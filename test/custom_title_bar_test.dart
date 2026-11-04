import 'package:eshell/ui/window/custom_title_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('自定义顶栏提供窗口控制并保留主内容区', (tester) async {
    final calls = <String>[];
    var maximized = false;

    Future<void> record(String action) async {
      calls.add(action);
      if (action == 'maximize') maximized = true;
      if (action == 'unmaximize') maximized = false;
    }

    await tester.pumpWidget(
      MaterialApp(
        home: AppWindowFrame(
          titleBar: CustomTitleBar(
            queryMaximized: () async => maximized,
            onMinimize: () => record('minimize'),
            onMaximize: () => record('maximize'),
            onUnmaximize: () => record('unmaximize'),
            onClose: () => record('close'),
          ),
          child: const ColoredBox(
            key: ValueKey('content'),
            color: Colors.black,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('EShell'), findsOneWidget);
    expect(find.byTooltip('最小化'), findsOneWidget);
    expect(find.byTooltip('最大化'), findsOneWidget);
    expect(find.byTooltip('关闭'), findsOneWidget);
    expect(find.byKey(const ValueKey('content')), findsOneWidget);

    await tester.tap(find.byTooltip('最大化'));
    await tester.pump();
    expect(calls, ['maximize']);
    expect(find.byTooltip('还原'), findsOneWidget);

    await tester.tap(find.byTooltip('还原'));
    await tester.tap(find.byTooltip('最小化'));
    await tester.tap(find.byTooltip('关闭'));
    await tester.pump();
    expect(calls, ['maximize', 'unmaximize', 'minimize', 'close']);
  });

  testWidgets('窗口最大化失败时不误切换为还原状态', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: CustomTitleBar(
          queryMaximized: () async => false,
          onMaximize: () async => throw StateError('native window unavailable'),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('最大化'));
    await tester.pump();
    final titleCenter = tester.getCenter(find.text('EShell'));
    await tester.tapAt(titleCenter);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(titleCenter);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    expect(find.byTooltip('最大化'), findsOneWidget);
    expect(find.byTooltip('还原'), findsNothing);
  });

  testWidgets('标题拖动区双击使用注入的最大化命令', (tester) async {
    var maximizeCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: CustomTitleBar(
          queryMaximized: () async => false,
          onMaximize: () async => maximizeCount++,
        ),
      ),
    );
    await tester.pump();

    final titleCenter = tester.getCenter(find.text('EShell'));
    await tester.tapAt(titleCenter);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(titleCenter);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    expect(maximizeCount, 1);
    expect(find.byTooltip('还原'), findsOneWidget);
  });

  testWidgets('窄窗口下顶栏不产生布局溢出', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 360,
          height: 120,
          child: AppWindowFrame(
            titleBar: CustomTitleBar(
              queryMaximized: () async => false,
              onMinimize: () async {},
              onMaximize: () async {},
              onUnmaximize: () async {},
              onClose: () async {},
            ),
            child: const SizedBox.shrink(),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}
