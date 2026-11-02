import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/session.dart';
import 'secret_store.dart';

/// 会话与 known_hosts 持久化（SharedPreferences / JSON）。
///
/// 口令安全（S1）：password / passphrase 经 DPAPI 加密后入库
/// （`dpapi:v1:` 前缀），旧版明文在读取时兼容、保存时自动升级。
///
/// known_hosts（S3）：改为 `%USERPROFILE%\.eshell\known_hosts` 纯文本
/// （`host:port fingerprint` 每行一条，# 开头为注释），便于查看/备份/迁移；
/// 旧版 SharedPreferences 中的记录首次加载时自动迁移过来。
class SessionStore {
  static const _kSessions = 'eshell.sessions';
  static const _kKnownHostsLegacy = 'eshell.known_hosts';

  /// 测试可注入目录；生产环境为 %USERPROFILE%\.eshell。
  static String? knownHostsDirectory;

  static Directory _knownHostsDir() {
    final base = knownHostsDirectory ??
        Platform.environment['USERPROFILE'] ??
        Directory.systemTemp.path;
    return Directory('$base\\.eshell');
  }

  static File _knownHostsFile() =>
      File('${_knownHostsDir().path}\\known_hosts');

  static Future<List<Session>> loadSessions() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kSessions);
    if (raw == null) return const [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => _sessionFromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static Session _sessionFromJson(Map<String, dynamic> json) {
    final s = Session.fromJson(json);
    // 兼容历史明文；密文在此处解出，模型内存中始终是明文。
    return s.copyWith(
      password: SecretStore.reveal(s.password),
      passphrase: SecretStore.reveal(s.passphrase),
    );
  }

  static Future<void> saveSessions(List<Session> sessions) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(sessions
        .where((s) => !s.isTemporary)
        .map((s) => s
            .copyWith(
              password: SecretStore.protect(s.password),
              passphrase: SecretStore.protect(s.passphrase),
            )
            .toJson())
        .toList());
    await prefs.setString(_kSessions, raw);
  }

  /// host:port -> 公钥指纹（`SHA256:<base64>`）。
  static Future<Map<String, String>> loadKnownHosts() async {
    final file = _knownHostsFile();
    if (!await file.exists()) {
      // 文件不存在时尝试一次性迁移旧版记录（避免每次连接都查 prefs）。
      await _migrateLegacyKnownHosts();
      if (!await _knownHostsFile().exists()) return {};
    }
    try {
      final entries = <String, String>{};
      for (final line in await file.readAsLines()) {
        final trimmed = line.trim();
        if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
        final space = trimmed.indexOf(' ');
        if (space <= 0) continue;
        entries[trimmed.substring(0, space)] = trimmed.substring(space + 1);
      }
      return entries;
    } catch (_) {
      return {};
    }
  }

  static Future<void> rememberHostKey(
      String host, int port, String fingerprint) async {
    final known = await loadKnownHosts();
    known['$host:$port'] = fingerprint;
    await _writeKnownHosts(known);
  }

  static Future<void> _writeKnownHosts(Map<String, String> known) async {
    final dir = _knownHostsDir();
    await dir.create(recursive: true);
    final buffer = StringBuffer(
        '# EShell known_hosts · host:port SHA256指纹 · 手动删除某行可重置信任\n');
    known.forEach((key, value) => buffer.writeln('$key $value'));
    await _knownHostsFile().writeAsString(buffer.toString(), flush: true);
  }

  /// 旧版 SharedPreferences 中的 known_hosts 一次性迁移到文件，然后清除
  /// 旧键。直接写文件，不经 load/remember，避免递归。
  static Future<void> _migrateLegacyKnownHosts() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kKnownHostsLegacy);
    if (raw == null) return;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final legacy = <String, String>{};
      for (final entry in json.entries) {
        final value = entry.value;
        if (value is String) legacy[entry.key] = value;
      }
      await _writeKnownHosts(legacy);
    } catch (_) {
      // 迁移失败不阻塞加载，旧键保留。
      return;
    }
    await prefs.remove(_kKnownHostsLegacy);
  }
}
