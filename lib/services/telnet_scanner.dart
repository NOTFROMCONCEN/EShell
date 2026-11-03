import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'telnet_protocol.dart';

/// 单个端口的探测结论。
enum TelnetProbeKind {
  /// 收到 IAC 协商字节：确定是 Telnet 服务。
  telnet,

  /// 收到可读回显（横幅/提示符）：疑似设备控制台。
  console,

  /// 端口开放但没有任何输出：EVE-NG 直通控制台常见形态。
  silent,

  /// 有响应但不像终端（HTTP/SSH/TLS 等），不建议作为 Telnet 连接。
  nonTelnet,

  /// 端口未开放 / 连接被拒绝 / 超时。
  closed,
}

/// 单端口探测结果。
class TelnetProbe {
  const TelnetProbe({
    required this.kind,
    this.banner = '',
  });

  final TelnetProbeKind kind;

  /// 清洗后的回显预览（去掉 Telnet 协商、ANSI 控制序列，压缩空白）。
  final String banner;

  bool get isOpen => kind != TelnetProbeKind.closed;
}

/// 扫描结果的一行。
class TelnetScanResult {
  const TelnetScanResult({
    required this.port,
    required this.kind,
    this.banner = '',
  });

  final int port;
  final TelnetProbeKind kind;
  final String banner;

  /// 是否值得作为 Telnet 控制台尝试连接。
  bool get candidate => kind != TelnetProbeKind.nonTelnet;
}

/// 扫描进度（用于 UI 进度条文案）。
class TelnetScanProgress {
  const TelnetScanProgress({
    required this.scanned,
    required this.total,
    required this.found,
  });

  final int scanned;
  final int total;
  final int found;
}

/// 可注入的端口探测器（单测用假实现替换真实 Socket）。
typedef TelnetPortProber = Future<TelnetProbe> Function(
    String host, int port);

/// 扫描允许的最大端口数量：避免手滑输入 1-65535 导致长时间扫描。
const int kMaxTelnetScanPorts = 4096;

/// 端口范围解析（纯逻辑，错误信息可直接展示）。
({int start, int end}) parsePortRange(String startText, String endText) {
  final start = int.tryParse(startText.trim());
  if (start == null) {
    throw const FormatException('起始端口必须是数字');
  }
  final end = int.tryParse(endText.trim());
  if (end == null) {
    throw const FormatException('结束端口必须是数字');
  }
  if (start < 1 || start > 65535 || end < 1 || end > 65535) {
    throw const FormatException('端口必须在 1-65535 之间');
  }
  if (start > end) {
    throw const FormatException('起始端口不能大于结束端口');
  }
  if (end - start + 1 > kMaxTelnetScanPorts) {
    throw const FormatException(
        '单次扫描最多 $kMaxTelnetScanPorts 个端口，请缩小区间');
  }
  return (start: start, end: end);
}

/// 根据探测到的原始字节判断端口性质（纯逻辑，可单测）。
TelnetProbeKind classifyTelnetProbe(List<int> bytes) {
  if (bytes.isEmpty) return TelnetProbeKind.silent;
  if (bytes.contains(TelnetCommand.iac)) return TelnetProbeKind.telnet;
  // TLS ServerHello/Alert（0x16/0x15 + 0x03）不是终端。
  if (bytes.length >= 2 && bytes[0] == 0x16 && bytes[1] == 0x03) {
    return TelnetProbeKind.nonTelnet;
  }
  final text = sanitizeTelnetProbeBanner(bytes);
  if (text.isEmpty) return TelnetProbeKind.nonTelnet;
  final lower = text.toLowerCase();
  if (lower.startsWith('http/') ||
      lower.startsWith('ssh-') ||
      lower.contains('<html') ||
      lower.contains('<head')) {
    return TelnetProbeKind.nonTelnet;
  }
  return TelnetProbeKind.console;
}

/// 把探测到的原始字节清洗成一行可读预览。
///
/// 去掉 IAC 协商序列与 ANSI 转义，控制字符转空格并压缩空白。
String sanitizeTelnetProbeBanner(List<int> bytes, {int maxLength = 80}) {
  final data = <int>[];
  for (var i = 0; i < bytes.length; i++) {
    final byte = bytes[i];
    if (byte != TelnetCommand.iac) {
      data.add(byte);
      continue;
    }
    if (i + 1 >= bytes.length) break;
    final command = bytes[i + 1];
    if (command == TelnetCommand.iac) {
      data.add(TelnetCommand.iac);
      i += 1;
    } else if (command == TelnetCommand.sb) {
      // 跳过 IAC SB … IAC SE。
      i += 2;
      while (i + 1 < bytes.length) {
        if (bytes[i] == TelnetCommand.iac &&
            bytes[i + 1] == TelnetCommand.se) {
          i += 1;
          break;
        }
        i += 1;
      }
    } else {
      // WILL/WONT/DO/DONT + 1 字节选项码。
      i += 2;
    }
  }

  var text = utf8.decode(data, allowMalformed: true);
  // CSI 序列，如 ESC[2J、ESC[1;32m。
  text = text.replaceAll(RegExp(r'\x1B\[[0-9;?]*[ -/]*[@-~]'), '');
  // 其他两字节 ESC 序列。
  text = text.replaceAll(RegExp(r'\x1B[@-_]'), '');
  // 其余控制字符（保留可读性）。
  text = text.replaceAll(RegExp(r'[\x00-\x08\x0B-\x1F\x7F]'), ' ');
  text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.length > maxLength) {
    text = '${text.substring(0, maxLength)}…';
  }
  return text;
}

/// 探测一个端口：连接 → 等主动横幅 → 无输出则发回车触发回显 → 分类。
Future<TelnetProbe> probeTelnetPort(
  String host,
  int port, {
  Duration connectTimeout = const Duration(milliseconds: 350),
  Duration bannerWindow = const Duration(milliseconds: 400),
  Duration probeWindow = const Duration(milliseconds: 700),
  int maxBytes = 4096,
}) async {
  Socket socket;
  try {
    socket = await Socket.connect(host, port, timeout: connectTimeout);
  } catch (_) {
    return const TelnetProbe(kind: TelnetProbeKind.closed);
  }

  final buffer = <int>[];
  final closed = Completer<void>();
  late final StreamSubscription<Uint8List> sub;
  sub = socket.listen(
    (chunk) {
      if (buffer.length >= maxBytes) return;
      final take = maxBytes - buffer.length;
      buffer.addAll(chunk.length <= take ? chunk : chunk.sublist(0, take));
    },
    onDone: () {
      if (!closed.isCompleted) closed.complete();
    },
    onError: (Object _) {
      if (!closed.isCompleted) closed.complete();
    },
    cancelOnError: true,
  );

  try {
    // 阶段一：等 Telnet 协商或设备横幅主动到来。
    await Future.any([Future<void>.delayed(bannerWindow), closed.future]);
    // 阶段二：仍无输出时发一个回车，触发控制台提示符回显。
    if (buffer.isEmpty && !closed.isCompleted) {
      try {
        socket.add(const [0x0D, 0x0A]);
      } catch (_) {}
      await Future.any([Future<void>.delayed(probeWindow), closed.future]);
    }
  } finally {
    await sub.cancel();
    try {
      socket.destroy();
    } catch (_) {}
  }

  return TelnetProbe(
    kind: classifyTelnetProbe(buffer),
    banner: sanitizeTelnetProbeBanner(buffer),
  );
}

/// 并发端口扫描器：默认探测 `host` 上 `[startPort, endPort]` 的开放端口。
///
/// 每个端口独立连接、短超时、并发 [concurrency] 个 worker；支持取消
/// （返回已扫描到的部分结果）。可通过 [prober] 注入假探测器做单测。
class TelnetScanner {
  TelnetScanner({
    this.concurrency = 48,
    Duration connectTimeout = const Duration(milliseconds: 350),
    Duration bannerWindow = const Duration(milliseconds: 400),
    Duration probeWindow = const Duration(milliseconds: 700),
    TelnetPortProber? prober,
  })  : connectTimeout = connectTimeout,
        bannerWindow = bannerWindow,
        probeWindow = probeWindow,
        _prober = prober ??
            ((host, port) => probeTelnetPort(
                  host,
                  port,
                  connectTimeout: connectTimeout,
                  bannerWindow: bannerWindow,
                  probeWindow: probeWindow,
                ));

  final int concurrency;
  final Duration connectTimeout;
  final Duration bannerWindow;
  final Duration probeWindow;

  final TelnetPortProber _prober;

  Future<List<TelnetScanResult>> scan({
    required String host,
    required int startPort,
    required int endPort,
    void Function(TelnetScanProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final total = endPort - startPort + 1;
    if (total <= 0) return const [];

    final results = <TelnetScanResult>[];
    var scanned = 0;
    var nextIndex = 0;

    Future<void> worker() async {
      while (true) {
        if (isCancelled?.call() ?? false) return;
        final index = nextIndex++;
        if (index >= total) return;
        final port = startPort + index;

        TelnetProbe probe;
        try {
          probe = await _prober(host, port);
        } catch (_) {
          probe = const TelnetProbe(kind: TelnetProbeKind.closed);
        }
        if (probe.isOpen) {
          results.add(TelnetScanResult(
            port: port,
            kind: probe.kind,
            banner: probe.banner,
          ));
        }
        scanned++;
        onProgress?.call(TelnetScanProgress(
          scanned: scanned,
          total: total,
          found: results.length,
        ));
      }
    }

    final workers = <Future<void>>[];
    final workerCount = concurrency.clamp(1, total);
    for (var i = 0; i < workerCount; i++) {
      workers.add(worker());
    }
    await Future.wait(workers);

    results.sort((a, b) => a.port.compareTo(b.port));
    return results;
  }
}
