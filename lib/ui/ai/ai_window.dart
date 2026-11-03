import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../../services/window_protocol.dart';
import '../../state/ai_state.dart';
import '../../state/app_state.dart';
import '../../theme/app_theme.dart';
import 'ai_panel.dart';

/// AI 助手独立子窗口入口。
///
/// 对话「迁移」模型：启动后向主窗口拉取对话快照，之后对话在子窗口
/// 自持（请求也由子窗口直连 AI 服务），每 3 秒把快照备份回主窗口；
/// 收回 / 用户点 X 时先备份再关闭，主窗口据此把对话迁回停靠面板。
Future<void> runAiWindow() async {
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(440, 720),
      minimumSize: Size(320, 480),
      center: true,
      title: 'EShell · AI 助手',
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );

  final settings = AiSettings();
  await settings.loadFromDisk();
  final chat = AiChat();

  final channel = const WindowMethodChannel(WindowProtocol.aiChannel);

  // ---- 终端上下文经 IPC 向主窗口索取 ----
  var reqSeq = 0;
  final contextWaiters = <int, Completer<String>>{};

  // ---- 对话迁移与关闭拦截 ----
  void backupSnapshot() {
    unawaited(channel.invokeMethod(WindowProtocol.aiBackupSnapshot, {
      'snapshot': AiChatSnapshot.capture(chat).encodeJson(),
    }).catchError((_) {}));
  }

  Future<void> closeSelf() async {
    // 关闭回执携带最终快照：主窗口据此迁回对话并恢复停靠状态
    // （与周期备份分离，见 WindowProtocol.aiWindowClosed 注释）。
    unawaited(channel.invokeMethod(WindowProtocol.aiWindowClosed, {
      'snapshot': AiChatSnapshot.capture(chat).encodeJson(),
    }).catchError((_) {}));
    await windowManager.setPreventClose(false);
    await windowManager.close();
  }

  await windowManager.setPreventClose(true);
  final closeHook = _AiWindowCloseHook(closeSelf);
  windowManager.addListener(closeHook);

  // 周期备份：主窗口持续镜像对话，X 直关最多丢一个周期。
  final backupTimer =
      Timer.periodic(const Duration(seconds: 3), (_) => backupSnapshot());

  channel.setMethodCallHandler((call) async {
    switch (call.method) {
      case WindowProtocol.aiPushSnapshot:
        // 主窗口推送的对话快照（弹出迁移的初始对话）。
        final args = call.arguments as Map? ?? const {};
        final snapshot =
            AiChatSnapshot.decodeJson(args['snapshot'] as String? ?? '');
        if (snapshot != null) snapshot.applyTo(chat);
        return null;
      case WindowProtocol.aiContextReply:
        final args = call.arguments as Map? ?? const {};
        final reqId = args['reqId'] as int?;
        final text = args['text'] as String? ?? '';
        if (reqId != null) contextWaiters.remove(reqId)?.complete(text);
        return null;
      case WindowProtocol.aiCollectAndClose:
        // 主窗口收回：备份 + 关闭（关闭回执经 closeSelf 触发）。
        await closeSelf();
        return null;
      case WindowProtocol.aiFocusWindow:
        // 重复点击弹出按钮：把已有子窗口调到前台。
        await windowManager.show();
        await windowManager.focus();
        return null;
      default:
        return null;
    }
  });

  // 就绪后向主窗口要初始对话快照。
  unawaited(channel
      .invokeMethod(WindowProtocol.aiRequestInit)
      .catchError((_) {}));

  // 子窗口独立引擎：从磁盘读主题设置（与主窗口外观一致）。
  final themeSettings = ThemeSettings();
  await themeSettings.loadThemeFromPrefs();

  runApp(
    ChangeNotifierProvider.value(
      value: settings,
      child: DynamicColorBuilder(
        builder: (lightDynamic, darkDynamic) {
          final resolved = resolveTheme(
            settings: themeSettings,
            lightDynamic: lightDynamic,
            darkDynamic: darkDynamic,
          );
          return _AiWindowApp(
            chat: chat,
            settings: settings,
            backupAndClose: closeSelf,
            disposeHook: () {
              backupTimer.cancel();
              windowManager.removeListener(closeHook);
            },
            theme: AppTheme.of(resolved.light),
            darkTheme: AppTheme.of(resolved.dark),
            themeMode: resolved.mode,
            contextProvider: () {
              final reqId = ++reqSeq;
              final completer = Completer<String>();
              contextWaiters[reqId] = completer;
              unawaited(channel
                  .invokeMethod(WindowProtocol.aiGetContext, {'reqId': reqId})
                  .catchError((_) {}));
              return completer.future.timeout(
                const Duration(seconds: 2),
                onTimeout: () => '（获取终端上下文超时；请基于通用网络知识回答。）',
              );
            },
          );
        },
      ),
    ),
  );
}

class _AiWindowCloseHook with WindowListener {
  _AiWindowCloseHook(this.onCloseRequested);

  final Future<void> Function() onCloseRequested;
  bool _closing = false;

  @override
  void onWindowClose() {
    if (_closing) return;
    _closing = true;
    unawaited(onCloseRequested());
  }
}

class _AiWindowApp extends StatelessWidget {
  const _AiWindowApp({
    required this.chat,
    required this.settings,
    required this.contextProvider,
    required this.backupAndClose,
    required this.disposeHook,
    required this.theme,
    required this.darkTheme,
    required this.themeMode,
  });

  final AiChat chat;
  final AiSettings settings;
  final Future<String> Function() contextProvider;
  final Future<void> Function() backupAndClose;
  final VoidCallback disposeHook;
  final ThemeData theme;
  final ThemeData darkTheme;
  final ThemeMode themeMode;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      darkTheme: darkTheme,
      themeMode: themeMode,
      home: _AiWindowScaffold(
        chat: chat,
        settings: settings,
        contextProvider: contextProvider,
        backupAndClose: backupAndClose,
        disposeHook: disposeHook,
      ),
    );
  }
}

class _AiWindowScaffold extends StatelessWidget {
  const _AiWindowScaffold({
    required this.chat,
    required this.settings,
    required this.contextProvider,
    required this.backupAndClose,
    required this.disposeHook,
  });

  final AiChat chat;
  final AiSettings settings;
  final Future<String> Function() contextProvider;
  final Future<void> Function() backupAndClose;
  final VoidCallback disposeHook;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AiAssistantPanel(
        chatOverride: chat,
        settingsOverride: settings,
        contextProvider: contextProvider,
        // 独立窗口内没有主窗口的活动会话信息，导出头不写会话行。
        onCloseOverride: () {
          disposeHook();
          unawaited(backupAndClose());
        },
        onSettingsSaved: () {
          // 子窗口保存设置：写盘并通知主窗口重载。
          unawaited(() async {
            await settings.persist();
            await const WindowMethodChannel(WindowProtocol.aiChannel)
                .invokeMethod(WindowProtocol.aiSettingsChanged)
                .catchError((_) {});
          }());
        },
      ),
    );
  }
}
