import 'dart:io';

import 'package:eshell/services/session_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir =
        await Directory.systemTemp.createTemp('eshell_known_hosts_test');
    SessionStore.knownHostsDirectory = tempDir.path;
  });

  tearDown(() async {
    SessionStore.knownHostsDirectory = null;
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  group('known_hosts TOFU 存取（S3 文件化）', () {
    test('首次为空', () async {
      expect(await SessionStore.loadKnownHosts(), isEmpty);
    });

    test('remember 后 load 可读回（TOFU 记录）', () async {
      await SessionStore.rememberHostKey(
          '198.51.100.1', 22, 'SHA256:AAAA1111');
      await SessionStore.rememberHostKey(
          '198.51.100.2', 2222, 'SHA256:BBBB2222');

      final known = await SessionStore.loadKnownHosts();
      expect(known['198.51.100.1:22'], 'SHA256:AAAA1111');
      expect(known['198.51.100.2:2222'], 'SHA256:BBBB2222');
    });

    test('同 host:port 重复记录覆盖旧指纹', () async {
      await SessionStore.rememberHostKey('h', 22, 'SHA256:OLD');
      await SessionStore.rememberHostKey('h', 22, 'SHA256:NEW');
      final known = await SessionStore.loadKnownHosts();
      expect(known['h:22'], 'SHA256:NEW');
      expect(known.length, 1);
    });

    test('known_hosts 文件存在于用户目录 .eshell 下且可读', () async {
      await SessionStore.rememberHostKey('h', 22, 'SHA256:X');
      final file = File('${tempDir.path}\\.eshell\\known_hosts');
      expect(await file.exists(), isTrue);
      final lines = await file.readAsLines();
      expect(lines.any((l) => l.contains('h:22 SHA256:X')), isTrue);
    });

    test('旧版 SharedPreferences 记录自动迁移到文件（S3）', () async {
      SharedPreferences.setMockInitialValues({
        'eshell.known_hosts': '{"old.host:22": "SHA256:LEGACY"}',
      });

      final known = await SessionStore.loadKnownHosts();
      expect(known['old.host:22'], 'SHA256:LEGACY');

      // 迁移完成后旧键清除，避免重复迁移。
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('eshell.known_hosts'), isNull);
      final reloaded = await SessionStore.loadKnownHosts();
      expect(reloaded['old.host:22'], 'SHA256:LEGACY');
    });
  });
}
