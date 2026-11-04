import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'telnet_protocol.dart';
import 'terminal_connection.dart';

/// 一条打开的 Telnet 终端连接：原始 TCP + RFC 854 协商 + xterm 终端实例。
///
/// 适用场景：EVE-NG 导出的节点控制台（`telnet://<eve-ip>:<端口>`）、
/// 带 Telnet 服务的终端服务器等。
///
/// 数据流：Socket → [TelnetCodec.feed]（剥 IAC / 回协商）→ 基类落日志 + 终端；
/// 键盘：terminal.onOutput → [TelnetCodec.encodeOutgoing]（转义/CR LF）→ Socket。
class TelnetConnection extends TerminalConnection {
  TelnetConnection({required super.session, TelnetCodec? codec})
      : _codec = codec ?? TelnetCodec();

  final TelnetCodec _codec;

  Socket? _socket;
  StreamSubscription<Uint8List>? _sub;

  @override
  Future<void> performConnect() async {
    // 重连沿用同一对象：清掉上一次连接的协商记忆。
    _codec.reset();
    _codec.updateWindow(terminal.viewWidth, terminal.viewHeight);

    final socket = await Socket.connect(
      session.host,
      session.port,
      timeout: const Duration(seconds: 12),
    );
    _socket = socket;
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {
      // 某些平台不支持该选项，忽略即可。
    }

    _sub = socket.listen(
      _onData,
      onDone: () {
        unawaited(handleRemoteClosed());
      },
      onError: (Object e) {
        unawaited(handleRemoteClosed(err: e.toString()));
      },
      cancelOnError: true,
    );

    // 协议协商：声明终端类型/窗口尺寸/SGA，并请求对端 SGA。
    _write(_codec.initialNegotiation());

    terminal.onOutput = (data) {
      try {
        _write(_codec.encodeOutgoing(data));
      } catch (e) {
        // 连接已断开时写失败：按远端关闭处理。
        unawaited(handleRemoteClosed(err: e.toString()));
      }
    };
    terminal.onResize = (columns, rows, _, _) {
      _codec.updateWindow(columns, rows);
      // 只有对端协商过 NAWS 才上报，避免向不支持的服务端发无意义子协商。
      if (_codec.nawsNegotiated) _write(_codec.nawsBytes(columns, rows));
    };
  }

  void _onData(Uint8List chunk) {
    final result = _codec.feed(chunk);
    if (result.replies.isNotEmpty) _write(result.replies);
    if (result.data.isNotEmpty) handleRemoteBytes(result.data);
  }

  void _write(Uint8List bytes) {
    final socket = _socket;
    if (socket == null) return;
    try {
      socket.add(bytes);
    } catch (_) {
      // 写入失败只可能发生在断开过程，状态由 onDone/onError 流转。
    }
  }

  @override
  Future<void> performTeardown() async {
    await _sub?.cancel();
    _sub = null;
    final socket = _socket;
    _socket = null;
    if (socket == null) return;
    try {
      await socket.flush().timeout(const Duration(seconds: 2));
    } catch (_) {}
    try {
      socket.destroy();
    } catch (_) {}
  }
}
