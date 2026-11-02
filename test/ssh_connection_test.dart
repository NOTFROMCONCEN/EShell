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
}
