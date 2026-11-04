import 'package:eshell/models/session.dart';
import 'package:eshell/services/ssh_service.dart';
import 'package:eshell/services/terminal_connection.dart';
import 'package:eshell/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppState.sendCommandToActiveSession · AI 发送入口', () {
    test('无活动会话：返回错误文案', () {
      final app = AppState();
      expect(app.sendCommandToActiveSession('show version'),
          '当前没有打开的终端会话');
    });

    test('已连接的活动会话：发送成功并写入终端输入', () {
      final app = AppState();
      final conn = SshConnection(
        session: Session(id: 's1', name: '', host: 'h', username: 'u'),
      );
      conn.status = ConnStatus.connected;
      final out = <String>[];
      conn.terminal.onOutput = out.add;
      app.tabs.add(ConnectionTab(id: 't1', connection: conn));
      app.activeTabId = 't1';

      expect(app.sendCommandToActiveSession('display version'), isNull);
      expect(out.join(), 'display version\r');
    });

    test('会话未连接：返回错误文案且不写入', () {
      final app = AppState();
      final conn = SshConnection(
        session: Session(id: 's2', name: '', host: 'h', username: 'u'),
      );
      conn.status = ConnStatus.closed;
      final out = <String>[];
      conn.terminal.onOutput = out.add;
      app.tabs.add(ConnectionTab(id: 't2', connection: conn));
      app.activeTabId = 't2';

      expect(app.sendCommandToActiveSession('display version'), '当前会话未连接');
      expect(out, isEmpty);
    });

    test('非活动标签不接收命令', () {
      final app = AppState();
      final active = SshConnection(
        session: Session(id: 's3', name: '', host: 'h', username: 'u'),
      );
      final idle = SshConnection(
        session: Session(id: 's4', name: '', host: 'h', username: 'u'),
      );
      active.status = ConnStatus.connected;
      final idleOut = <String>[];
      idle.terminal.onOutput = idleOut.add;
      app.tabs
        ..add(ConnectionTab(id: 't3', connection: idle))
        ..add(ConnectionTab(id: 't4', connection: active));
      app.activeTabId = 't4';

      expect(app.sendCommandToActiveSession('x'), isNull);
      expect(idleOut, isEmpty);
    });
  });

  group('AppState.captureCommandOutputDelta · Agent 增量输出', () {
    SshConnection attach(AppState app) {
      final conn = SshConnection(
        session: Session(id: 'd1', name: '', host: 'h', username: 'u'),
      );
      conn.status = ConnStatus.connected;
      app.tabs.add(ConnectionTab(id: 'td', connection: conn));
      app.activeTabId = 'td';
      return conn;
    }

    test('只返回命令发送后新增的输出（不含旧屏内容）', () {
      final app = AppState();
      final conn = attach(app);
      conn.terminal.write('旧输出 A\n旧输出 B\n');

      expect(app.sendCommandToActiveSession('df -hT'), isNull);
      conn.terminal.write('df -hT 的新输出\n');

      final delta = app.captureCommandOutputDelta();
      expect(delta, contains('df -hT 的新输出'));
      expect(delta, isNot(contains('旧输出 A')));
      expect(delta, isNot(contains('旧输出 B')));
    });

    test('无新输出时返回占位，可重复调用做稳定采样', () {
      final app = AppState();
      final conn = attach(app);
      conn.terminal.write('ready\n');
      app.sendCommandToActiveSession('cmd');
      // 尚未产生输出：多次采样结果一致（稳定）。
      final first = app.captureCommandOutputDelta();
      final second = app.captureCommandOutputDelta();
      expect(first, '（无输出）');
      expect(second, '（无输出）');
    });

    test('超长输出尾部截断（控制 token 体量）', () {
      final app = AppState();
      final conn = attach(app);
      app.sendCommandToActiveSession('show log');
      final huge = '${'x' * 7000}\nEND-MARK';
      conn.terminal.write('$huge\n');

      final delta = app.captureCommandOutputDelta(maxChars: 2000);
      expect(delta.length, lessThanOrEqualTo(2100));
      expect(delta, contains('已截断'));
      expect(delta, contains('END-MARK'));
    });

    test('无活动会话时返回占位', () {
      expect(AppState().captureCommandOutputDelta(), '（没有活动会话）');
    });
  });
}
