import 'package:eshell/state/app_state.dart';
import 'package:eshell/ui/home/terminal_workspace.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('AI 面板可拖动分隔条调整宽度，受边界夹取，双击恢复默认', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final app = AppState();
    await app.load();
    app.settings.setShowAiPanel(true);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: Scaffold(body: TerminalWorkspace())),
      ),
    );
    await tester.pumpAndSettle();
    expect(app.settings.aiPanelWidth, ThemeSettings.defaultAiPanelWidth);

    final handle = find.byTooltip('拖动调整 AI 面板宽度 · 双击恢复默认');
    expect(handle, findsOneWidget);

    // 默认测试视口 800 宽：maxPanelWidth = 800 - 320 = 480。
    // 向左拖 → 面板变宽（未触顶）。
    await _dragHandle(tester, handle, -60);
    await tester.pumpAndSettle();
    expect(app.settings.aiPanelWidth, 460.0);

    // 继续向左拖 → 被窗口可用宽度夹住（保住终端区最小宽度）。
    await _dragHandle(tester, handle, -180);
    await tester.pumpAndSettle();
    expect(app.settings.aiPanelWidth, 480.0);

    // 双击分隔条 → 恢复默认宽度。
    await _doubleTap(tester, handle);
    await tester.pumpAndSettle();
    expect(app.settings.aiPanelWidth, ThemeSettings.defaultAiPanelWidth);

    // 向右拖越过下限 → 被最小宽度夹住。
    await _dragHandle(tester, handle, 130);
    await tester.pumpAndSettle();
    expect(app.settings.aiPanelWidth, ThemeSettings.minAiPanelWidth);

    // 宽度随设置防抖落盘（先 flush 取消挂起的定时器）。
    await app.flushSettings();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('eshell.aiPanelWidth'), ThemeSettings.minAiPanelWidth);
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
