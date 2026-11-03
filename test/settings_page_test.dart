import 'package:eshell/state/app_state.dart';
import 'package:eshell/ui/home/session_rail.dart';
import 'package:eshell/ui/settings/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('程序设置页按分组展示设置并实时更新状态', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final app = AppState();
    await app.load();

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: FilledButton(
                  onPressed: () => showSettingsPage(context),
                  child: const Text('打开设置'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开设置'));
    await tester.pumpAndSettle();
    expect(find.text('程序设置'), findsOneWidget);
    expect(find.text('外观与终端'), findsAtLeastNWidgets(1));
    expect(find.text('主题模式'), findsOneWidget);

    await tester.tap(find.widgetWithText(ListTile, '布局'));
    await tester.pumpAndSettle();
    expect(find.text('显示会话侧边栏'), findsOneWidget);
    await tester.tap(find.widgetWithText(SwitchListTile, '显示会话侧边栏'));
    await tester.pumpAndSettle();
    expect(app.settings.showSidebar, isFalse);

    await tester.tap(find.widgetWithText(ListTile, 'Telnet 扫描'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(3));
    await tester.enterText(fields.at(1), '1');
    await tester.enterText(fields.at(2), '5000');
    await tester.pumpAndSettle();
    expect(find.text('单次扫描最多 4096 个端口，请缩小区间'), findsOneWidget);

    await tester.enterText(fields.at(2), '4096');
    await tester.pumpAndSettle();
    expect(app.settings.telnetScanStartPort, 1);
    expect(app.settings.telnetScanEndPort, 4096);
    expect(find.text('单次扫描最多 4096 个端口，请缩小区间'), findsNothing);

    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.text('程序设置'), findsNothing);
    await app.flushSettings();
  });

  testWidgets('会话侧栏的程序设置入口打开统一设置页', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final app = AppState();
    await app.load();

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: Scaffold(body: SessionRail())),
      ),
    );
    await tester.tap(find.byTooltip('程序设置'));
    await tester.pumpAndSettle();

    expect(find.text('程序设置'), findsOneWidget);
    expect(find.text('AI 助手'), findsAtLeastNWidgets(1));
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    await app.flushSettings();
  });
}
