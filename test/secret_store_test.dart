import 'dart:io';

import 'package:eshell/services/secret_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('DPAPI 加密往返（S1）', () {
    if (!Platform.isWindows) return; // 仅 Windows 桌面环境验证。

    const secret = 'p@ssw0rd-中文-😀';
    final stored = SecretStore.protect(secret);

    // 密文带 dpapi:v1 前缀，且不含明文。
    expect(stored, startsWith('dpapi:v1:'));
    expect(stored!.contains(secret), isFalse);

    // 解密还原。
    expect(SecretStore.reveal(stored), secret);
  });

  test('同样的明文两次加密密文不同（DPAPI 随机性）', () {
    if (!Platform.isWindows) return;
    final a = SecretStore.protect('same')!;
    final b = SecretStore.protect('same')!;
    expect(a, isNot(equals(b)));
  });

  test('已加密的值不重复加密', () {
    final once = SecretStore.protect('x')!;
    expect(SecretStore.protect(once), same(once));
  });

  test('空值与 null 透传', () {
    expect(SecretStore.protect(null), isNull);
    expect(SecretStore.protect(''), '');
    expect(SecretStore.reveal(null), isNull);
    expect(SecretStore.reveal(''), '');
  });

  test('历史明文按兼容模式读取', () {
    expect(SecretStore.reveal('legacy-plain'), 'legacy-plain');
  });

  test('损坏的密文解密返回 null（当作未设置）', () {
    if (!Platform.isWindows) return;
    expect(SecretStore.reveal('dpapi:v1:not-valid-base64!!'), isNull);
    expect(SecretStore.reveal('dpapi:v1:QUJD'), isNull);
  });
}
