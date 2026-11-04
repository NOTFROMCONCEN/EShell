import 'dart:convert';

import '../utils/ai_markdown.dart';
import 'telnet_scanner.dart';

/// AI Agent 自动执行模式的安全与协议纯逻辑。
///
/// 协议：模型把待执行命令放进 ```run 代码块（每条消息最多一个），
/// 应用自动执行并把命令执行后的最新终端输出回传给模型继续分析。
///
/// 安全分级（每条命令按行 + 复合命令分段检查，取最严重级别）：
/// - blocked：永不自动执行（重启/清配置/格式化/递归删除等），
///   回传拦截说明让模型改用文字指引。
/// - confirm：弹确认对话框，用户点击「执行」才发送。
/// - auto：直接自动执行。
enum AgentCommandVerdict { blocked, confirm, auto }

/// 单次 Agent 链路的自动执行步数上限（防失控循环）。
const int agentMaxSteps = 12;

/// 视为 shell 类的语言标签（无语言的裸 ``` 在运维语境里也按命令处理）。
const Set<String> kAgentShellLanguages = {
  'bash', 'sh', 'shell', 'zsh', 'console', 'powershell', 'pwsh',
  'ps1', 'cmd', 'batch', 'bat',
};

/// 提取回复里待自动执行的命令。
///
/// 优先取最后一个 ```run 块（显式协议）；若模型不遵守协议（实测常见），
/// 回退到最后一个 shell 类/无语言代码块——运维语境里这类块几乎都是
/// 待执行命令，且安全分级仍然生效。非 shell 语言（python/sql 等）
/// 不回退，返回 null。
String? extractRunCommand(String content) {
  String? lastRun;
  String? lastShellLike;
  for (final block in parseAiMarkdown(content)) {
    if (block is! AiCodeBlock) continue;
    final lang = block.language.toLowerCase();
    final code = block.code.trim();
    if (code.isEmpty) continue;
    if (lang == 'run') lastRun = code;
    if (lang.isEmpty || kAgentShellLanguages.contains(lang)) {
      lastShellLike = code;
    }
  }
  return lastRun ?? lastShellLike;
}

/// 永不自动执行的命令（命中即整块拦截）。
final List<RegExp> _agentBlockedPatterns = [
  // 重启 / 停机 / 出厂。
  RegExp(r'^\s*(reload|reboot|halt|poweroff|init\s+[06]|factory[- ]?reset)\b'),
  RegExp(r'\b(write\s+erase|reset\s+saved|restore\s+default)\b'),
  RegExp(r'^\s*erase\b'),
  RegExp(r'^\s*undo\s+all\b'),
  // 格式化 / 底层写盘。
  RegExp(r'\b(mkfs\w*|fdisk|parted|diskpart)\b'),
  RegExp(r'\bdd\s+if='),
  RegExp(r'\bformat\s+\w+:'),
  // 递归 / 强制删除。
  RegExp(r'rm\s+(-[a-z]*[rf][a-z]*\s+)+'),
  RegExp(r'\brd\s+/s\b'),
  RegExp(r'\bdel\s+/[fsq]\b'),
  RegExp(r'remove-item\b.*-recurse'),
  // fork bomb。
  RegExp(r':\(\)\s*\{\s*:\|\s*&\s*\}\s*;\s*:'),
];

/// 需要用户确认的命令（配置变更 / 删除 / 停服务等）。
final List<RegExp> _agentConfirmPatterns = [
  // 网络设备配置变更（Cisco/H3C/华为）。
  RegExp(r'^\s*(no|undo)\s+\S'),
  RegExp(r'^\s*shutdown\b'),
  RegExp(r'^\s*(delete|del|rd|rmdir|rm)\b'),
  RegExp(r'\bcopy\s+running-config\s+startup-config\b'),
  RegExp(r'^\s*(save|write)\b.*\bconfig'),
  // 进程 / 服务 / 系统操作。
  RegExp(r'\b(kill|pkill|taskkill|userdel|usermod|passwd)\b'),
  RegExp(r'systemctl\s+(stop|restart|disable|reset-failed)\b'),
  RegExp(r'\b(chmod|chown|visudo)\b'),
  RegExp(r'\b(apt|yum|dnf|zypper|pip|npm)\s+(remove|purge|uninstall|autoremove)\b'),
  RegExp(r'\breboot\b.*\b(now| -f)?\b'),
  RegExp(r'\brestart\b'),
];

AgentCommandVerdict classifyAgentCommand(String command) {
  var worst = AgentCommandVerdict.auto;
  for (final raw in command.split('\n')) {
    // 复合命令按 ; && || | 逐段检查（任何一段命中即整条升级）。
    final segments = raw.split(RegExp(r';|&&|\|\||\|'));
    for (final seg in segments) {
      final line = seg.trim().toLowerCase();
      if (line.isEmpty) continue;
      final verdict = _classifySegment(line);
      if (verdict == AgentCommandVerdict.blocked) {
        return AgentCommandVerdict.blocked;
      }
      if (verdict == AgentCommandVerdict.confirm) {
        worst = AgentCommandVerdict.confirm;
      }
    }
  }
  return worst;
}

AgentCommandVerdict _classifySegment(String line) {
  for (final pattern in _agentBlockedPatterns) {
    if (pattern.hasMatch(line)) return AgentCommandVerdict.blocked;
  }
  for (final pattern in _agentConfirmPatterns) {
    if (pattern.hasMatch(line)) return AgentCommandVerdict.confirm;
  }
  return AgentCommandVerdict.auto;
}

// ---------- Telnet 扫描能力（```scan 块） ----------

/// Agent 请求的端口扫描（```scan 块，JSON：
/// `{"host":"127.0.0.1","startPort":32768,"endPort":32800}`）。
class AgentScanRequest {
  const AgentScanRequest({
    required this.host,
    required this.startPort,
    required this.endPort,
  });

  final String host;
  final int startPort;
  final int endPort;

  String get label => '$host:$startPort-$endPort';
}

/// 提取最后一段 ```scan 块原文；没有返回 null。
String? extractScanBlock(String content) {
  for (final block in parseAiMarkdown(content).reversed) {
    if (block is AiCodeBlock && block.language.toLowerCase() == 'scan') {
      return block.code;
    }
  }
  return null;
}

/// 解析 scan 块 JSON。失败抛 [FormatException]（中文可读）。
AgentScanRequest parseScanRequest(String raw) {
  dynamic json;
  try {
    json = jsonDecode(raw);
  } catch (_) {
    throw const FormatException(
        'scan 块必须是 JSON，例如 {"host":"127.0.0.1","startPort":32768,"endPort":32800}');
  }
  if (json is! Map) {
    throw const FormatException('scan 块必须是 JSON 对象');
  }
  var host = (json['host'] as String?)?.trim() ?? '127.0.0.1';
  if (host.isEmpty) host = '127.0.0.1';
  final start = json['startPort'];
  final end = json['endPort'];
  if (start is! int || end is! int) {
    throw const FormatException('startPort / endPort 必须是整数');
  }
  if (start < 1 || start > 65535 || end < 1 || end > 65535) {
    throw const FormatException('端口必须在 1-65535 之间');
  }
  if (start > end) {
    throw const FormatException('startPort 不能大于 endPort');
  }
  if (end - start + 1 > kMaxTelnetScanPorts) {
    throw FormatException('单次扫描最多 $kMaxTelnetScanPorts 个端口，请缩小区间');
  }
  return AgentScanRequest(host: host, startPort: start, endPort: end);
}

/// 是否本机地址：本机扫描直接执行，远程主机需用户确认。
bool isLocalScanHost(String host) {
  final h = host.trim().toLowerCase();
  return h == 'localhost' || h == '127.0.0.1' || h == '::1' || h == '[::1]';
}

/// 把扫描结果压成回传给模型的摘要文本（每行一个开放端口）。
String formatScanSummary(List<TelnetScanResult> results) {
  if (results.isEmpty) return '（未发现开放的候选端口）';
  final buffer = StringBuffer();
  for (final r in results) {
    final kind = switch (r.kind) {
      TelnetProbeKind.telnet => 'telnet',
      TelnetProbeKind.console => 'console',
      TelnetProbeKind.silent => 'silent',
      TelnetProbeKind.nonTelnet => 'nonTelnet',
      TelnetProbeKind.closed => 'closed',
    };
    buffer.writeln(
        '${r.port} → $kind${r.banner.isEmpty ? '' : '｜${r.banner}'}');
  }
  return buffer.toString().trim();
}

/// 执行一次扫描并返回给模型的摘要（Agent scanProvider 默认实现）。
Future<String> runTelnetScanForAgent(AgentScanRequest request) async {
  try {
    final results = await TelnetScanner().scan(
      host: request.host,
      startPort: request.startPort,
      endPort: request.endPort,
    );
    return formatScanSummary(results);
  } catch (e) {
    return '扫描失败：$e';
  }
}
