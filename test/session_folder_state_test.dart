import 'package:eshell/models/session.dart';
import 'package:eshell/services/session_store.dart';
import 'package:eshell/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Session session(String id, {String? folder}) => Session(
  id: id,
  name: '会话$id',
  host: '127.0.0.1',
  username: 'admin',
  tag: folder,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('旧版分组标签自动成为文件夹，空文件夹也能持久化', () async {
    await SessionStore.saveSessions([
      session('1', folder: '生产'),
      session('2', folder: ' 生产 '),
    ]);
    final app = AppState();
    await app.load();
    expect(app.folders, ['生产']);
    expect(app.sessions.map((s) => s.tag), everyElement('生产'));
    await app.createFolder('测试');
    expect(app.groupedSessions['测试'], isEmpty);

    final reloaded = AppState();
    await reloaded.load();
    expect(reloaded.folders, ['生产', '测试']);
    expect(reloaded.groupedSessions['测试'], isEmpty);
  });

  test('移动、重命名和删除文件夹不会删除会话', () async {
    final app = AppState();
    await app.load();
    await app.upsert(session('1'));
    await app.createFolder('生产');
    await app.moveSessionToFolder('1', '生产');
    expect(app.sessions.single.tag, '生产');
    await app.renameFolder('生产', '核心');
    expect(app.folders, ['核心']);
    expect(app.sessions.single.tag, '核心');
    await app.deleteFolder('核心');
    expect(app.folders, isEmpty);
    expect(app.sessions.single.tag, isNull);

    final reloaded = AppState();
    await reloaded.load();
    expect(reloaded.sessions, hasLength(1));
    expect(reloaded.sessions.single.tag, isNull);
  });

  test('文件夹名称校验与折叠状态持久化', () async {
    final app = AppState();
    await app.load();
    await app.createFolder('生产');
    await expectLater(app.createFolder('  '), throwsFormatException);
    await expectLater(app.createFolder('生产'), throwsFormatException);
    await app.toggleFolder('生产');
    expect(app.collapsedFolders, contains('生产'));

    final reloaded = AppState();
    await reloaded.load();
    expect(reloaded.collapsedFolders, contains('生产'));
  });

  test('历史标签规范化后会回写到会话存储', () async {
    await SessionStore.saveSessions([
      session('1', folder: ' 生产 '),
      session('2', folder: '生产'),
    ]);

    final app = AppState();
    await app.load();
    expect(app.folders, ['生产']);
    expect(app.sessions.map((s) => s.tag), everyElement('生产'));

    final persisted = await SessionStore.loadSessions();
    expect(persisted.map((s) => s.tag), everyElement('生产'));
  });

  test('文件夹名称拒绝超长和控制字符', () async {
    final app = AppState();
    await app.load();

    await expectLater(app.createFolder('a' * 65), throwsFormatException);
    await expectLater(app.createFolder('含\n换行'), throwsFormatException);
    await expectLater(app.createFolder('含\u0000控制符'), throwsFormatException);
  });

  test('upsert 会规范化会话标签并创建规范文件夹', () async {
    final app = AppState();
    await app.load();

    await app.upsert(session('1', folder: ' 生产 '));
    expect(app.folders, ['生产']);
    expect(app.sessions.single.tag, '生产');

    final reloaded = AppState();
    await reloaded.load();
    expect(reloaded.folders, ['生产']);
    expect(reloaded.sessions.single.tag, '生产');
  });

  test('重复或旧格式的折叠文件夹会去重并回写', () async {
    SharedPreferences.setMockInitialValues({
      'eshell.folders': ['生产'],
      'eshell.collapsedFolders': ['生产', '生产', '生产'],
    });

    final app = AppState();
    await app.load();
    expect(app.collapsedFolders, {'生产'});

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('eshell.collapsedFolders'), ['生产']);
  });

  test('upsert 复用已有文件夹的规范拼写并拒绝非法标签', () async {
    final app = AppState();
    await app.load();
    await app.createFolder('Prod');

    await app.upsert(session('1', folder: ' prod '));
    expect(app.folders, ['Prod']);
    expect(app.sessions.single.tag, 'Prod');

    await expectLater(
      app.upsert(session('2', folder: 'bad\nfolder')),
      throwsFormatException,
    );
  });

  test('并发文件夹操作按提交顺序串行落盘', () async {
    final app = AppState();
    await app.load();

    await Future.wait([app.createFolder('甲'), app.createFolder('乙')]);

    expect(app.folders, ['甲', '乙']);
    final reloaded = AppState();
    await reloaded.load();
    expect(reloaded.folders, ['甲', '乙']);
  });
}
