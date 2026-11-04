import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/ai_client.dart';
import '../services/secret_store.dart';

/// AI 助手设置：OpenAI 兼容接口地址 / 模型 / API Key / 上下文行数 / 思考强度。
///
/// API Key 在内存中是明文，落盘时由 [SecretStore]（Windows DPAPI）加密；
/// 存储键见 [kPrefBaseUrl] 等（主窗口与子窗口读写同一份磁盘设置）。
class AiSettings extends ChangeNotifier {
  static const defaultBaseUrl = 'https://api.deepseek.com/v1';
  static const defaultModel = 'deepseek-chat';
  static const defaultContextLines = 150;
  static const minContextLines = 30;
  static const maxContextLines = 500;
  static const defaultReasoningEffort = 'off';

  /// 持久化键（public：AI 子窗口直接读写同一份磁盘设置）。
  static const kPrefBaseUrl = 'eshell.aiBaseUrl';
  static const kPrefModel = 'eshell.aiModel';
  static const kPrefApiKey = 'eshell.aiApiKey';
  static const kPrefContextLines = 'eshell.aiContextLines';
  static const kPrefReasoningEffort = 'eshell.aiReasoningEffort';

  String baseUrl = defaultBaseUrl;
  String model = defaultModel;
  String apiKey = '';
  int contextLines = defaultContextLines;

  /// 思考强度：'off'（默认，不发送）/ low / medium / high，
  /// 作为 `reasoning_effort` 随请求发送；需要模型支持。
  String reasoningEffort = defaultReasoningEffort;

  bool get configured =>
      apiKey.trim().isNotEmpty &&
      baseUrl.trim().isNotEmpty &&
      model.trim().isNotEmpty;

  /// 内置 DeepSeek 默认值（用户可改 Base URL 切到其它 OpenAI 兼容服务）。
  void applyDefaults() {
    update(
      baseUrl: defaultBaseUrl,
      model: defaultModel,
      contextLines: defaultContextLines,
    );
  }

  void update({
    String? baseUrl,
    String? model,
    String? apiKey,
    int? contextLines,
    String? reasoningEffort,
  }) {
    var changed = false;
    if (baseUrl != null && baseUrl != this.baseUrl) {
      this.baseUrl = baseUrl.trim();
      changed = true;
    }
    if (model != null && model != this.model) {
      this.model = model.trim();
      changed = true;
    }
    if (apiKey != null && apiKey != this.apiKey) {
      this.apiKey = apiKey.trim();
      changed = true;
    }
    if (contextLines != null) {
      final clamped = contextLines.clamp(minContextLines, maxContextLines);
      if (clamped != this.contextLines) {
        this.contextLines = clamped;
        changed = true;
      }
    }
    if (reasoningEffort != null &&
        reasoningEffort != this.reasoningEffort &&
        kAiReasoningEfforts.contains(reasoningEffort)) {
      this.reasoningEffort = reasoningEffort;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  /// 持久化时使用（与 [SecretStore.reveal] 配对）。
  String get encryptedApiKey => SecretStore.protect(apiKey) ?? '';

  /// 把当前设置写入磁盘（主窗口与 AI 子窗口共用；API Key 经 DPAPI）。
  Future<void> persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kPrefBaseUrl, baseUrl);
    await prefs.setString(kPrefModel, model);
    await prefs.setString(kPrefApiKey, encryptedApiKey);
    await prefs.setInt(kPrefContextLines, contextLines);
    await prefs.setString(kPrefReasoningEffort, reasoningEffort);
  }

  /// 从磁盘读入设置（AI 子窗口启动时用；键与 [persist] 一致）。
  Future<void> loadFromDisk() async {
    final prefs = await SharedPreferences.getInstance();
    update(
      baseUrl: prefs.getString(kPrefBaseUrl) ?? baseUrl,
      model: prefs.getString(kPrefModel) ?? model,
      apiKey: SecretStore.reveal(prefs.getString(kPrefApiKey)) ?? '',
      contextLines: prefs.getInt(kPrefContextLines) ?? contextLines,
      reasoningEffort:
          prefs.getString(kPrefReasoningEffort) ?? reasoningEffort,
    );
  }
}

/// 一条聊天消息。[pending] 表示 assistant 回复正在流式输出。
class AiChatMessage {
  AiChatMessage({
    required this.role,
    required this.content,
    this.reasoning = '',
    this.truncated = false,
    this.interrupted = false,
    this.pending = false,
  });

  final String role; // user / assistant
  String content;

  /// assistant 的思考过程（reasoning_content 流式累积；可为空）。
  String reasoning;

  /// 回复因达到 max_tokens 被服务端截断（finish_reason=length）。
  bool truncated;
  bool interrupted;
  bool pending;
}

/// AI 面板会话状态（跨面板开关保留）。
class AiChat extends ChangeNotifier {
  final List<AiChatMessage> messages = [];
  bool sending = false;
  String? error;

  void clear() {
    messages.clear();
    sending = false;
    error = null;
    notifyListeners();
  }

  /// 用快照覆盖恢复（AI 对话从子窗口迁回主窗口时用）；
  /// 流式状态归位为已完成。
  void restore({
    required List<AiChatMessage> messages,
    String? error,
  }) {
    this.messages
      ..clear()
      ..addAll(messages);
    sending = false;
    this.error = error;
    notifyListeners();
  }

  void addUser(String text) {
    error = null;
    messages.add(AiChatMessage(role: 'user', content: text));
    notifyListeners();
  }

  void beginAssistant() {
    messages.add(AiChatMessage(role: 'assistant', content: '', pending: true));
    sending = true;
    error = null;
    notifyListeners();
  }

  void appendChunk(String chunk) {
    if (messages.isEmpty || chunk.isEmpty) return;
    final last = messages.last;
    if (last.role != 'assistant') return;
    last.content += chunk;
    notifyListeners();
  }

  /// 追加思考过程增量（与正文分开累积，不进入请求历史）。
  void appendReasoning(String chunk) {
    if (messages.isEmpty || chunk.isEmpty) return;
    final last = messages.last;
    if (last.role != 'assistant') return;
    last.reasoning += chunk;
    notifyListeners();
  }

  void finishAssistant({bool truncated = false}) {
    if (messages.isNotEmpty && messages.last.role == 'assistant') {
      messages.last.pending = false;
      messages.last.truncated = truncated;
    }
    sending = false;
    notifyListeners();
  }

  /// 请求失败：移除未完成的 assistant 占位消息，展示错误。
  void fail(String message) {
    if (messages.isNotEmpty && messages.last.pending) {
      messages.removeLast();
    }
    sending = false;
    error = message;
    notifyListeners();
  }

  /// 流式连接中断：保留已收到的部分回复，并提示用户内容不完整。
  void interrupt(String message) {
    if (messages.isNotEmpty && messages.last.role == 'assistant') {
      messages.last.pending = false;
      messages.last.interrupted = true;
    }
    sending = false;
    error = message;
    notifyListeners();
  }

  /// 用户点「停止」：保留已生成内容。
  void stop() {
    sending = false;
    if (messages.isNotEmpty && messages.last.pending) {
      messages.last.pending = false;
    }
    notifyListeners();
  }

  /// 移除最后一条 assistant 消息（重新生成前调用）。
  void popLastAssistant() {
    if (messages.isNotEmpty && messages.last.role == 'assistant') {
      messages.removeLast();
      notifyListeners();
    }
  }

  void dismissError() {
    error = null;
    notifyListeners();
  }

  /// 构建请求历史（不含最新的用户问题；由调用方单独传入 prompt）。
  List<AiMessage> historyForRequest({int maxMessages = 10}) {
    final history = messages
        .where((m) => m.role == 'assistant' || m.role == 'user')
        .where((m) => m.content.trim().isNotEmpty)
        .where((m) => !m.interrupted)
        .toList();
    final recent = history.length > maxMessages
        ? history.sublist(history.length - maxMessages)
        : history;
    return [
      for (final m in recent)
        AiMessage(role: m.role, content: m.content),
    ];
  }
}
