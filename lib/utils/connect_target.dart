import '../models/session.dart';

/// 快速连接目标的解析（纯逻辑，便于单测）。
///
/// SSH 支持形式：
/// - `host` · `host:port`
/// - `user@host` · `user@host:port`
/// - `[IPv6]` · `[IPv6]:port`（裸 IPv6 含多个冒号，视为纯主机名）
///
/// Telnet 支持形式（transport = telnet）：
/// - `telnet://host`（默认 23）
/// - `telnet://host:port`（EVE-NG 控制台链接即此形式，如
///   `telnet://127.0.0.1:32768`）；`telnet://user@host:port` 中的用户名忽略
///
/// 串口支持形式（transport = serial）：
/// - `COM3`（默认 9600 波特率）
/// - `COM3@115200`
class ConnectTarget {
  const ConnectTarget({
    required this.transport,
    required this.username,
    required this.host,
    required this.port,
  });

  const ConnectTarget.ssh({
    required this.username,
    required this.host,
    this.port = 22,
  }) : transport = SessionTransport.ssh;

  const ConnectTarget.telnet({
    required this.host,
    this.port = 23,
  })  : transport = SessionTransport.telnet,
        username = '';

  final SessionTransport transport;
  final String username;

  /// SSH/Telnet：主机名/IP；串口：COM 口名（统一大写）。
  final String host;

  /// SSH/Telnet：端口；串口：波特率。
  final int port;
}

/// 常用波特率（编辑对话框下拉与串口校验共用）。
const List<int> kSerialBaudRates = [
  1200,
  2400,
  4800,
  9600,
  14400,
  19200,
  38400,
  57600,
  115200,
  230400,
  460800,
  921600,
];

/// 解析失败抛 [FormatException]，message 为可直接展示给用户的中文错误。
/// 输入为空白时返回 null。
ConnectTarget? parseConnectTarget(String input) {
  final text = input.trim();
  if (text.isEmpty) return null;

  // Telnet 形式优先：telnet://host[:port]。
  final telnet =
      RegExp(r'^telnet://(.*)$', caseSensitive: false).firstMatch(text);
  if (telnet != null) {
    var hostPort = telnet.group(1)!.trim();
    // 容错：去掉导出链接可能带的尾部斜杠。
    while (hostPort.endsWith('/')) {
      hostPort = hostPort.substring(0, hostPort.length - 1);
    }
    if (hostPort.isEmpty) {
      throw const FormatException(
          'Telnet 目标不能为空（示例：telnet://127.0.0.1:32768）');
    }
    // Telnet 无认证环节：user@ 前缀忽略，不参与连接。
    final at = hostPort.lastIndexOf('@');
    if (at >= 0) hostPort = hostPort.substring(at + 1);
    final parsed = _parseHostPort(hostPort, defaultPort: 23);
    return ConnectTarget.telnet(host: parsed.host, port: parsed.port);
  }

  // 串口形式（COM3 / COM3@115200）；COM 口名带 @ 波特率后缀，
  // 必须在 user@host 拆分之前识别。
  final comOnly = RegExp(r'^com\d+$', caseSensitive: false).firstMatch(text);
  if (comOnly != null) {
    return ConnectTarget(
      transport: SessionTransport.serial,
      username: '',
      host: text.toUpperCase(),
      port: 9600,
    );
  }
  final comWithBaud =
      RegExp(r'^(com\d+)@(.+)$', caseSensitive: false).firstMatch(text);
  if (comWithBaud != null) {
    // 带 @ 后缀的 COM 形式：波特率非法必须报错，不允许误入 SSH 解析。
    final baudText = comWithBaud.group(2)!.trim();
    final baud = int.tryParse(baudText);
    if (baud == null) {
      throw FormatException('串口波特率必须是数字（如 9600、115200），收到“$baudText”');
    }
    if (baud < 110 || baud > 4000000) {
      throw FormatException('波特率必须在 110-4000000 之间，收到 $baud');
    }
    return ConnectTarget(
      transport: SessionTransport.serial,
      username: '',
      host: comWithBaud.group(1)!.toUpperCase(),
      port: baud,
    );
  }

  var username = 'root';
  var hostPort = text;
  final at = text.indexOf('@');
  if (at == 0) {
    throw const FormatException('用户名不能为空（示例：admin@192.0.2.1）');
  }
  if (at > 0) {
    username = text.substring(0, at);
    hostPort = text.substring(at + 1);
    if (hostPort.isEmpty) throw const FormatException('主机不能为空');
  }

  final parsed = _parseHostPort(hostPort, defaultPort: 22);
  return ConnectTarget.ssh(
    username: username,
    host: parsed.host,
    port: parsed.port,
  );
}

/// 解析 `host[:port]` / `[IPv6][:port]`；未写端口时用 [defaultPort]。
({String host, int port}) _parseHostPort(
  String hostPort, {
  required int defaultPort,
}) {
  var port = defaultPort;
  String host;
  if (hostPort.startsWith('[')) {
    final close = hostPort.indexOf(']');
    if (close < 0) {
      throw const FormatException('IPv6 地址缺少 "]"；请用 [::1] 或 [::1]:2222 形式');
    }
    host = hostPort.substring(1, close);
    if (close + 1 < hostPort.length) {
      if (hostPort[close + 1] != ':') {
        throw const FormatException('“]”后只能跟“:端口”');
      }
      port = _parsePort(hostPort.substring(close + 2));
    }
  } else {
    final colon = hostPort.lastIndexOf(':');
    if (colon == 0) throw const FormatException('主机不能为空');
    // 仅当恰好一个冒号时按 host:port 解析；多个冒号视为裸 IPv6 主机名。
    if (colon > 0 && colon == hostPort.indexOf(':')) {
      port = _parsePort(hostPort.substring(colon + 1));
      host = hostPort.substring(0, colon);
    } else {
      host = hostPort;
    }
  }

  if (host.isEmpty) throw const FormatException('主机不能为空');
  return (host: host, port: port);
}

int _parsePort(String s) {
  final p = int.tryParse(s);
  if (p == null) {
    throw FormatException('端口必须是数字（1-65535），收到“$s”');
  }
  if (p < 1 || p > 65535) {
    throw FormatException('端口必须在 1-65535 之间，收到 $p');
  }
  return p;
}
