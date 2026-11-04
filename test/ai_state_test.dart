import 'dart:typed_data';

import 'package:eshell/services/ai_client.dart';
import 'package:eshell/services/ai_prompt.dart';
import 'package:eshell/services/secret_store.dart';
import 'package:eshell/state/ai_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('AiSettings', () {
    test('未填 Key 视为未配置', () {
      final settings = AiSettings();
      expect(settings.configured, isFalse);
      settings.update(apiKey: 'demo-key');
      expect(settings.configured, isTrue);
    });

    test('agentMode 默认关闭，持久化往返一致', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = AiSettings();
      await settings.loadFromDisk();
      expect(settings.agentMode, isFalse);
      settings.setAgentMode(true);
      await settings.persist();
      final reloaded = AiSettings();
      await reloaded.loadFromDisk();
      expect(reloaded.agentMode, isTrue);
      reloaded.setAgentMode(false);
      expect(reloaded.agentMode, isFalse);
    });

    test('update 去空白并夹取上下文行数', () {
      final settings = AiSettings();
      settings.update(
        baseUrl: '  https://api.deepseek.com/v1  ',
        model: ' deepseek-chat ',
        contextLines: 5,
      );
      expect(settings.baseUrl, 'https://api.deepseek.com/v1');
      expect(settings.model, 'deepseek-chat');
      expect(settings.contextLines, AiSettings.minContextLines);

      settings.update(contextLines: 9999);
      expect(settings.contextLines, AiSettings.maxContextLines);
    });

    test('思考强度只接受合法档位，非法值被忽略', () {
      final settings = AiSettings();
      expect(settings.reasoningEffort, 'off');
      settings.update(reasoningEffort: 'high');
      expect(settings.reasoningEffort, 'high');
      settings.update(reasoningEffort: 'ultra');
      expect(settings.reasoningEffort, 'high');
      settings.update(reasoningEffort: 'off');
      expect(settings.reasoningEffort, 'off');
    });

    test('API Key 落盘用 DPAPI 密文（可用 reveal 还原）', () {
      final settings = AiSettings()..apiKey = 'demo-key';
      final stored = settings.encryptedApiKey;
      expect(stored, startsWith('dpapi:v1:'));
      expect(SecretStore.reveal(stored), 'demo-key');
    });
  });

  group('AiChat', () {
    test('连接中断保留回复并排除后续请求历史', () {
      final chat = AiChat()
        ..addUser('q')
        ..beginAssistant()
        ..appendChunk('部分内容');
      chat.interrupt('连接中断');
      expect(chat.messages.last.content, '部分内容');
      expect(chat.messages.last.interrupted, isTrue);
      expect(chat.messages.last.pending, isFalse);
      expect(chat.historyForRequest().map((m) => m.content), ['q']);
    });
    test('提问 → 流式追加 → 完成', () {
      final chat = AiChat();
      chat.addUser('分析一下');
      expect(chat.sending, isFalse);

      chat.beginAssistant();
      expect(chat.sending, isTrue);
      expect(chat.messages, hasLength(2));
      expect(chat.messages.last.pending, isTrue);

      chat.appendChunk('结论');
      chat.appendChunk('：正常');
      chat.finishAssistant();
      expect(chat.sending, isFalse);
      expect(chat.messages.last.content, '结论：正常');
      expect(chat.messages.last.pending, isFalse);
    });

    test('失败移除占位消息并保留错误', () {
      final chat = AiChat()
        ..addUser('q')
        ..beginAssistant()
        ..appendChunk('部分');
      chat.fail('HTTP 401');
      expect(chat.error, 'HTTP 401');
      expect(chat.sending, isFalse);
      // 占位消息被移除（仅保留用户提问）。
      expect(chat.messages, hasLength(1));
      expect(chat.messages.single.role, 'user');
    });

    test('finishAssistant 记录截断标志，stop 清除 pending', () {
      final chat = AiChat()
        ..addUser('q')
        ..beginAssistant()
        ..appendChunk('写到一半');
      chat.finishAssistant(truncated: true);
      expect(chat.messages.last.pending, isFalse);
      expect(chat.messages.last.truncated, isTrue);
      expect(chat.sending, isFalse);

      chat.addUser('q2');
      chat.beginAssistant();
      chat.appendChunk('正常');
      chat.finishAssistant();
      expect(chat.messages.last.truncated, isFalse);
    });

    test('停止保留已生成内容', () {
      final chat = AiChat()
        ..addUser('q')
        ..beginAssistant()
        ..appendChunk('部分输出');
      chat.stop();
      expect(chat.sending, isFalse);
      expect(chat.messages.last.pending, isFalse);
      expect(chat.messages.last.content, '部分输出');
    });

    test('思考过程独立累积，完成/失败/停止后保留', () {
      final chat = AiChat()
        ..addUser('q')
        ..beginAssistant()
        ..appendReasoning('先分析')
        ..appendReasoning('路由表')
        ..appendChunk('结论');
      expect(chat.messages.last.reasoning, '先分析路由表');
      expect(chat.messages.last.content, '结论');
      chat.finishAssistant();
      expect(chat.messages.last.reasoning, '先分析路由表');

      // 思考内容不进入请求历史。
      chat.addUser('下一问');
      final history = chat.historyForRequest();
      expect(history.map((m) => m.content), contains('结论'));
      expect(
        history.map((m) => m.content),
        everyElement(isNot(contains('先分析路由表'))),
      );
    });

    test('historyForRequest 只保留最近 N 条且跳过空内容', () {
      final chat = AiChat();
      for (var i = 0; i < 20; i++) {
        chat.addUser('u$i');
        chat.beginAssistant();
        chat.appendChunk('a$i');
        chat.finishAssistant();
      }
      final history = chat.historyForRequest(maxMessages: 4);
      expect(history, hasLength(4));
      expect(history.first.content, 'u18');
      expect(history.last.content, 'a19');
    });

    test('clear 清空对话与错误', () {
      final chat = AiChat()
        ..addUser('q')
        ..beginAssistant();
      chat.fail('err');
      chat.clear();
      expect(chat.messages, isEmpty);
      expect(chat.error, isNull);
      expect(chat.sending, isFalse);
    });

    test('buildAiMessages 注入 system 与上下文', () {
      final messages = buildAiMessages(
        context: '终端上下文',
        prompt: '问题',
        history: const [AiMessage(role: 'user', content: '旧问题')],
      );
      expect(messages.first.role, 'system');
      // 安全约定：AI 不自行执行，命令经用户确认后发送到终端。
      expect(messages.first.content, contains('不能自行执行'));
      expect(messages.first.content, contains('发送到当前终端'));
      // 非 Agent 模式不含 run 块自动执行说明。
      expect(messages.first.content, isNot(contains('Agent 自动执行模式')));
    });

    test('buildAiMessages 空上下文时不拼接上下文段（Agent 续步）', () {
      final messages = buildAiMessages(
        context: '',
        prompt: '继续执行下一步',
        agentMode: true,
      );
      // 无上下文段与分隔符，只有纯提示词。
      expect(messages.last.content, '继续执行下一步');
      expect(messages.last.content, isNot(contains('--- 用户问题 ---')));
    });

    test('historyForRequest 保留最近 16 条并截断超长消息', () {
      final chat = AiChat();
      for (var i = 0; i < 20; i++) {
        chat.messages.add(AiChatMessage(
          role: i.isEven ? 'user' : 'assistant',
          content: 'm$i',
        ));
      }
      chat.messages
          .add(AiChatMessage(role: 'user', content: 'x' * 5000));

      final history = chat.historyForRequest();
      // 窗口从 10 扩到 16：Agent 多步执行时原始任务不易被挤出。
      expect(history, hasLength(16));
      // 最新消息保留，最早的消息被裁掉。
      expect(history.any((m) => m.content == 'm19'), isTrue);
      expect(history.any((m) => m.content == 'm0'), isFalse);
      // 超长消息截断并标注（UI 全文不受影响）。
      expect(history.last.content.length, lessThanOrEqualTo(4100));
      expect(history.last.content, contains('历史消息过长已截断'));
    });

    test('buildAiMessages agentMode 追加 Agent 自动执行说明', () {
      final messages = buildAiMessages(
        context: '终端上下文',
        prompt: '巡检',
        history: const [AiMessage(role: 'user', content: '旧问题')],
        agentMode: true,
      );
      expect(messages.first.content, contains('Agent 自动执行模式'));
      expect(messages.first.content, contains('```run'));
      expect(messages.first.content, contains('不能自行执行'));
      expect(messages[1].content, '旧问题');
      expect(messages.last.role, 'user');
      expect(messages.last.content, contains('终端上下文'));
      expect(messages.last.content, contains('巡检'));
    });
  });

  group('图片附件（多模态）', () {
    AiImage png([int seed = 1]) => AiImage(
        mime: 'image/png', bytes: Uint8List.fromList([seed, 2, 3]));

    test('addUser 保存图片附件，历史保留最近一条带图消息', () {
      final chat = AiChat();
      chat.addUser('第一张图', images: [png(1)]);
      chat.beginAssistant();
      chat.appendChunk('ok');
      chat.finishAssistant();
      chat.addUser('第二张图', images: [png(2)]);
      chat.beginAssistant();
      chat.appendChunk('ok');
      chat.finishAssistant();

      final history = chat.historyForRequest();
      // 只有最近一条带图消息保留图片（之前的图片被剥离，控制请求体量）。
      final withImages = history.where((m) => m.images.isNotEmpty).toList();
      expect(withImages, hasLength(1));
      expect(withImages.single.content, '第二张图');
      expect(withImages.single.images.single.bytes.first, 2);
    });

    test('纯图片消息（无文字）也进入历史', () {
      final chat = AiChat();
      chat.addUser('请结合附图分析。', images: [png(9)]);
      final history = chat.historyForRequest();
      expect(history, hasLength(1));
      expect(history.single.images, hasLength(1));
    });

    test('buildAiMessages 把本次提问图片挂在最后一条 user 消息上', () {
      final messages = buildAiMessages(
        context: '',
        prompt: '看拓扑',
        promptImages: [png(7)],
      );
      expect(messages.last.role, 'user');
      expect(messages.last.images, hasLength(1));
      expect(messages.last.images.single.bytes.first, 7);
    });
  });
}
