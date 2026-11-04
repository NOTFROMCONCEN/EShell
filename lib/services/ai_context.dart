import '../models/session.dart';
import '../state/app_state.dart';

/// 组装发给 AI 的终端上下文（纯逻辑，可单测）。
///
/// 只取最近 [maxLines] 行，并限制总字符数 [maxChars]，避免一次请求吞掉太多 token。
String buildTerminalContext({
  required String displayName,
  required String transport,
  required String address,
  required String status,
  required String terminalText,
  int maxLines = 150,
  int maxChars = 12000,
}) {
  final normalized = terminalText.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  var lines = normalized.split('\n');
  // 去掉尾部连续空行（终端缓冲末尾常见空白）。
  while (lines.isNotEmpty && lines.last.trim().isEmpty) {
    lines = lines.sublist(0, lines.length - 1);
  }
  final tail = lines.length > maxLines
      ? lines.sublist(lines.length - maxLines)
      : lines;
  var body = tail.join('\n');
  if (body.length > maxChars) {
    body = body.substring(body.length - maxChars);
  }

  final buffer = StringBuffer()
    ..writeln('会话: $displayName')
    ..writeln('类型: $transport')
    ..writeln('地址: $address')
    ..writeln('状态: $status');
  if (body.isEmpty) {
    buffer.writeln('--- 终端当前无输出 ---');
  } else {
    buffer
      ..writeln('--- 终端最近 ${tail.length} 行输出 ---')
      ..writeln(body);
  }
  return buffer.toString();
}

/// 无活动会话时的上下文占位。
const String noSessionContext = '（当前没有打开的终端会话；请基于通用网络知识回答，'
    '并说明需要用户提供哪些设备输出。）';

/// 会话传输类型的中文名（AI 上下文展示用）。
String transportLabel(SessionTransport transport) => switch (transport) {
      SessionTransport.ssh => 'SSH',
      SessionTransport.telnet => 'Telnet',
      SessionTransport.serial => '串口',
    };

/// 连接状态的中文名（AI 上下文展示用）。
String connectionStatusLabel(String statusName) => switch (statusName) {
      'connecting' => '连接中',
      'connected' => '已连接',
      'failed' => '连接失败',
      'closed' => '已关闭',
      _ => statusName,
    };

/// 从主窗口 AppState 构建当前活动会话的上下文
///（停靠面板本地生成、AI 子窗口经 IPC 请求主窗口生成，共用此函数）。
String buildContextFromAppState(AppState app) {
  final connection = app.activeTab?.connection;
  if (connection == null) return noSessionContext;
  return buildTerminalContext(
    displayName: connection.session.displayName,
    transport: transportLabel(connection.session.transport),
    address: connection.session.address,
    status: connectionStatusLabel(connection.status.name),
    terminalText: connection.terminal.buffer.getText(),
    maxLines: app.ai.contextLines,
  );
}
