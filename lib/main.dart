import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'services/window_host.dart';
import 'services/window_protocol.dart';
import 'state/app_state.dart';
import 'theme/app_theme.dart';
import 'ui/ai/ai_window.dart';
import 'ui/home/rail_window.dart';
import 'ui/home/shell_home.dart';
import 'ui/window/custom_title_bar.dart';

/// 取当前引擎的窗口定义；主窗口 desktop_multi_window 返回空参数，
/// 插件未就绪/异常时按主窗口处理（fromWindowId 不发起平台调用，安全）。
Future<WindowController> _currentWindowSafe() async {
  try {
    return await WindowController.fromCurrentEngine();
  } catch (_) {
    return WindowController.fromWindowId('main');
  }
}

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // 多窗口分发：desktop_multi_window 创建的子窗口仍从本入口启动，
  // 按创建参数里的业务 ID 分流（主窗口无参数）。
  final currentWindow = await _currentWindowSafe();
  switch (WindowProtocol.businessIdOf(currentWindow.arguments)) {
    case WindowProtocol.businessIdAi:
      await runAiWindow();
      return;
    case WindowProtocol.businessIdRail:
      await runRailWindow();
      return;
  }

  await windowManager.ensureInitialized();

  // 初始窗口尺寸按屏幕工作区比例自适应（逻辑像素），
  // 高 DPI 缩放屏（如 200%）不会被固定尺寸撑满整个桌面。
  final size = _adaptiveWindowSize();
  final options = WindowOptions(
    size: size,
    minimumSize: const Size(880, 560),
    center: true,
    title: 'EShell',
    titleBarStyle: TitleBarStyle.hidden,
    windowButtonVisibility: false,
  );
  final appState = AppState();
  await appState.load();

  // 多窗口宿主：弹出/收回 AI 助手与会话栏子窗口；
  // 通知桥接给 AppState，主窗口布局随弹出状态重建。
  final windowHost = MultiWindowHost(appState);
  appState.attachWindowHost(windowHost);

  // C2：接管关窗事件——退出前等待会话日志 flush/close、设置写盘完成。
  final closeHook = _WindowCloseHook(appState);
  await windowManager.waitUntilReadyToShow(options, () async {
    // 重新显式应用逻辑尺寸并居中：规避 window_manager 在
    // 非 100% 缩放屏上初始 size 换算的时序问题。
    await windowManager.setSize(size);
    await windowManager.center();
    await windowManager.show();
    await windowManager.focus();
    // show 之后注册：拦截原生关闭，由 onWindowClose 决定真正退出时机。
    windowManager.addListener(closeHook);
    await windowManager.setPreventClose(true);
  });

  runApp(EShellApp(appState: appState, windowHost: windowHost));
}

/// 取主显示器逻辑尺寸，窗口约占 78% × 82%，并限制上下限。
Size _adaptiveWindowSize() {
  const fallback = Size(1320, 840);
  final view = WidgetsBinding.instance.platformDispatcher.views.firstOrNull;
  final display = view?.display;
  if (view == null || display == null || display.size == Size.zero) {
    return fallback;
  }
  final dpr = view.devicePixelRatio;
  if (dpr <= 0) return fallback;
  final screen = display.size / dpr;
  return Size(
    (screen.width * 0.78).clamp(960.0, 1440.0),
    (screen.height * 0.82).clamp(600.0, 960.0),
  );
}

/// 关窗钩子（C2）：等待所有会话日志落盘、防抖中的设置写盘，再销毁窗口。
/// 每步限时，避免异常情况卡住无法退出。
class _WindowCloseHook with WindowListener {
  _WindowCloseHook(this.appState);

  final AppState appState;
  bool _closing = false;

  @override
  void onWindowClose() {
    if (_closing) return;
    _closing = true;
    unawaited(_flushAndClose());
  }

  Future<void> _flushAndClose() async {
    // 并行停止所有会话日志（各自限时 3s，总耗时不超过 3s）。
    await Future.wait(List.of(appState.tabs).map((tab) async {
      try {
        await tab.connection.stopLogging().timeout(const Duration(seconds: 3));
      } catch (_) {}
    }));
    try {
      await appState.flushSettings().timeout(const Duration(seconds: 2));
    } catch (_) {}
    // 先解除关闭拦截，再走原生关窗路径。
    //
    // 不要改用 windowManager.destroy()：它只 PostQuitMessage、不销毁窗口，
    // 窗口仍存活时 Flutter 引擎退场实测会卡约 12 秒（看似退出卡死）。
    // close() 触发 WM_CLOSE → DefWindowProc → DestroyWindow → WM_DESTROY，
    // 窗口正常销毁后进程立即退出（实测 ~0.25s）。
    await windowManager.setPreventClose(false);
    await windowManager.close();
  }
}

class EShellApp extends StatelessWidget {
  const EShellApp({super.key, required this.appState, required this.windowHost});

  final AppState appState;
  final MultiWindowHost windowHost;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: appState,
      child: DynamicColorBuilder(
        builder: (ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
          return AnimatedBuilder(
            animation: appState.settings,
            builder: (context, _) {
              final resolved = resolveTheme(
                settings: appState.settings,
                lightDynamic: lightDynamic,
                darkDynamic: darkDynamic,
              );
              return MaterialApp(
                title: 'EShell',
                debugShowCheckedModeBanner: false,
                themeMode: resolved.mode,
                theme: AppTheme.of(resolved.light),
                darkTheme: AppTheme.of(resolved.dark),
                home: const AppWindowFrame(child: ShellHome()),
                // 界面缩放（DPI 优化）：文字缩放只改字号，整体缩放等比缩小整屏。
                builder: (context, child) {
                  final settings = appState.settings;
                  Widget content = child!;
                  // 文字缩放（只影响字号）。
                  final textScale = settings.uiTextScale;
                  if (textScale != 1.0) {
                    content = MediaQuery(
                      data: MediaQuery.of(context)
                          .copyWith(textScaler: TextScaler.linear(textScale)),
                      child: content,
                    );
                  }
                  // 整体缩放（文字/图标/间距等比缩小，视觉 DPI 小一号）。
                  final uiScale = settings.uiScale;
                  if (uiScale != 1.0) {
                    content = _UiScaleView(scale: uiScale, child: content);
                  }
                  return content;
                },
              );
            },
          );
        },
      ),
    );
  }
}

/// 整体界面缩放：把逻辑画布放大 1/scale，再整体缩小 scale 绘制。
///
/// 这样文字、图标、间距、控件尺寸一起等比缩小（视觉上 DPI 小一号），
/// 同时逻辑视口变大、能容纳更多内容；窗口尺寸不变、不出现空白边。
class _UiScaleView extends StatelessWidget {
  const _UiScaleView({required this.scale, required this.child});

  final double scale;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final scaledSize = Size(
      media.size.width / scale,
      media.size.height / scale,
    );
    return ClipRect(
      child: OverflowBox(
        alignment: Alignment.topLeft,
        minWidth: 0,
        maxWidth: double.infinity,
        minHeight: 0,
        maxHeight: double.infinity,
        child: Transform.scale(
          scale: scale,
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: scaledSize.width,
            height: scaledSize.height,
            child: MediaQuery(
              data: media.copyWith(size: scaledSize),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}
