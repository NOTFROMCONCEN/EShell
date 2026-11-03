import 'package:eshell/models/session.dart';
import 'package:eshell/state/app_state.dart';
import 'package:eshell/ui/session/session_edit_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('新建会话对话框：切到 Telnet 后保存为 telnet 会话', (tester) async {
    final app = AppState();
    await app.load();

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showSessionEditDialog(context),
                  child: const Text('open-edit'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open-edit'));
    await tester.pumpAndSettle();
    expect(find.text('新建会话'), findsOneWidget);

    // SSH / Telnet / 串口 三选一，默认 SSH。
    expect(find.text('SSH'), findsOneWidget);
    expect(find.text('Telnet'), findsOneWidget);
    expect(find.text('串口'), findsOneWidget);

    await tester.tap(find.text('Telnet'));
    await tester.pumpAndSettle();
    // 端口从 22 切到 23。
    expect(find.text('23'), findsOneWidget);
    // Telnet 模式没有用户名/认证方式。
    expect(find.text('用户名 *'), findsNothing);
    expect(find.text('认证方式'), findsNothing);

    // 名称 / 文件夹选择 / 主机 / 端口。
    await tester.enterText(find.byType(TextField).at(1), '127.0.0.1');
    await tester.pumpAndSettle();

    await tester.tap(find.text('仅保存'));
    await tester.pumpAndSettle();

    expect(app.sessions, hasLength(1));
    final saved = app.sessions.single;
    expect(saved.transport, SessionTransport.telnet);
    expect(saved.host, '127.0.0.1');
    expect(saved.port, 23);
    expect(saved.username, '');
    expect(saved.password, isNull);
  });

  testWidgets('新建会话可以选择已有文件夹', (tester) async {
    final app = AppState();
    await app.load();
    await app.createFolder('生产');
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () => showSessionEditDialog(context),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String?>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('生产').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(1), '127.0.0.1');
    await tester.enterText(find.byType(TextField).at(3), 'admin');
    await tester.pumpAndSettle();
    await tester.tap(find.text('仅保存'));
    await tester.pumpAndSettle();
    expect(app.sessions.single.tag, '生产');
  });

  testWidgets('会话编辑对话框监听打开后的文件夹变化', (tester) async {
    final app = AppState();
    await app.load();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () => showSessionEditDialog(context),
                child: const Text('打开动态编辑'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开动态编辑'));
    await tester.pumpAndSettle();
    await app.createFolder('动态文件夹');
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DropdownButtonFormField<String?>));
    await tester.pumpAndSettle();
    expect(find.text('动态文件夹'), findsOneWidget);
  });

  testWidgets('会话编辑对话框中的文件夹被删除后回退为未分组', (tester) async {
    final app = AppState();
    await app.load();
    await app.createFolder('临时文件夹');
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () => showSessionEditDialog(context),
                child: const Text('打开删除测试'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开删除测试'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String?>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('临时文件夹').last);
    await tester.pumpAndSettle();

    await app.deleteFolder('临时文件夹');
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String?>));
    await tester.pumpAndSettle();
    expect(find.text('未分组'), findsAtLeastNWidgets(1));
    expect(find.text('临时文件夹'), findsNothing);
  });
}
