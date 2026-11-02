import 'dart:async';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'state/app_state.dart';
import 'theme/app_theme.dart';
import 'ui/home/shell_home.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await windowManager.ensureInitialized();

  // 初始窗口尺寸按屏幕工作区比例自适应（逻辑像素），
  // 高 DPI 缩放屏（如 200%）不会被固定尺寸撑满整个桌面。
  final size = _adaptiveWindowSize();
  final options = WindowOptions(
    size: size,
    minimumSize: const Size(880, 560),
    center: true,
    title: 'EShell',
    titleBarStyle: TitleBarStyle.normal,
  );
  final appState = AppState();
  await appState.load();

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

  runApp(EShellApp(appState: appState));
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
    for (final tab in List.of(appState.tabs)) {
      try {
        await tab.connection.stopLogging().timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
    try {
      await appState.flushSettings().timeout(const Duration(seconds: 2));
    } catch (_) {}
    await windowManager.destroy();
  }
}

class EShellApp extends StatelessWidget {
  const EShellApp({super.key, required this.appState});

  final AppState appState;

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
                home: const ShellHome(),
                // 界面文字缩放（DPI 优化）：1.0 跟随系统，其余固定放大。
                builder: (context, child) {
                  final scale = appState.settings.uiTextScale;
                  if (scale == 1.0) return child!;
                  return MediaQuery(
                    data: MediaQuery.of(context)
                        .copyWith(textScaler: TextScaler.linear(scale)),
                    child: child!,
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}
