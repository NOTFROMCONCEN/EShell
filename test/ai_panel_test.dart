import 'dart:async';
import 'dart:convert';

import 'package:eshell/services/ai_agent.dart';
import 'package:eshell/services/ai_client.dart';
import 'package:eshell/state/app_state.dart';
import 'package:eshell/ui/ai/ai_panel.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// 保存对话框 mock：固定返回预设路径。
class _MockSavePlatform extends FileSelectorPlatform {
  _MockSavePlatform(this.saveLocation);

  final FileSaveLocation saveLocation;

  @override
  Future<FileSaveLocation?> getSaveLocation({
    List<XTypeGroup>? acceptedTypeGroups,
    SaveDialogOptions options = const SaveDialogOptions(),
  }) async =>
      saveLocation;
}

/// 保存对话框 mock：用户取消。
class _NullSavePlatform extends FileSelectorPlatform {
  @override
  Future<FileSaveLocation?> getSaveLocation({
    List<XTypeGroup>? acceptedTypeGroups,
    SaveDialogOptions options = const SaveDialogOptions(),
  }) async =>
      null;
}

/// 假流式客户端：把预设片段依次吐出，记录是否被关闭。
class _FakeClient implements AiStreamingClient {
  _FakeClient(this.chunks);

  final List<AiStreamChunk> chunks;
  bool closed = false;
  List<AiMessage>? lastMessages;

  @override
  Stream<AiStreamChunk> streamChat(List<AiMessage> messages) async* {
    lastMessages = messages;
    for (final chunk in chunks) {
      yield chunk;
    }
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

/// 文本片段便捷构造。
AiStreamChunk text(String s) => AiStreamChunk(content: s);

/// 思考片段便捷构造。
AiStreamChunk think(String s) => AiStreamChunk(reasoning: s);

/// 可多次调用的假客户端：每次 streamChat 依次吐出预设的一组片段。
class _MultiFake implements AiStreamingClient {
  _MultiFake(this.responses);

  final List<List<AiStreamChunk>> responses;
  int callIndex = 0;
  final List<List<AiMessage>> calls = [];

  @override
  Stream<AiStreamChunk> streamChat(List<AiMessage> messages) async* {
    calls.add(messages);
    final chunks = responses[callIndex.clamp(0, responses.length - 1)];
    callIndex++;
    for (final chunk in chunks) {
      yield chunk;
    }
  }

  @override
  Future<void> close() async {}
}

Widget _wrap(AppState app, Widget child) {
  return ChangeNotifierProvider.value(
    value: app,
    child: MaterialApp(home: Scaffold(body: child)),
  );
}

void main() {
  testWidgets('上下文尚未返回时连续触发，只发起一次 AI 请求', (tester) async {
    final app = AppState();
    app.ai.update(baseUrl: 'http://127.0.0.1:1/v1', model: 'mock', apiKey: 'key');
    final contextReady = Completer<String>();
    final fake = _MultiFake([[text('ok')]]);
    await tester.pumpWidget(_wrap(app, AiAssistantPanel(
      clientFactory: (_) => fake,
      contextProvider: () => contextReady.future,
    )));
    await tester.tap(find.text('分析当前终端'));
    await tester.tap(find.text('分析当前终端'));
    contextReady.complete('无终端输出');
    await tester.pumpAndSettle();
    expect(fake.calls, hasLength(1));
    expect(app.aiChat.messages, hasLength(2));
  });
  testWidgets('AI 面板：快捷提问 → 流式回复 → 代码块复制按钮', (tester) async {
    final app = AppState();
    app.ai.update(
      baseUrl: 'http://127.0.0.1:1/v1',
      model: 'mock',
      apiKey: 'demo-key',
    );
    final fake = _FakeClient([
      text('结论：缺少默认路由。\n\n'),
      text('```\nip route-static 0.0.0.0 0 198.51.100.1\n```'),
    ]);

    await tester.pumpWidget(_wrap(
      app,
      AiAssistantPanel(clientFactory: (_) => fake),
    ));
    await tester.pumpAndSettle();

    // 只读提示与快捷问题入口。
    expect(find.text('命令需确认执行'), findsOneWidget);
    expect(find.text('分析当前终端'), findsOneWidget);

    await tester.tap(find.text('分析当前终端'));
    await tester.pumpAndSettle();

    expect(app.aiChat.messages, hasLength(2));
    expect(app.aiChat.messages[1].content, contains('ip route-static'));
    expect(app.aiChat.messages[1].pending, isFalse);
    expect(find.byIcon(Icons.copy_rounded), findsOneWidget);
    expect(fake.closed, isTrue);
    // 只读：不会自动打开标签/连接设备。
    expect(app.tabs, isEmpty);

    // 请求里带了 system 提示与终端上下文。
    final messages = fake.lastMessages!;
    expect(messages.first.role, 'system');
    expect(messages.last.content, contains('用户问题'));
  });

  testWidgets('未配置 API Key 时先弹设置对话框，不会发请求', (tester) async {
    final app = AppState(); // 默认未配置 Key
    final fake = _FakeClient([text('不应出现')]);

    await tester.pumpWidget(_wrap(
      app,
      AiAssistantPanel(clientFactory: (_) => fake),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('分析当前终端'));
    await tester.pumpAndSettle();
    expect(find.text('AI 助手设置'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(app.aiChat.messages, isEmpty);
    expect(fake.lastMessages, isNull);
  });

  testWidgets('思考过程默认折叠为 4 行滚动视口，可展开/收起', (tester) async {
    final app = AppState();
    app.ai.update(
      baseUrl: 'http://127.0.0.1:1/v1',
      model: 'mock',
      apiKey: 'demo-key',
    );
    final fake = _FakeClient([
      // 超过 4 行的思考内容，折叠视口才会触达 72px 上限。
      think('第一行思考。\n第二行思考。\n第三行思考。\n'
          '第四行思考。\n第五行思考。\n第六行思考。'),
      text('结论：缺少默认路由。'),
      text('执行 `ip route-static 0.0.0.0 0 198.51.100.1` 即可。'),
    ]);

    await tester.pumpWidget(_wrap(
      app,
      AiAssistantPanel(clientFactory: (_) => fake),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('分析当前终端'));
    // 只 pump 几帧：思考 chunk 已到、正文未完 —— 流式期间也是折叠态。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    expect(find.byType(ShaderMask), findsOneWidget);

    await tester.pumpAndSettle();
    final msg = app.aiChat.messages.last;
    expect(msg.reasoning, contains('第六行思考。'));
    expect(msg.content, contains('缺少默认路由'));
    expect(msg.pending, isFalse);

    // 完成后默认仍是折叠：思考区头部常驻 + 渐隐遮罩视口。
    expect(find.text('思考过程'), findsOneWidget);
    expect(find.byType(ShaderMask), findsOneWidget);
    // 折叠视口限高 4 行。
    final viewport = tester.getSize(find.byType(AnimatedSize));
    expect(viewport.height, lessThanOrEqualTo(72));

    // 手动展开：遮罩消失、动画后全量显示思考文本。
    await tester.tap(find.text('思考过程'));
    await tester.pumpAndSettle();
    expect(find.byType(ShaderMask), findsNothing);
    final expandedSize = tester.getSize(find.byType(AnimatedSize));
    expect(expandedSize.height, greaterThan(viewport.height));

    // 再点一次收起，遮罩恢复。
    await tester.tap(find.text('思考过程'));
    await tester.pumpAndSettle();
    expect(find.byType(ShaderMask), findsOneWidget);

    // 行内 Markdown：`ip route-static ...` 代码片段存在。
    expect(find.textContaining('ip route-static'), findsOneWidget);
  });

  testWidgets('Markdown 块级渲染：标题/列表/命令块（shell 图标 + 复制）', (tester) async {
    final app = AppState();
    app.ai.update(
      baseUrl: 'http://127.0.0.1:1/v1',
      model: 'mock',
      apiKey: 'demo-key',
    );
    final fake = _FakeClient([
      text('## 排查步骤\n\n'),
      text('1. 检查接口状态\n2. 查看路由表\n\n'),
      text('```bash\nsysname R1\n```\n\n> 命令需手动粘贴执行'),
    ]);

    await tester.pumpWidget(_wrap(
      app,
      AiAssistantPanel(clientFactory: (_) => fake),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('分析当前终端'));
    await tester.pumpAndSettle();

    // 标题与列表项渲染为独立文本。
    expect(find.text('排查步骤'), findsOneWidget);
    expect(find.textContaining('检查接口状态'), findsOneWidget);
    expect(find.textContaining('查看路由表'), findsOneWidget);
    // 有序列表标记。
    expect(find.text('1.'), findsOneWidget);
    expect(find.text('2.'), findsOneWidget);
    // bash 命令块：语言标签 + 复制按钮；引用块内容可见。
    expect(find.text('bash'), findsOneWidget);
    expect(find.byIcon(Icons.terminal_rounded), findsOneWidget);
    expect(find.byIcon(Icons.copy_rounded), findsOneWidget);
    expect(find.textContaining('命令需手动粘贴执行'), findsOneWidget);
  });

  testWidgets('finish_reason=length 时提示回复被截断', (tester) async {
    final app = AppState();
    app.ai.update(
      baseUrl: 'http://127.0.0.1:1/v1',
      model: 'mock',
      apiKey: 'demo-key',
    );
    // 假客户端直接吐一个带 finishReason 的 chunk 模拟服务端截断。
    final fake = _FakeClient([
      text('前半段回答。'),
      const AiStreamChunk(finishReason: 'length'),
    ]);

    await tester.pumpWidget(_wrap(
      app,
      AiAssistantPanel(clientFactory: (_) => fake),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('分析当前终端'));
    await tester.pumpAndSettle();

    final msg = app.aiChat.messages.last;
    expect(msg.pending, isFalse);
    expect(msg.truncated, isTrue);
    expect(find.textContaining('被截断'), findsOneWidget);
  });

  testWidgets('正常结束（stop）不显示截断提示', (tester) async {
    final app = AppState();
    app.ai.update(
      baseUrl: 'http://127.0.0.1:1/v1',
      model: 'mock',
      apiKey: 'demo-key',
    );
    final fake = _FakeClient([
      text('完整回答。'),
      const AiStreamChunk(finishReason: 'stop'),
    ]);

    await tester.pumpWidget(_wrap(
      app,
      AiAssistantPanel(clientFactory: (_) => fake),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('分析当前终端'));
    await tester.pumpAndSettle();

    expect(app.aiChat.messages.last.truncated, isFalse);
    expect(find.textContaining('被截断'), findsNothing);
  });

  testWidgets('重新生成：移除末条回复并用上一问重发', (tester) async {
    final app = AppState();
    app.ai.update(
      baseUrl: 'http://127.0.0.1:1/v1',
      model: 'mock',
      apiKey: 'demo-key',
    );
    final fake = _MultiFake([
      [text('第一次回答')],
      [text('重新生成的回答')],
    ]);

    await tester.pumpWidget(_wrap(
      app,
      AiAssistantPanel(clientFactory: (_) => fake),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('分析当前终端'));
    await tester.pumpAndSettle();
    expect(app.aiChat.messages.last.content, '第一次回答');

    // 点「重新生成」：旧回复被替换，请求重新发出。
    await tester.tap(find.text('重新生成'));
    await tester.pumpAndSettle();
    expect(app.aiChat.messages, hasLength(2));
    expect(app.aiChat.messages.last.content, '重新生成的回答');
    expect(app.aiChat.messages.last.pending, isFalse);
    // 第二次请求的历史不含被替换的旧回复。
    final historyContents =
        fake.calls[1].map((m) => m.content).toList();
    expect(historyContents.where((c) => c.contains('第一次回答')), isEmpty);
    expect(fake.calls.last.last.content, contains('用户问题'));
  });

  testWidgets('导出 TXT：保存对话框选位置后写出（头部带元信息）', (tester) async {
    final app = AppState();
    app.ai.update(
      baseUrl: 'http://127.0.0.1:1/v1',
      model: 'mock-model',
      apiKey: 'demo-key',
    );
    final fake = _FakeClient([text('导出的巡检结论。')]);
    String? exportedPath;
    String? exportedText;
    final originalPlatform = FileSelectorPlatform.instance;
    FileSelectorPlatform.instance = _MockSavePlatform(
      const FileSaveLocation(r'C:\export\巡检报告.txt'),
    );
    addTearDown(() => FileSelectorPlatform.instance = originalPlatform);

    await tester.pumpWidget(_wrap(
      app,
      AiAssistantPanel(
        clientFactory: (_) => fake,
        sessionNameProvider: () => '核心交换机',
        // FakeAsync zone 里真实写盘不会完成：注入内存捕获。
        exportWriter: (path, text) async {
          exportedPath = path;
          exportedText = text;
        },
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('分析当前终端'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('导出 TXT'));
    await tester.pumpAndSettle();

    expect(exportedPath, r'C:\export\巡检报告.txt');
    expect(exportedText, contains('EShell AI 导出'));
    expect(exportedText, contains('模型: mock-model'));
    expect(exportedText, contains('会话: 核心交换机'));
    expect(exportedText, contains('导出的巡检结论。'));
    expect(find.textContaining('已导出到'), findsOneWidget);
  });

  testWidgets('导出对话框取消（返回 null）不写文件也无提示', (tester) async {
    final app = AppState();
    app.ai.update(
      baseUrl: 'http://127.0.0.1:1/v1',
      model: 'mock-model',
      apiKey: 'demo-key',
    );
    final fake = _FakeClient([text('内容')]);
    var writerCalled = false;
    final originalPlatform = FileSelectorPlatform.instance;
    FileSelectorPlatform.instance = _NullSavePlatform();
    addTearDown(() => FileSelectorPlatform.instance = originalPlatform);

    await tester.pumpWidget(_wrap(
      app,
      AiAssistantPanel(
        clientFactory: (_) => fake,
        exportWriter: (path, text) async => writerCalled = true,
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('分析当前终端'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('导出 TXT'));
    await tester.pumpAndSettle();
    expect(writerCalled, isFalse);
    expect(find.textContaining('已导出到'), findsNothing);
  });

  test('buildAiExportText 组装头部元信息与正文', () {
    final text = buildAiExportText(
      content: '结论：正常。',
      model: 'deepseek-chat',
      time: DateTime(2026, 11, 3, 12, 5),
      sessionName: '核心交换机',
    );
    expect(text, contains('EShell AI 导出'));
    expect(text, contains('模型: deepseek-chat'));
    expect(text, contains('会话: 核心交换机'));
    expect(text.endsWith('结论：正常。\n'), isTrue);

    // 无会话名（独立窗口导出）省略会话行。
    final noSession = buildAiExportText(
      content: 'abc',
      model: 'm',
      time: DateTime(2026, 11, 3),
    );
    expect(noSession, isNot(contains('会话:')));
  });

  testWidgets('AI 回复里的 GFM 表格渲染为 Table，而非管道纯文本', (tester) async {
    final app = AppState();
    app.ai.update(
      baseUrl: 'http://127.0.0.1:1/v1',
      model: 'mock',
      apiKey: 'demo-key',
    );
    final fake = _FakeClient([
      text('| 层级 | 关注点 |\n'
          '|:---|---:|\n'
          '| 物理层 | 端口 up/down |\n'
          '| 链路层 | STP 状态 |'),
    ]);

    await tester.pumpWidget(_wrap(
      app,
      AiAssistantPanel(clientFactory: (_) => fake),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('分析当前终端'));
    await tester.pumpAndSettle();

    // 表格语义存在；管道字符不按纯文本泄漏。
    expect(find.byType(Table), findsOneWidget);
    // TableRow 是配置类、不进 Element 树，从 Table widget 读 children。
    final table = tester.widget<Table>(find.byType(Table));
    expect(table.children, hasLength(3)); // 表头 + 2 数据行
    expect(find.text('物理层'), findsOneWidget);
    expect(find.text('端口 up/down'), findsOneWidget);
    expect(find.textContaining('| 层级 |'), findsNothing);
    expect(find.textContaining('|---|'), findsNothing);
  });

  testWidgets('命令块「发送到终端」：点击后调用 sender 并反馈成功', (tester) async {
    final app = AppState();
    app.ai.update(
      baseUrl: 'http://127.0.0.1:1/v1',
      model: 'mock',
      apiKey: 'demo-key',
    );
    final fake = _FakeClient([
      text('执行以下命令查看版本：\n\n```\ndisplay version\n```'),
    ]);
    final sent = <String>[];

    await tester.pumpWidget(_wrap(
      app,
      AiAssistantPanel(
        clientFactory: (_) => fake,
        commandSender: (cmd) async {
          sent.add(cmd);
          return null;
        },
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('分析当前终端'));
    await tester.pumpAndSettle();

    // 命令块上有发送按钮；点击后命令经用户确认写入终端。
    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await tester.pumpAndSettle();
    expect(sent, ['display version']);
    expect(find.text('命令已发送到当前终端'), findsOneWidget);
    // 发送成功后按钮变为已发送标记。
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
  });

  testWidgets('命令块发送失败时显示错误文案', (tester) async {
    final app = AppState();
    app.ai.update(
      baseUrl: 'http://127.0.0.1:1/v1',
      model: 'mock',
      apiKey: 'demo-key',
    );
    final fake = _FakeClient([text('```\ndir\n```')]);

    await tester.pumpWidget(_wrap(
      app,
      AiAssistantPanel(
        clientFactory: (_) => fake,
        commandSender: (_) async => '当前会话未连接',
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('分析当前终端'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await tester.pumpAndSettle();

    expect(find.text('当前会话未连接'), findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsNothing);
  });

  testWidgets('未注入 commandSender 时不显示发送按钮（只读兜底）', (tester) async {
    final app = AppState();
    app.ai.update(
      baseUrl: 'http://127.0.0.1:1/v1',
      model: 'mock',
      apiKey: 'demo-key',
    );
    final fake = _FakeClient([text('```\ndir\n```')]);

    await tester.pumpWidget(
        _wrap(app, AiAssistantPanel(clientFactory: (_) => fake)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('分析当前终端'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
    expect(find.byIcon(Icons.copy_rounded), findsOneWidget);
  });

  group('Agent 自动执行模式', () {
    /// 搭建 Agent 模式面板并发送快捷提问。
    /// 返回 (fake 调用记录, 已发送命令, AppState)。
    Future<(List<List<AiMessage>>, List<String>, AppState)> pumpAgent(
      WidgetTester tester,
      List<List<AiStreamChunk>> responses, {
      String? senderError,
      Future<String> Function()? contextProvider,
      Future<String> Function()? outputDeltaProvider,
      Future<String> Function(AgentScanRequest request)? scanProvider,
      List<AgentScanRequest>? scanCalls,
    }) async {
      final app = AppState();
      app.ai.update(
        baseUrl: 'http://127.0.0.1:1/v1',
        model: 'mock',
        apiKey: 'demo-key',
        agentMode: true,
      );
      final fake = _MultiFake(responses);
      final sent = <String>[];

      await tester.pumpWidget(_wrap(
        app,
        AiAssistantPanel(
          clientFactory: (_) => fake,
          contextProvider: contextProvider,
          outputDeltaProvider: outputDeltaProvider,
          scanProvider: scanProvider,
          commandSender: (cmd) async {
            if (senderError != null) return senderError;
            sent.add(cmd);
            return null;
          },
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('分析当前终端'));
      await tester.pumpAndSettle();
      // Agent 链路里的输出稳定等待（800ms 定时器）与续步请求。
      for (var i = 0; i < agentMaxSteps + 1; i++) {
        await tester.pump(const Duration(milliseconds: 900));
        await tester.pumpAndSettle();
      }
      return (fake.calls, sent, app);
    }

    testWidgets('scan 块自动执行扫描并回传摘要 → 模型继续', (tester) async {
      final scanCalls = <AgentScanRequest>[];
      final (calls, sent, app) = await pumpAgent(
        tester,
        [
          [
            text('先扫描本机控制台端口：\n\n```scan\n'
                '{"host":"127.0.0.1","startPort":32768,"endPort":32800}\n```')
          ],
          [text('扫描完成，32769 是 Telnet 控制台。')],
        ],
        scanProvider: (request) async {
          scanCalls.add(request);
          return '32769 → telnet｜\n32770 → silent';
        },
      );

      // 扫描能力被透传给 Agent：不发送终端命令，执行扫描。
      expect(sent, isEmpty);
      expect(scanCalls, hasLength(1));
      expect(scanCalls.single.host, '127.0.0.1');
      expect(scanCalls.single.startPort, 32768);
      expect(scanCalls.single.endPort, 32800);
      expect(calls, hasLength(2));
      expect(
          app.aiChat.messages
              .any((m) => m.content.contains('Telnet 扫描结果')),
          isTrue);
      expect(
          app.aiChat.messages.any((m) => m.content.contains('32769 → telnet')),
          isTrue);
    });

    testWidgets('scan 块不显示「发送到终端」按钮（不把 JSON 当命令发）',
        (tester) async {
      final app = AppState();
      app.ai.update(
        baseUrl: 'http://127.0.0.1:1/v1',
        model: 'mock',
        apiKey: 'demo-key',
      );
      final fake = _FakeClient([
        text('```scan\n{"host":"127.0.0.1","startPort":32768,"endPort":32800}\n```'),
      ]);

      await tester.pumpWidget(_wrap(
        app,
        AiAssistantPanel(
          clientFactory: (_) => fake,
          commandSender: (_) async => null,
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('分析当前终端'));
      await tester.pumpAndSettle();

      expect(find.text('Telnet 扫描（自动执行）'), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
    });

    testWidgets('run 块自动执行 → 回传输出 → 模型继续收尾', (tester) async {
      final (calls, sent, app) = await pumpAgent(tester, [
        [text('查看版本。\n\n```run\ndisplay version\n```')],
        [text('版本信息已确认，巡检完成。')],
      ]);

      expect(sent, ['display version']);
      // 两个回合：执行 + 收尾总结。
      expect(calls, hasLength(2));
      // 回传给模型的最新请求里带「命令执行结果」与续步指令。
      expect(calls.last.last.content, contains('命令已执行完毕'));
      // 对话里能看到执行结果记录与最终结论。
      expect(
          app.aiChat.messages
              .any((m) => m.content.contains('命令执行结果')),
          isTrue);
      expect(find.text('版本信息已确认，巡检完成。'), findsOneWidget);
    });

    testWidgets('危险命令被拦截：不执行、回传拦截说明并继续', (tester) async {
      final (calls, sent, app) = await pumpAgent(tester, [
        [text('尝试重启。\n\n```run\nreboot\n```')],
        [text('已拦截，请手动处理。')],
      ]);

      expect(sent, isEmpty);
      expect(calls, hasLength(2));
      expect(
          app.aiChat.messages
              .any((m) => m.content.contains('自动执行被拦截')),
          isTrue);
    });

    testWidgets('模型不守协议给普通 bash 块时同样自动执行（回退）', (tester) async {
      final (calls, sent, app) = await pumpAgent(tester, [
        [text('采集计划如下。\n\n```bash\ndf -hT\n```\n预期输出：挂载点用量。')],
        [text('=== 结论 ===\n磁盘正常。')],
      ]);

      // 回退生效：普通 shell 块也被自动执行。
      expect(sent, ['df -hT']);
      expect(calls, hasLength(2));
      expect(
          app.aiChat.messages
              .any((m) => m.content.contains('命令执行结果')),
          isTrue);
      expect(find.textContaining('=== 结论 ==='), findsOneWidget);
    });

    testWidgets('增量输出：工具消息只含命令输出，续步请求不再附带整屏上下文',
        (tester) async {
      // 输出增量通道：第一次空（刚发送），随后返回稳定增量。
      var polls = 0;
      const deltas = ['', 'output-1\n', 'output-1\n'];
      Future<String> deltaProvider() async {
        final text = deltas[polls.clamp(0, deltas.length - 1)];
        polls++;
        return text;
      }

      final (calls, sent, app) = await pumpAgent(
        tester,
        [
          [text('```run\ndf -hT\n```')],
          [text('=== 结论 ===\n完成。')],
        ],
        contextProvider: () async => 'MARKER-CONTEXT-200LINES',
        outputDeltaProvider: deltaProvider,
      );

      expect(sent, ['df -hT']);
      // 首轮请求带完整上下文；续步请求不带（不再重复整屏）。
      expect(calls.first.last.content, contains('MARKER-CONTEXT-200LINES'));
      expect(calls.last.last.content,
          isNot(contains('MARKER-CONTEXT-200LINES')));
      expect(calls.last.last.content, contains('继续分析'));
      // 工具消息只含增量输出，不含整屏上下文。
      final tool = app.aiChat.messages
          .lastWhere((m) => m.content.contains('命令执行结果'));
      expect(tool.content, contains('output-1'));
      expect(tool.content, isNot(contains('MARKER-CONTEXT-200LINES')));
    });

    testWidgets('步数达到上限自动暂停并提示', (tester) async {
      final (calls, sent, app) = await pumpAgent(tester, [
        // 每次都返回同一个 run 块响应（_MultiFake 钳位到最后一份）。
        [text('```run\ndisplay version\n```')],
      ]);

      // 初始 1 次 + 11 次续步 = 12 个请求；执行 12 条后暂停。
      expect(calls, hasLength(agentMaxSteps + 1));
      expect(sent, hasLength(agentMaxSteps));
      expect(
          app.aiChat.messages.any((m) => m.content.contains('步数上限')),
          isTrue);
    });
  });

  testWidgets('用户消息附带图片：气泡内渲染缩略图', (tester) async {
    // 1x1 透明 PNG（Image.memory 可解码的最小合法图片）。
    final pngBytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==');
    final app = AppState();
    app.aiChat.addUser('这是网络拓扑，请分析',
        images: [AiImage(mime: 'image/png', bytes: pngBytes)]);
    app.aiChat.beginAssistant();
    app.aiChat.appendChunk('收到拓扑，设备为 CE6800-CE + 两台 Ruijie 交换机。');
    app.aiChat.finishAssistant();

    await tester.pumpWidget(_wrap(app, const AiAssistantPanel()));
    await tester.pumpAndSettle();

    // 用户气泡里出现图片缩略图与文字。
    expect(find.byType(Image), findsWidgets);
    expect(find.text('这是网络拓扑，请分析'), findsOneWidget);
  });
}
