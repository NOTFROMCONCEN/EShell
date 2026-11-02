import 'package:eshell/models/session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Session JSON 往返', () {
    test('完整字段往返一致', () {
      final s = Session(
        id: 'abc123',
        name: '核心交换机',
        host: '10.0.0.1',
        port: 2222,
        username: 'admin',
        authType: SshAuthType.publicKey,
        password: 'p@ss',
        passphrase: 'keypass',
        privateKeyPath: r'C:\keys\id_rsa',
        tag: '生产',
        lastConnectedAt: DateTime.parse('2026-10-27T03:22:59.000'),
      );
      final r = Session.fromJson(s.toJson());
      expect(r.id, s.id);
      expect(r.name, s.name);
      expect(r.host, s.host);
      expect(r.port, s.port);
      expect(r.username, s.username);
      expect(r.authType, SshAuthType.publicKey);
      expect(r.password, 'p@ss');
      expect(r.passphrase, 'keypass');
      expect(r.privateKeyPath, s.privateKeyPath);
      expect(r.tag, s.tag);
      expect(r.lastConnectedAt, s.lastConnectedAt);
    });

    test('串口会话往返与字段约定（host=COM 口，port=波特率）', () {
      final s = Session(
        id: 'com1',
        name: 'console',
        host: 'COM3',
        port: 115200,
        transport: SessionTransport.serial,
        username: '',
      );
      final r = Session.fromJson(s.toJson());
      expect(r.transport, SessionTransport.serial);
      expect(r.host, 'COM3');
      expect(r.port, 115200);
      expect(r.displayName, 'console');
      expect(r.address, 'COM3 · 115200 bps');
    });

    test('缺省 transport 为 ssh；串口 displayName 回退 COM 口名', () {
      expect(Session.fromJson({'id': 'x', 'name': '', 'host': 'h', 'username': 'u'})
          .transport, SessionTransport.ssh);
      final serial = Session(
        id: 'x',
        name: '',
        host: 'COM7',
        port: 9600,
        transport: SessionTransport.serial,
        username: '',
      );
      expect(serial.displayName, 'COM7');
    });

    test('autoBaud 序列化往返与缺省值；address 显示自动波特率', () {
      final s = Session(
        id: 'a1',
        name: 'console-auto',
        host: 'COM3',
        port: 9600,
        transport: SessionTransport.serial,
        autoBaud: true,
        username: '',
      );
      expect(s.address, 'COM3 · 自动波特率');
      final r = Session.fromJson(s.toJson());
      expect(r.autoBaud, isTrue);
      // 旧数据无 autoBaud 字段 → false。
      expect(
          Session.fromJson({
            'id': 'a2',
            'name': '',
            'host': 'COM4',
            'port': 9600,
            'transport': 'serial',
            'username': '',
          }).autoBaud,
          isFalse);
      expect(s.copyWith(autoBaud: false).address, 'COM3 · 9600 bps');
    });

    test('缺省字段回退默认值', () {
      final s = Session.fromJson({
        'id': 'x1',
        'name': '',
        'host': 'h',
        'username': 'root',
      });
      expect(s.port, 22);
      expect(s.authType, SshAuthType.password);
      expect(s.password, isNull);
      expect(s.passphrase, isNull);
      expect(s.privateKeyPath, isNull);
      expect(s.tag, isNull);
      expect(s.lastConnectedAt, isNull);
      expect(s.isTemporary, isFalse);
    });

    test('displayName 回退 用户名@主机；address 含端口', () {
      final s = Session(id: 'x', name: '', host: 'h', username: 'u');
      expect(s.displayName, 'u@h');
      expect(s.address, 'u@h:22');
    });
  });

  group('Session.copyWith · M3 不可变模型', () {
    test('不传的字段沿用原值，显式 null 才清空', () {
      final s = Session(
        id: 'x',
        name: 'a',
        host: 'h',
        username: 'u',
        password: 'old',
        tag: 't',
      );
      final s2 = s.copyWith(name: 'b');
      expect(s2.name, 'b');
      expect(s2.password, 'old');
      expect(s2.tag, 't');
      expect(identical(s, s2), isFalse);

      final s3 = s.copyWith(password: null);
      expect(s3.password, isNull);
    });

    test('原实例不被修改', () {
      final s = Session(id: 'x', name: 'a', host: 'h', username: 'u');
      s.copyWith(name: 'changed', port: 9999);
      expect(s.name, 'a');
      expect(s.port, 22);
    });
  });
}
