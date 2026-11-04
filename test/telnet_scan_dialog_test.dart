import 'package:eshell/services/telnet_scanner.dart';
import 'package:eshell/state/app_state.dart';
import 'package:eshell/ui/session/telnet_scan_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('扫描对话框：开始扫描 → 分类结果渲染 → 关闭', (tester) async {
    final app = AppState();
    await app.load();
    final scanner = TelnetScanner(
      prober: (host, port) async => switch (port) {
        32770 => const TelnetProbe(
            kind: TelnetProbeKind.telnet, banner: 'IAC 协商'),
        32771 => const TelnetProbe(kind: TelnetProbeKind.silent),
        32772 => const TelnetProbe(
            kind: TelnetProbeKind.nonTelnet, banner: 'HTTP/1.1 400'),
        _ => const TelnetProbe(kind: TelnetProbeKind.closed),
      },
    );

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () =>
                      showTelnetScanDialog(context, scanner: scanner),
                  child: const Text('open-scan'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open-scan'));
    await tester.pumpAndSettle();
    expect(find.text('扫描 Telnet 服务'), findsOneWidget);
    // 默认来自持久化设置：本机 + EVE-NG 常用区间。
    expect(find.text('127.0.0.1'), findsOneWidget);

    await tester.tap(find.text('开始扫描'));
    await tester.pumpAndSettle();

    expect(find.text('发现 3 个开放端口'), findsOneWidget);
    expect(find.textContaining('127.0.0.1:32770'), findsOneWidget);
    expect(find.textContaining('127.0.0.1:32771'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '连接'), findsNWidgets(3));
    // 非 Telnet 响应单独标注，避免误连到 HTTP/SSH 端口。
    expect(find.text('非 Telnet'), findsOneWidget);

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    // 取消挂起的设置写盘防抖计时器，避免测试结束时残留 Timer。
    await app.flushSettings();
  });
}
