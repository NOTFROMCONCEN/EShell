import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'ai_context.dart';
import 'window_protocol.dart';
import '../state/app_state.dart';

/// 多窗口宿主（主窗口侧）：负责弹出/收回 AI 助手与会话栏子窗口。
///
/// 状态权威始终在主窗口：
/// - AI 子窗口「迁移」对话——弹出时主窗口对话清空交给子窗口，子窗口
///   定期把快照备份回主窗口（镜像到 AppState.aiChat），收回/X 关闭后
///   对话自然回到主窗口，最多丢最近一个备份周期的增量。
/// - 会话栏子窗口是远程视图——主窗口节流推送状态快照，子窗口回传动作。
///
/// 弹出状态不持久化：应用重启后都回到停靠状态。
class MultiWindowHost extends ChangeNotifier {
  MultiWindowHost(this._app) {
    _registerHandlers();
    _app.addListener(_pushRailSnapshotSoon);
  }

  final AppState _app;

  bool aiPoppedOut = false;
  bool railPoppedOut = false;

  /// AI 子窗口最近一次备份（JSON；恢复镜像已实时写入 aiChat）。
  String? aiBackupJson;

  Timer? _railPushTimer;
  String _lastRailPush = '';

  // ---- 弹出 ----

  Future<void> popOutAi() async {
    if (aiPoppedOut) {
      // 已弹出：把子窗口调到前台，而不是重复创建。
      unawaited(const WindowMethodChannel(WindowProtocol.aiChannel)
          .invokeMethod(WindowProtocol.aiFocusWindow)
          .catchError((_) {}));
      return;
    }
    try {
      // 双向 WindowMethodChannel 按通道名配对通信，无需持有 windowId；
      // controller 仅触发创建。
      await WindowController.create(
        const WindowConfiguration(
          arguments: '{"businessId":"ai"}',
          hiddenAtLaunch: true,
        ),
      );
    } catch (_) {
      // 创建失败：保持停靠状态，不让占位卡卡死。
      return;
    }
    aiPoppedOut = true;
    notifyListeners();
  }

  Future<void> popOutRail() async {
    if (railPoppedOut) return;
    await WindowController.create(
      const WindowConfiguration(
        arguments: '{"businessId":"rail"}',
        hiddenAtLaunch: true,
      ),
    );
    railPoppedOut = true;
    _pushRailSnapshotSoon();
    notifyListeners();
  }

  // ---- 收回 ----

  /// 收回 AI 子窗口（对话迁回停靠面板）。
  Future<void> dockAi() async {
    if (!aiPoppedOut) return;
    try {
      await const WindowMethodChannel(WindowProtocol.aiChannel)
          .invokeMethod(WindowProtocol.aiCollectAndClose);
      // 子窗口会在关闭前回传 aiWindowClosed（含最终备份）。
      // 若应答因窗口销毁而抛错，走下面的 catch 兜底。
    } catch (_) {
      // 子窗口可能已经死了：直接用最近备份恢复。
      _onAiWindowClosed();
    }
  }

  /// 收回会话栏子窗口。
  Future<void> dockRail() async {
    if (!railPoppedOut) return;
    try {
      await const WindowMethodChannel(WindowProtocol.railChannel)
          .invokeMethod(WindowProtocol.railCloseWindow);
    } catch (_) {
      railPoppedOut = false;
      notifyListeners();
    }
  }

  // ---- 主窗口侧通道处理 ----

  void _registerHandlers() {
    const WindowMethodChannel(WindowProtocol.aiChannel)
        .setMethodCallHandler(_handleAiCall);
    const WindowMethodChannel(WindowProtocol.railChannel)
        .setMethodCallHandler(_handleRailCall);
  }

  Future<dynamic> _handleAiCall(MethodCall call) async {
    switch (call.method) {
      case WindowProtocol.aiRequestInit:
        // 子窗口就绪：推送初始对话快照（弹出时刻的对话）。
        await _pushAiSnapshot();
        return null;
      case WindowProtocol.aiBackupSnapshot:
        // 子窗口定期备份：只镜像数据回主窗口对话，供 X 直关兜底；
        // 绝不能动 aiPoppedOut（否则弹出 3 秒后被周期备份重置，
        // 停靠面板回归造成重复显示，且会重复创建子窗口）。
        aiBackupJson = call.arguments is Map
            ? (call.arguments as Map)['snapshot'] as String?
            : call.arguments as String?;
        _mirrorAiBackup(aiBackupJson);
        return null;
      case WindowProtocol.aiWindowClosed:
        // 子窗口真正关闭（X / 收回）：迁回最近备份并恢复停靠状态。
        aiBackupJson = call.arguments is Map
            ? (call.arguments as Map)['snapshot'] as String?
            : aiBackupJson;
        _onAiWindowClosed();
        return null;
      case WindowProtocol.aiGetContext:
        final args = call.arguments as Map? ?? const {};
        final reqId = args['reqId'];
        final text = buildContextFromAppState(_app);
        await const WindowMethodChannel(WindowProtocol.aiChannel).invokeMethod(
          WindowProtocol.aiContextReply,
          {'reqId': reqId, 'text': text},
        );
        return null;
      case WindowProtocol.aiSettingsChanged:
        // AI 设置在子窗口被修改：主窗口从磁盘重载（监听器会同步写盘桥）。
        await _app.ai.loadFromDisk();
        return null;
      default:
        return null;
    }
  }

  Future<void> _pushAiSnapshot() async {
    final snapshot = AiChatSnapshot.capture(_app.aiChat).encodeJson();
    await const WindowMethodChannel(WindowProtocol.aiChannel)
        .invokeMethod(WindowProtocol.aiPushSnapshot, {'snapshot': snapshot});
  }

  /// 把备份快照镜像到主窗口对话（只动数据，不动弹出状态）。
  void _mirrorAiBackup(String? json) {
    final snapshot = json == null ? null : AiChatSnapshot.decodeJson(json);
    if (snapshot != null) {
      snapshot.applyTo(_app.aiChat);
    }
  }

  /// 子窗口已关闭：迁回备份、恢复停靠状态。
  void _onAiWindowClosed() {
    if (!aiPoppedOut) return;
    _mirrorAiBackup(aiBackupJson);
    aiPoppedOut = false;
    notifyListeners();
  }

  Future<dynamic> _handleRailCall(MethodCall call) async {
    switch (call.method) {
      case WindowProtocol.railAction:
        final args = call.arguments as Map? ?? const {};
        await _dispatchRailAction(
          args['type'] as String? ?? '',
          args,
        );
        return null;
      case WindowProtocol.railWindowClosed:
        // 用户直接关闭了会话栏子窗口。
        railPoppedOut = false;
        _railPushTimer?.cancel();
        notifyListeners();
        return null;
      default:
        return null;
    }
  }

  Future<void> _dispatchRailAction(String type, Map args) async {
    final app = _app;
    switch (type) {
      case WindowProtocol.railActConnect:
        final sessionId = args['sessionId'] as String?;
        final session =
            app.sessions.where((s) => s.id == sessionId).firstOrNull;
        if (session != null) app.connect(session);
      case WindowProtocol.railActSetActive:
        app.setActive(args['tabId'] as String? ?? '');
      case WindowProtocol.railActSetFilter:
        app.setFilter(args['value'] as String? ?? '');
      case WindowProtocol.railActToggleAiPanel:
        app.settings.setShowAiPanel(!app.settings.showAiPanel);
      case WindowProtocol.railActOpenDialog:
        _pendingRailDialog = args['kind'] as String?;
        notifyListeners();
      case WindowProtocol.railActCreateFolder:
        await app.createFolder(args['name'] as String? ?? '');
      case WindowProtocol.railActRenameFolder:
        await app.renameFolder(
            args['oldName'] as String? ?? '', args['newName'] as String? ?? '');
      case WindowProtocol.railActDeleteFolder:
        await app.deleteFolder(args['name'] as String? ?? '');
      case WindowProtocol.railActToggleFolder:
        await app.toggleFolder(args['name'] as String? ?? '');
      case WindowProtocol.railActMoveSession:
        await app.moveSessionToFolder(
            args['sessionId'] as String? ?? '', args['folder'] as String?);
    }
  }

  /// 子窗口请求打开的对话框类型（主窗口 UI 消费后清空）。
  String? _pendingRailDialog;
  String? consumePendingRailDialog() {
    final pending = _pendingRailDialog;
    _pendingRailDialog = null;
    return pending;
  }

  // ---- 会话栏快照推送 ----

  void _pushRailSnapshotSoon() {
    if (!railPoppedOut) return;
    // AppState 高频通知（连接状态/流式输出），500ms 节流。
    _railPushTimer ??= Timer(const Duration(milliseconds: 500), () {
      _railPushTimer = null;
      _pushRailSnapshot();
    });
  }

  Future<void> _pushRailSnapshot() async {
    if (!railPoppedOut) return;
    final snapshot = _buildRailSnapshot().encodeJson();
    if (snapshot == _lastRailPush) return;
    _lastRailPush = snapshot;
    try {
      await const WindowMethodChannel(WindowProtocol.railChannel)
          .invokeMethod(WindowProtocol.railPushSnapshot, {
        'snapshot': snapshot,
      });
    } catch (_) {
      // 子窗口已关闭（X）：下一轮 dispatch 处理。
    }
  }

  RailSnapshot _buildRailSnapshot() {
    final app = _app;
    return RailSnapshot(
      sessions: [
        for (final s in app.sessions)
          RailSession(
            id: s.id,
            displayName: s.displayName,
            host: s.host,
            transport: s.transport.name,
            tag: s.tag,
            lastConnectedAt: s.lastConnectedAt,
          ),
      ],
      tabs: [
        for (final t in app.tabs)
          RailTab(
            id: t.id,
            sessionId: t.connection.session.id,
            title: t.title,
            status: t.connection.status.name,
          ),
      ],
      activeTabId: app.activeTabId,
      filter: app.filter,
      showAiPanel: app.settings.showAiPanel,
      folders: List.of(app.folders),
      collapsedFolders: app.collapsedFolders.toList(),
    );
  }

  @override
  void dispose() {
    _app.removeListener(_pushRailSnapshotSoon);
    _railPushTimer?.cancel();
    super.dispose();
  }
}
