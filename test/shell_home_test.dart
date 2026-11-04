import 'package:eshell/state/app_state.dart';
import 'package:eshell/ui/home/session_rail.dart';
import 'package:eshell/ui/home/shell_home.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('空状态点「显示侧边栏」可恢复侧栏，再点头部按钮可收起', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final app = AppState();
    await app.load();
    app.settings.setShowSidebar(false);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: ShellHome()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SessionRail), findsNothing);

    // 空状态页左上角的「显示侧边栏」按钮。
    await tester.tap(find.byTooltip('显示侧边栏 (Ctrl+Shift+B)'));
    await tester.pumpAndSettle();
    expect(find.byType(SessionRail), findsOneWidget);

    // 侧栏头部的「隐藏侧边栏」按钮。
    await tester.tap(find.byTooltip('隐藏侧边栏 (Ctrl+Shift+B)'));
    await tester.pumpAndSettle();
    expect(find.byType(SessionRail), findsNothing);
    // 空状态页要同步重建出「显示侧边栏」恢复入口。
    expect(find.byTooltip('显示侧边栏 (Ctrl+Shift+B)'), findsOneWidget);

    await app.flushSettings();
  });

  testWidgets('侧栏可拖动分隔条调整宽度，受边界夹取，双击恢复默认', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final app = AppState();
    await app.load();

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: ShellHome()),
      ),
    );
    await tester.pumpAndSettle();
    expect(app.settings.sidebarWidth, ThemeSettings.defaultSidebarWidth);

    final handle = find.byTooltip('拖动调整侧栏宽度 · 双击恢复默认');
    expect(handle, findsOneWidget);

    // 向右拖 → 侧栏变宽（默认视口 800 宽，maxSidebar = 800-320 = 480，未触顶）。
    await _dragHandle(tester, handle, 50);
    await tester.pumpAndSettle();
    expect(app.settings.sidebarWidth, 350.0);

    // 向左拖越过下限 → 夹取到最小宽度。
    await _dragHandle(tester, handle, -200);
    await tester.pumpAndSettle();
    expect(app.settings.sidebarWidth, ThemeSettings.minSidebarWidth);

    // 双击恢复默认。
    await _doubleTap(tester, handle);
    await tester.pumpAndSettle();
    expect(app.settings.sidebarWidth, ThemeSettings.defaultSidebarWidth);

    // 宽度随设置防抖落盘。
    await _dragHandle(tester, handle, 40);
    await tester.pumpAndSettle();
    await app.flushSettings();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('eshell.sidebarWidth'), 340.0);
  });
}

/// 拖动分隔条：拖拽识别器接受手势之前的增量会被整体丢弃，
/// 所以先用 10px 激活（超过精确指针 slop，触发接受），第二步才是真实 delta。
Future<void> _dragHandle(
    WidgetTester tester, Finder finder, double dx) async {
  final center = tester.getCenter(finder);
  final gesture =
      await tester.startGesture(center, kind: PointerDeviceKind.mouse);
  await gesture.moveBy(Offset(dx < 0 ? -10.0 : 10.0, 0));
  await tester.pump();
  await gesture.moveBy(Offset(dx, 0));
  await tester.pump();
  await gesture.up();
  await tester.pump();
}

/// 模拟双击：两次 down/up 之间隔一个 kDoubleTapMinTime。
Future<void> _doubleTap(WidgetTester tester, Finder finder) async {
  final center = tester.getCenter(finder);
  final gesture = await tester.startGesture(center);
  await gesture.up();
  await tester.pump(kDoubleTapMinTime + const Duration(milliseconds: 20));
  await gesture.down(center);
  await gesture.up();
  await tester.pump();
}
