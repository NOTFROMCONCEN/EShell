import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:eshell/models/session.dart';
import 'package:eshell/services/telnet_connection.dart';
import 'package:eshell/services/terminal_connection.dart';
import 'package:eshell/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';

Session _telnetSession(int port) => Session(
      id: 'telnet-test',
      name: '',
      host: '127.0.0.1',
      port: port,
      transport: SessionTransport.telnet,
      username: '',
    );

bool _containsSequence(List<int> haystack, List<int> needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var matched = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        matched = false;
        break;
      }
    }
    if (matched) return true;
  }
  return false;
}

void main() {
  test('Telnet 连接：发协商、剥帧显示、回协商、远端关闭', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final serverSide = Completer<Socket>();
    final received = <int>[];
    server.listen((socket) {
      if (!serverSide.isCompleted) serverSide.complete(socket);
      socket.listen(received.addAll);
    });

    final conn = TelnetConnection(session: _telnetSession(server.port));
    try {
      await conn.connect();
      expect(conn.status, ConnStatus.connected);
      final socket = await serverSide.future;

      // 初始协商以 IAC WILL TERMINAL-TYPE 起头。
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(received.length, greaterThanOrEqualTo(3));
      expect(received.sublist(0, 3), [255, 251, 24]);

      // 服务端 WILL ECHO + 设备回显：终端只应看到文本，协商被剥离。
      socket.add(Uint8List.fromList([255, 251, 1, ...'Router>'.codeUnits]));
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(conn.terminal.buffer.getText(), contains('Router>'));
      expect(_containsSequence(received, [255, 253, 1]), isTrue);

      // 键盘输入：回车经 NVT 编码为 CR LF。
      conn.terminal.textInput('ls\r');
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(_containsSequence(received, 'ls\r\n'.codeUnits), isTrue);

      // 远端关闭 → closed。
      await socket.close();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(conn.status, ConnStatus.closed);
    } finally {
      await conn.disconnect();
      if (serverSide.isCompleted) (await serverSide.future).destroy();
      await server.close();
    }
  });

  test('连接被拒绝 → failed 且带错误信息', () async {
    final conn = TelnetConnection(session: _telnetSession(1));
    await conn.connect();
    expect(conn.status, ConnStatus.failed);
    expect(conn.error, isNotNull);
    await conn.disconnect();
  });

  test('AppState.connect 对 Telnet 会话创建 TelnetConnection 标签', () async {
    final app = AppState();
    app.connect(Session(
      id: 'telnet-app',
      name: '',
      host: '127.0.0.1',
      port: 1,
      transport: SessionTransport.telnet,
      username: '',
    ));
    expect(app.tabs, hasLength(1));
    final conn = app.tabs.single.connection;
    expect(conn, isA<TelnetConnection>());
    for (var i = 0; i < 100 && conn.status == ConnStatus.connecting; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(conn.status, ConnStatus.failed);
    app.closeTab(app.tabs.single.id);
    expect(app.tabs, isEmpty);
  });
}
