import 'dart:io';
import 'dart:typed_data';

import 'package:eshell/services/telnet_scanner.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List bytes(List<int> values) => Uint8List.fromList(values);

List<int> ascii(String text) => text.codeUnits;

void main() {
  group('parsePortRange · 扫描区间校验', () {
    test('合法区间', () {
      final range = parsePortRange('32768', '32800');
      expect(range.start, 32768);
      expect(range.end, 32800);
    });

    test('前后空白被忽略', () {
      expect(parsePortRange(' 23 ', ' 2323 ').end, 2323);
    });

    test('非数字报错', () {
      expect(() => parsePortRange('abc', '100'),
          throwsA(isA<FormatException>()));
      expect(() => parsePortRange('1', ''),
          throwsA(isA<FormatException>()));
    });

    test('越界报错', () {
      expect(() => parsePortRange('0', '10'), throwsA(isA<FormatException>()));
      expect(() => parsePortRange('1', '65536'),
          throwsA(isA<FormatException>()));
    });

    test('起止倒置报错', () {
      expect(() => parsePortRange('100', '99'),
          throwsA(isA<FormatException>()));
    });

    test('超过单次上限报错（防手滑扫 6 万端口）', () {
      expect(() => parsePortRange('1', '65535'),
          throwsA(isA<FormatException>()));
    });

    test('恰好等于上限允许', () {
      expect(parsePortRange('1', '$kMaxTelnetScanPorts').end,
          kMaxTelnetScanPorts);
    });
  });

  group('classifyTelnetProbe · 端口性质判断', () {
    test('空数据 → silent', () {
      expect(classifyTelnetProbe(const []), TelnetProbeKind.silent);
    });

    test('含 IAC 协商 → telnet', () {
      expect(classifyTelnetProbe(const [255, 251, 1]),
          TelnetProbeKind.telnet);
    });

    test('可读提示符 → console', () {
      expect(
        classifyTelnetProbe([0x0D, 0x0A, ...ascii('Router>')]),
        TelnetProbeKind.console,
      );
    });

    test('HTTP 响应 → nonTelnet', () {
      expect(
        classifyTelnetProbe(ascii('HTTP/1.1 200 OK\r\n\r\n')),
        TelnetProbeKind.nonTelnet,
      );
    });

    test('SSH 横幅 → nonTelnet', () {
      expect(
        classifyTelnetProbe(ascii('SSH-2.0-OpenSSH_9.0\r\n')),
        TelnetProbeKind.nonTelnet,
      );
    });

    test('TLS 握手 → nonTelnet', () {
      expect(classifyTelnetProbe(const [0x16, 0x03, 0x01, 0x00, 0x05]),
          TelnetProbeKind.nonTelnet);
    });

    test('二进制垃圾 → nonTelnet', () {
      expect(classifyTelnetProbe(const [0x00, 0x01, 0x02, 0x03]),
          TelnetProbeKind.nonTelnet);
    });
  });

  group('sanitizeTelnetProbeBanner · 回显清洗', () {
    test('剥离 IAC 协商后保留设备横幅', () {
      final raw = [
        255, 251, 1, // IAC WILL ECHO
        255, 250, 24, 1, 255, 240, // TTYPE SEND 子协商
        ...ascii('Router>'),
      ];
      expect(sanitizeTelnetProbeBanner(raw), 'Router>');
    });

    test('换行/控制字符压缩为单个空格', () {
      expect(sanitizeTelnetProbeBanner(ascii('a\r\n\tb')), 'a b');
    });

    test('去除 ANSI 颜色序列', () {
      final raw = [...ascii('\x1B[1;32mOK\x1B[0m')];
      expect(sanitizeTelnetProbeBanner(raw), 'OK');
    });

    test('超长回显截断并加省略号', () {
      final raw = ascii('x' * 120);
      final text = sanitizeTelnetProbeBanner(raw, maxLength: 20);
      expect(text.length, 21);
      expect(text.endsWith('…'), isTrue);
    });
  });

  group('TelnetScanner · 假探测器', () {
    test('只返回开放端口，且按端口升序', () async {
      final scanner = TelnetScanner(
        concurrency: 4,
        prober: (host, port) async => switch (port) {
          32770 => const TelnetProbe(kind: TelnetProbeKind.silent),
          32772 => const TelnetProbe(
              kind: TelnetProbeKind.telnet, banner: 'IAC'),
          _ => const TelnetProbe(kind: TelnetProbeKind.closed),
        },
      );
      final results = await scanner.scan(
        host: '127.0.0.1',
        startPort: 32768,
        endPort: 32774,
      );
      expect(results.map((r) => r.port).toList(), [32770, 32772]);
      expect(results.map((r) => r.kind).toList(), [
        TelnetProbeKind.silent,
        TelnetProbeKind.telnet,
      ]);
      expect(results.last.banner, 'IAC');
    });

    test('进度回调覆盖全部端口', () async {
      final scanner = TelnetScanner(
        concurrency: 2,
        prober: (host, port) async =>
            const TelnetProbe(kind: TelnetProbeKind.closed),
      );
      final progress = <TelnetScanProgress>[];
      await scanner.scan(
        host: 'h',
        startPort: 1,
        endPort: 5,
        onProgress: progress.add,
      );
      expect(progress.length, 5);
      expect(progress.last.scanned, 5);
      expect(progress.last.total, 5);
      expect(progress.last.found, 0);
    });

    test('取消后不再继续探测（返回部分结果）', () async {
      var probes = 0;
      final scanner = TelnetScanner(
        concurrency: 1,
        prober: (host, port) async {
          probes++;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          return const TelnetProbe(kind: TelnetProbeKind.silent);
        },
      );
      final results = await scanner.scan(
        host: 'h',
        startPort: 1,
        endPort: 10,
        isCancelled: () => probes >= 2,
      );
      expect(probes, 2);
      expect(results.length, 2);
    });
  });

  group('probeTelnetPort · 真实本地监听', () {
    test('主动发送 IAC 协商 → telnet', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final clients = <Socket>[];
      server.listen((socket) {
        clients.add(socket);
        socket.add(bytes([255, 251, 1]));
        socket.listen((_) {});
      });
      try {
        final probe = await probeTelnetPort(
          '127.0.0.1',
          server.port,
          bannerWindow: const Duration(milliseconds: 120),
          probeWindow: const Duration(milliseconds: 120),
        );
        expect(probe.kind, TelnetProbeKind.telnet);
      } finally {
        for (final c in clients) {
          c.destroy();
        }
        await server.close();
      }
    });

    test('设备提示符回显 → console', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final clients = <Socket>[];
      server.listen((socket) {
        clients.add(socket);
        socket.add(bytes(ascii('Router>')));
        socket.listen((_) {});
      });
      try {
        final probe = await probeTelnetPort(
          '127.0.0.1',
          server.port,
          bannerWindow: const Duration(milliseconds: 120),
          probeWindow: const Duration(milliseconds: 120),
        );
        expect(probe.kind, TelnetProbeKind.console);
        expect(probe.banner, contains('Router>'));
      } finally {
        for (final c in clients) {
          c.destroy();
        }
        await server.close();
      }
    });

    test('静默监听（EVE-NG 直通控制台形态）→ silent，且探测会补发回车', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final clients = <Socket>[];
      final received = <int>[];
      server.listen((socket) {
        clients.add(socket);
        socket.listen(received.addAll);
      });
      try {
        final probe = await probeTelnetPort(
          '127.0.0.1',
          server.port,
          bannerWindow: const Duration(milliseconds: 120),
          probeWindow: const Duration(milliseconds: 120),
        );
        expect(probe.kind, TelnetProbeKind.silent);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(received, containsAll(const [0x0D, 0x0A]));
      } finally {
        for (final c in clients) {
          c.destroy();
        }
        await server.close();
      }
    });

    test('HTTP 响应 → nonTelnet', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final clients = <Socket>[];
      server.listen((socket) {
        clients.add(socket);
        socket.add(bytes(ascii('HTTP/1.1 400 Bad Request\r\n\r\n')));
        socket.listen((_) {});
      });
      try {
        final probe = await probeTelnetPort(
          '127.0.0.1',
          server.port,
          bannerWindow: const Duration(milliseconds: 120),
          probeWindow: const Duration(milliseconds: 120),
        );
        expect(probe.kind, TelnetProbeKind.nonTelnet);
      } finally {
        for (final c in clients) {
          c.destroy();
        }
        await server.close();
      }
    });

    test('未监听的端口 → closed', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      await server.close();
      final probe = await probeTelnetPort(
        '127.0.0.1',
        port,
        connectTimeout: const Duration(milliseconds: 500),
      );
      expect(probe.kind, TelnetProbeKind.closed);
    });
  });
}
