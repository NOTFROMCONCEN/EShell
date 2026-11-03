import 'package:eshell/models/session.dart';
import 'package:eshell/utils/connect_target.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseConnectTarget · C3 快速连接解析', () {
    test('纯主机名，默认 root:22', () {
      final t = parseConnectTarget('192.0.2.1')!;
      expect(t.username, 'root');
      expect(t.host, '192.0.2.1');
      expect(t.port, 22);
    });

    test('user@host', () {
      final t = parseConnectTarget('admin@core-sw01')!;
      expect(t.username, 'admin');
      expect(t.host, 'core-sw01');
      expect(t.port, 22);
    });

    test('host:port', () {
      final t = parseConnectTarget('192.0.2.1:2222')!;
      expect(t.host, '192.0.2.1');
      expect(t.port, 2222);
    });

    test('user@host:port', () {
      final t = parseConnectTarget('admin@198.51.100.1:2222')!;
      expect(t.username, 'admin');
      expect(t.host, '198.51.100.1');
      expect(t.port, 2222);
    });

    test('IPv6 带端口 [IPv6]:port', () {
      final t = parseConnectTarget('admin@[fe80::1]:22')!;
      expect(t.username, 'admin');
      expect(t.host, 'fe80::1');
      expect(t.port, 22);
    });

    test('IPv6 不带端口 [IPv6]', () {
      final t = parseConnectTarget('[::1]')!;
      expect(t.host, '::1');
      expect(t.port, 22);
    });

    test('裸 IPv6（多冒号）整体视为主机名', () {
      final t = parseConnectTarget('fe80::1')!;
      expect(t.host, 'fe80::1');
      expect(t.port, 22);
    });

    test('前后空白被忽略', () {
      final t = parseConnectTarget('  admin@host:2200  ')!;
      expect(t.port, 2200);
    });

    test('空输入返回 null', () {
      expect(parseConnectTarget(''), isNull);
      expect(parseConnectTarget('   '), isNull);
    });

    test('端口非数字报错而非回退 22', () {
      expect(() => parseConnectTarget('host:abc'),
          throwsA(isA<FormatException>()));
    });

    test('端口越界报错', () {
      expect(() => parseConnectTarget('host:0'), throwsA(isA<FormatException>()));
      expect(() => parseConnectTarget('host:65536'),
          throwsA(isA<FormatException>()));
      expect(() => parseConnectTarget('host:-1'),
          throwsA(isA<FormatException>()));
    });

    test('空主机报错', () {
      expect(() => parseConnectTarget('@host'), throwsA(isA<FormatException>()));
      expect(() => parseConnectTarget('admin@'), throwsA(isA<FormatException>()));
      expect(() => parseConnectTarget(':2222'), throwsA(isA<FormatException>()));
    });

    test('IPv6 缺少右括号报错', () {
      expect(() => parseConnectTarget('[::1'), throwsA(isA<FormatException>()));
    });
  });

  group('parseConnectTarget · Telnet 目标', () {
    test('telnet://host 默认 23', () {
      final t = parseConnectTarget('telnet://127.0.0.1')!;
      expect(t.transport, SessionTransport.telnet);
      expect(t.host, '127.0.0.1');
      expect(t.port, 23);
      expect(t.username, '');
    });

    test('telnet://host:port（EVE-NG 控制台链接）', () {
      final t = parseConnectTarget('telnet://127.0.0.1:32768')!;
      expect(t.transport, SessionTransport.telnet);
      expect(t.host, '127.0.0.1');
      expect(t.port, 32768);
    });

    test('协议名大小写不敏感、前后空白与尾部斜杠容错', () {
      final t = parseConnectTarget('  TELNET://192.0.2.110:32769/  ')!;
      expect(t.transport, SessionTransport.telnet);
      expect(t.host, '192.0.2.110');
      expect(t.port, 32769);
    });

    test('telnet://user@host:port 中的用户名被忽略', () {
      final t = parseConnectTarget('telnet://admin@198.51.100.1:32800')!;
      expect(t.transport, SessionTransport.telnet);
      expect(t.host, '198.51.100.1');
      expect(t.port, 32800);
      expect(t.username, '');
    });

    test('telnet:// IPv6', () {
      final t = parseConnectTarget('telnet://[::1]:32768')!;
      expect(t.host, '::1');
      expect(t.port, 32768);
    });

    test('空目标报错', () {
      expect(() => parseConnectTarget('telnet://'),
          throwsA(isA<FormatException>()));
    });

    test('端口越界报错', () {
      expect(() => parseConnectTarget('telnet://host:65536'),
          throwsA(isA<FormatException>()));
      expect(() => parseConnectTarget('telnet://host:abc'),
          throwsA(isA<FormatException>()));
    });
  });

  group('parseConnectTarget · 串口目标', () {
    test('COM3 默认 9600', () {
      final t = parseConnectTarget('COM3')!;
      expect(t.transport, SessionTransport.serial);
      expect(t.host, 'COM3');
      expect(t.port, 9600);
      expect(t.username, '');
    });

    test('小写 com10 归一为大写', () {
      final t = parseConnectTarget('com10')!;
      expect(t.transport, SessionTransport.serial);
      expect(t.host, 'COM10');
    });

    test('COM3@115200 指定波特率', () {
      final t = parseConnectTarget('COM3@115200')!;
      expect(t.transport, SessionTransport.serial);
      expect(t.host, 'COM3');
      expect(t.port, 115200);
    });

    test('波特率非数字报错', () {
      expect(() => parseConnectTarget('COM3@abc'),
          throwsA(isA<FormatException>()));
    });

    test('波特率越界报错', () {
      expect(() => parseConnectTarget('COM3@50'),
          throwsA(isA<FormatException>()));
      expect(() => parseConnectTarget('COM3@0'),
          throwsA(isA<FormatException>()));
    });

    test('串口不吞 SSH 解析：host 名为 COM 开头但带后缀仍按 SSH', () {
      final t = parseConnectTarget('COM3.example.com')!;
      expect(t.transport, SessionTransport.ssh);
      expect(t.host, 'COM3.example.com');
    });
  });
}
