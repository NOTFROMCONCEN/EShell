import 'package:eshell/services/window_protocol.dart';
import 'package:eshell/state/ai_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AiChatSnapshot', () {
    test('capture → encodeJson → decodeJson → applyTo roundtrip', () {
      final chat = AiChat()
        ..addUser('检查路由')
        ..beginAssistant()
        ..appendReasoning('先看路由表')
        ..appendChunk('结论：缺默认路由');
      chat.messages.last.truncated = true;
      chat.messages.last.interrupted = true;
      chat.finishAssistant(truncated: true);

      final restored = AiChat();
      AiChatSnapshot.capture(chat).encodeJson();
      final json = AiChatSnapshot.capture(chat).encodeJson();
      final decoded = AiChatSnapshot.decodeJson(json);
      expect(decoded, isNotNull);
      decoded!.applyTo(restored);

      expect(restored.messages, hasLength(2));
      expect(restored.messages[0].role, 'user');
      expect(restored.messages[0].content, '检查路由');
      expect(restored.messages[1].reasoning, '先看路由表');
      expect(restored.messages[1].truncated, isTrue);
      expect(restored.messages[1].interrupted, isTrue);
      expect(restored.sending, isFalse);
    });

    test('坏 JSON / 空串返回 null，恢复后可继续流式', () {
      expect(AiChatSnapshot.decodeJson('not-json'), isNull);
      expect(AiChatSnapshot.decodeJson(''), isNull);

      // 迁回后的对话可以继续追加（sending 归位）。
      final chat = AiChat()
        ..addUser('q')
        ..beginAssistant()
        ..appendChunk('部分');
      AiChatSnapshot.capture(chat).applyTo(chat);
      expect(chat.sending, isFalse);
      chat.appendChunk('继续');
      expect(chat.messages.last.content, '部分继续');
    });
  });

  group('RailSnapshot', () {
    test('encode → decode roundtrip', () {
      final snapshot = RailSnapshot(
        sessions: [
          RailSession(
            id: 's1',
            displayName: '核心交换机',
            host: '198.51.100.1',
            transport: 'ssh',
            tag: '核心',
            lastConnectedAt: DateTime(2026, 11, 3, 10, 30),
          ),
          const RailSession(
            id: 's2',
            displayName: '防火墙',
            host: '192.0.2.1',
            transport: 'telnet',
          ),
        ],
        tabs: const [
          RailTab(
              id: 't1', sessionId: 's1', title: '核心交换机', status: 'connected'),
        ],
        activeTabId: 't1',
        filter: '核心',
        showAiPanel: true,
        folders: const ['核心', '空文件夹'],
        collapsedFolders: const ['核心'],
      );

      final decoded = RailSnapshot.decodeJson(snapshot.encodeJson());
      expect(decoded, isNotNull);
      expect(decoded!.sessions, hasLength(2));
      expect(decoded.sessions[0].displayName, '核心交换机');
      expect(decoded.sessions[0].lastConnectedAt, DateTime(2026, 11, 3, 10, 30));
      expect(decoded.sessions[1].tag, isNull);
      expect(decoded.sessions[1].lastConnectedAt, isNull);
      expect(decoded.tabs.single.sessionId, 's1');
      expect(decoded.tabs.single.status, 'connected');
      expect(decoded.activeTabId, 't1');
      expect(decoded.filter, '核心');
      expect(decoded.showAiPanel, isTrue);
      expect(decoded.folders, ['核心', '空文件夹']);
      expect(decoded.collapsedFolders, ['核心']);
    });

    test('坏 JSON 返回 null', () {
      expect(RailSnapshot.decodeJson('bad'), isNull);
    });
  });

  test('businessIdOf 解析窗口参数', () {
    expect(
      WindowProtocol.businessIdOf('{"businessId":"ai"}'),
      WindowProtocol.businessIdAi,
    );
    expect(
      WindowProtocol.businessIdOf('{"businessId":"rail"}'),
      WindowProtocol.businessIdRail,
    );
    expect(WindowProtocol.businessIdOf(''), WindowProtocol.businessIdMain);
    expect(WindowProtocol.businessIdOf('bad-json'), WindowProtocol.businessIdMain);
  });
}
