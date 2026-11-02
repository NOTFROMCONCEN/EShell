import 'package:eshell/utils/format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('sanitizeFileName · Windows 非法字符', () {
    test('替换非法字符为下划线', () {
      expect(sanitizeFileName(r'a\b/c:d*e?f"g<h>i|j'), 'a_b_c_d_e_f_g_h_i_j');
    });

    test('去除首尾空白', () {
      expect(sanitizeFileName('  core sw  '), 'core sw');
    });

    test('全非法时替换为等长下划线串', () {
      expect(sanitizeFileName(r'\\/:*?"<>|'), '__________');
      expect(sanitizeFileName('   '), 'session');
    });

    test('正常中文名保留', () {
      expect(sanitizeFileName('核心交换机-01'), '核心交换机-01');
    });
  });

  group('时间戳格式', () {
    test('formatTimestamp 人类可读', () {
      final t = DateTime(2026, 10, 27, 3, 22, 9);
      expect(formatTimestamp(t), '2026-10-27 03:22:09');
    });

    test('fileStamp 文件名安全', () {
      final t = DateTime(2026, 1, 5, 8, 7, 2);
      expect(fileStamp(t), '20260105-080702');
    });

    test('fileStamp 缺省为当前时间（格式校验）', () {
      final s = fileStamp();
      expect(RegExp(r'^\d{8}-\d{6}$').hasMatch(s), isTrue);
    });
  });
}
