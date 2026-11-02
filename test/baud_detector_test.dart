import 'dart:convert';
import 'dart:typed_data';

import 'package:eshell/services/baud_detector.dart';
import 'package:flutter_test/flutter_test.dart';

/// 构造「可打印控制台输出」样本。
Uint8List _text(String s) => Uint8List.fromList(utf8.encode(s));

/// 构造「错误波特率下的随机垃圾」样本：高比例非可打印字节。
Uint8List _garbage(int seed, int length) {
  final out = Uint8List(length);
  var x = seed;
  for (var i = 0; i < length; i++) {
    x = (x * 1103515245 + 12345) & 0x7FFFFFFF;
    // 取值偏向前 256 空间的低区段，包含大量控制字符。
    out[i] = (x >> 16) & 0xFF;
  }
  return out;
}

void main() {
  group('BaudDetector.scoreSample', () {
    test('正常控制台文本接近满分', () {
      final s = BaudDetector.scoreSample(
          _text('\r\nUsername: admin\r\nPassword: ****\r\n<H3C>'));
      expect(s, greaterThan(0.95));
    });

    test('中文 UTF-8 控制台输出按整序列计可打印', () {
      final s = BaudDetector.scoreSample(
          _text('\r\n系统时钟同步完成，链路状态正常。\r\n请重新登录。\r\n'));
      expect(s, greaterThan(0.95));
    });

    test('错误波特率垃圾样本得分低', () {
      final s = BaudDetector.scoreSample(_garbage(7, 200));
      expect(s, lessThan(0.6));
    });

    test('空样本得 0 分', () {
      expect(BaudDetector.scoreSample(const []), 0);
    });

    test('真实设备横幅命中检测', () {
      expect(BaudDetector.hasBanner(_text('User Access Verification')),
          isTrue);
      expect(BaudDetector.hasBanner(_text('Press RETURN to get started')),
          isTrue);
      expect(BaudDetector.hasBanner(_text('<H3C>display clock\r\n')),
          isTrue);
      expect(BaudDetector.hasBanner(_text('[core-sw-01]save force\r\n')),
          isTrue);
      // 无特征的普通文本不算横幅。
      expect(BaudDetector.hasBanner(_text('hello world 12345')), isFalse);
    });

    test('综合得分：横幅加成封顶 1.0，垃圾不加成', () {
      final clean = _text('<H3C>screen-length disable\r\n');
      expect(BaudDetector.score(clean), greaterThanOrEqualTo(0.95));
      final dirty = _garbage(3, 100);
      expect(BaudDetector.score(dirty), BaudDetector.scoreSample(dirty));
    });
  });

  group('BaudDetector.detect · 回调注入驱动', () {
    /// 脚本化环境：按「当前波特率」返回预置样本（模拟真实线路）。
    Future<int?> runScripted({
      required Map<int, List<int>> samplesByBaud,
      List<int> candidates = BaudDetector.candidates,
      void Function(int baud, int attempt, int total)? onProgress,
    }) {
      var current = 0;
      final progress = <int>[];
      return BaudDetector.detect(
        applyBaud: (b) async => current = b,
        clearBuffers: () async {},
        sendProbe: () async {},
        readAvailable: () =>
            samplesByBaud[current] ?? const <int>[],
        wait: (_) async {}, // 测试用假时钟，不真实等待
        onProgress: (b, a, t) {
          progress.add(b);
          onProgress?.call(b, a, t);
        },
        candidates: candidates,
      );
    }

    test('首个候选 9600 干净回显 → 早退直接命中', () async {
      final banner = _text(
          '\r\nUser Access Verification\r\n\r\nUsername: ');
      final detected = await runScripted(samplesByBaud: {
        9600: banner,
        115200: _garbage(1, 100),
      });
      expect(detected, 9600);
    });

    test('9600 是垃圾、115200 干净 → 跳到第二候选', () async {
      final detected = await runScripted(samplesByBaud: {
        9600: _garbage(11, 120),
        115200: _text('<H3C>\r\nUsername: '),
      });
      expect(detected, 115200);
    });

    test('全部候选均为垃圾 → 返回 null（落到兜底）', () async {
      final detected = await runScripted(samplesByBaud: {
        for (final b in BaudDetector.candidates) b: _garbage(b, 150),
      });
      expect(detected, isNull);
    });

    test('全部候选静默（空样本）→ 返回 null', () async {
      final detected = await runScripted(samplesByBaud: {
        for (final b in BaudDetector.candidates) b: const <int>[],
      });
      expect(detected, isNull);
    });

    test('进度回调按候选顺序推进', () async {
      final seen = <int>[];
      await runScripted(
        samplesByBaud: {
          9600: _garbage(5, 120),
          115200: _garbage(6, 120),
          57600: _text('Password: '),
        },
        onProgress: (b, a, t) => seen.add(b),
      );
      expect(seen, [9600, 115200, 57600]);
    });

    test('干净但无横幅的样本达到采纳阈值即可命中', () async {
      final plain = _text('系统时钟同步完成，链路状态正常。\r\n');
      final detected = await runScripted(samplesByBaud: {
        9600: _garbage(9, 120),
        115200: plain,
      });
      expect(detected, 115200);
    });
  });
}
