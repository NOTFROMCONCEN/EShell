import 'package:eshell/models/session.dart';
import 'package:eshell/state/app_state.dart';
import 'package:eshell/ui/home/session_rail.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('新建文件夹后可折叠其中的会话', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final app = AppState();
    await app.load();
    await app.upsert(Session(
      id: 's1', name: '核心交换机', host: '127.0.0.1', username: 'admin',
      tag: '生产',
    ));
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: app,
      child: const MaterialApp(home: Scaffold(body: SessionRail())),
    ));
    await tester.pumpAndSettle();
    expect(find.text('核心交换机'), findsOneWidget);
    await tester.tap(find.text('生产'));
    await tester.pumpAndSettle();
    expect(find.text('核心交换机'), findsNothing);
    await tester.tap(find.text('生产'));
    await tester.pumpAndSettle();
    expect(find.text('核心交换机'), findsOneWidget);

    await tester.tap(find.byTooltip('新建文件夹'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '测试');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(app.folders, contains('测试'));
    expect(find.text('测试'), findsOneWidget);
    await tester.tap(find.byType(PopupMenuButton<String>).at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移到：测试'));
    await tester.pumpAndSettle();
    expect(app.sessions.single.tag, '测试');
  });
  testWidgets('侧栏工具行包含快速连接与扫描 Telnet 两个入口', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final app = AppState();
    await app.load();

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: Scaffold(body: SessionRail())),
      ),
    );

    expect(find.text('新建会话'), findsOneWidget);
    expect(find.byIcon(Icons.bolt_rounded), findsOneWidget);
    expect(find.byIcon(Icons.radar_rounded), findsOneWidget);

    final railRect = tester.getRect(find.byType(SessionRail));
    final boltRect = tester.getRect(find.byIcon(Icons.bolt_rounded));
    final radarRect = tester.getRect(find.byIcon(Icons.radar_rounded));
    debugPrint('rail=$railRect bolt=$boltRect radar=$radarRect');
    expect(radarRect.right, lessThanOrEqualTo(railRect.right));
    expect(radarRect.left, greaterThanOrEqualTo(railRect.left));
  });
}
