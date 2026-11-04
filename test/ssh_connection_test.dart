import 'package:eshell/models/session.dart';
import 'package:eshell/services/ssh_service.dart';
import 'package:eshell/services/terminal_connection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 回归：C6 移除 ConnStatus.idle 后初始 status 即为 connecting，
  // connect() 的重入守卫曾把首次连接误拦下，导致永远卡在「正在连接」。
  group('SshConnection.connect 重入守卫', () {
    test('首次 connect 必须真正发起连接（不可达端口应流转到 failed）', () async {
      final conn = SshConnection(
        session: Session(
          id: 't1',
          name: '',
          host: '127.0.0.1',
          port: 1, // 本地拒绝连接的端口，快速失败。
          username: 'u',
        ),
      );
      await conn.connect();
      // 若卡在 connecting（旧回归），此断言失败。
      expect(conn.status, ConnStatus.failed);
      expect(conn.error, isNotNull);
    });

    test('失败后允许再次 connect（重试路径不被守卫拦截）', () async {
      final conn = SshConnection(
        session: Session(
          id: 't2',
          name: '',
          host: '127.0.0.1',
          port: 1,
          username: 'u',
        ),
      );
      await conn.connect();
      expect(conn.status, ConnStatus.failed);
      await conn.connect();
      expect(conn.status, ConnStatus.failed);
    });

    test('disconnect 后状态为 closed，可重新 connect', () async {
      final conn = SshConnection(
        session: Session(
          id: 't3',
          name: '',
          host: '127.0.0.1',
          port: 1,
          username: 'u',
        ),
      );
      await conn.connect();
      await conn.disconnect();
      expect(conn.status, ConnStatus.closed);
      await conn.connect();
      expect(conn.status, ConnStatus.failed);
    });
  });

  group('TerminalConnection.sendCommand · AI 发送到终端', () {
    SshConnection makeConn({ConnStatus status = ConnStatus.connected}) {
      final conn = SshConnection(
        session: Session(id: 's1', name: '', host: 'h', username: 'u'),
      );
      conn.status = status;
      return conn;
    }

    test('已连接：发送命令并补回车', () {
      final conn = makeConn();
      final out = <String>[];
      conn.terminal.onOutput = out.add;
      conn.sendCommand('  show version  ');
      expect(out.join(), 'show version\r');
    });

    test('多行命令逐行回车（CRLF 归一化）', () {
      final conn = makeConn();
      final out = <String>[];
      conn.terminal.onOutput = out.add;
      conn.sendCommand('conf t\r\nint g0/0\r\nshutdown');
      expect(out.join(), 'conf t\rint g0/0\rshutdown\r');
    });

    test('未连接时不发送（守卫）', () {
      final conn = makeConn(status: ConnStatus.closed);
      final out = <String>[];
      conn.terminal.onOutput = out.add;
      conn.sendCommand('show version');
      expect(out, isEmpty);
    });

    test('空白命令不发送', () {
      final conn = makeConn();
      final out = <String>[];
      conn.terminal.onOutput = out.add;
      conn.sendCommand(' \n\r\n ');
      expect(out, isEmpty);
    });
  });
}
