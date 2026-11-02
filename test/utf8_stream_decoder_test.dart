import 'dart:convert';

import 'package:eshell/utils/utf8_stream_decoder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 「中」= E4 B8 AD，「文」= E6 96 87，「😀」= F0 9F 98 80
  group('Utf8StreamDecoder · C1 跨 TCP 分块', () {
    test('完整字符单块解码', () {
      final d = Utf8StreamDecoder();
      expect(d.convert(utf8.encode('hello 中文')), 'hello 中文');
      expect(d.flush(), '');
    });

    test('3 字节中文字符劈成两半（2+1）', () {
      final d = Utf8StreamDecoder();
      final bytes = utf8.encode('中');
      expect(d.convert(bytes.sublist(0, 2)), '');
      expect(d.convert(bytes.sublist(2)), '中');
    });

    test('3 字节中文字符劈成两半（1+2）', () {
      final d = Utf8StreamDecoder();
      final bytes = utf8.encode('中文');
      // 第一块只有「中」的首字节。
      expect(d.convert(bytes.sublist(0, 1)), '');
      // 第二块是「中」的后两字节 + 「文」的完整三字节。
      expect(d.convert(bytes.sublist(1)), '中文');
    });

    test('4 字节 emoji 跨块', () {
      final d = Utf8StreamDecoder();
      final bytes = utf8.encode('x😀y');
      expect(d.convert(bytes.sublist(0, 2)), 'x');
      expect(d.convert(bytes.sublist(2)), '😀y');
    });

    test('连续多字节逐字节喂入', () {
      final d = Utf8StreamDecoder();
      final out = StringBuffer();
      for (final b in utf8.encode('终端中文字符串')) {
        out.write(d.convert([b]));
      }
      out.write(d.flush());
      expect(out.toString(), '终端中文字符串');
    });

    test('ASCII 与多字节混合且边界落在 ASCII', () {
      final d = Utf8StreamDecoder();
      final bytes = utf8.encode('a中b文c');
      expect(d.convert(bytes.sublist(0, 2)), 'a');
      expect(d.convert(bytes.sublist(2, 4)), '中');
      expect(d.convert(bytes.sublist(4)), 'b文c');
    });

    test('flush 输出尾部不完整序列（容错）', () {
      final d = Utf8StreamDecoder();
      final bytes = utf8.encode('中');
      expect(d.convert(bytes.sublist(0, 1)), '');
      // 流中断，残缺序列按 allowMalformed 输出替换符。
      expect(d.flush().codeUnitAt(0), equals(0xFFFD));
    });

    test('非法字节序列输出替换符而不抛异常', () {
      final d = Utf8StreamDecoder();
      final out = d.convert([0x61, 0xFF, 0x62]);
      expect(out.codeUnitAt(0), 0x61);
      expect(out.contains(String.fromCharCode(0xFFFD)), isTrue);
      expect(d.flush(), '');
    });

    test('多块累积后 pending 不泄漏（多轮收发）', () {
      final d = Utf8StreamDecoder();
      final out = StringBuffer();
      final payload = utf8.encode('路由器 GigabitEthernet0/0/1 状态 UP ✓');
      // 模拟 MTU 7 字节的分块。
      for (var i = 0; i < payload.length; i += 7) {
        out.write(
            d.convert(payload.sublist(i, (i + 7).clamp(0, payload.length))));
      }
      out.write(d.flush());
      expect(out.toString(), '路由器 GigabitEthernet0/0/1 状态 UP ✓');
    });
  });
}
