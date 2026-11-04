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
  static const kPrefAgentMode = 'eshell.aiAgentMode';

  String baseUrl = defaultBaseUrl;
  String model = defaultModel;
  String apiKey = '';
  int contextLines = defaultContextLines;

  /// 思考强度：'off'（默认，不发送）/ low / medium / high，
  /// 作为 `reasoning_effort` 随请求发送；需要模型支持。
  String reasoningEffort = defaultReasoningEffort;

  /// Agent 自动执行模式：开启后回复中的 ```run 命令块自动写入当前
  /// 终端（危险命令仍经安全分级确认），并自动继续多步任务。
  bool agentMode = false;

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
    bool? agentMode,
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
    if (agentMode != null && agentMode != this.agentMode) {
      this.agentMode = agentMode;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  void setAgentMode(bool value) => update(agentMode: value);

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
    await prefs.setBool(kPrefAgentMode, agentMode);
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
      agentMode: prefs.getBool(kPrefAgentMode) ?? agentMode,
    );
  }
}

/// 一条聊天消息。[pending] 表示 assistant 回复正在流式输出。
class AiChatMessage {
  AiChatMessage({
    required this.role,
    required this.content,
    this.images = const [],
    this.reasoning = '',
    this.truncated = false,
    this.interrupted = false,
    this.pending = false,
  });

  final String role; // user / assistant
  String content;

  /// 用户消息附带的图片（多模态；assistant 回复恒为空）。
  final List<AiImage> images;

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

  void addUser(String text, {List<AiImage> images = const []}) {
    error = null;
    messages.add(AiChatMessage(role: 'user', content: text, images: images));
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
  ///
  /// [maxMessages] 保留最近 N 条消息；[maxCharsPerMessage] 对单条消息做
  /// 字符上限截断（UI 保留全文，仅进入请求的历史被压缩）——避免长回复 /
  /// 工具结果把上下文窗口撑爆导致模型「失忆」。
  ///
  /// 图片只在「最近一条带图消息」上保留（多轮追问仍能引用图片），
  /// 更早的历史图片会被剥离，避免每次请求重复编码多张大图。
  List<AiMessage> historyForRequest({
    int maxMessages = 16,
    int maxCharsPerMessage = 4000,
  }) {
    final history = messages
        .where((m) => m.role == 'assistant' || m.role == 'user')
        .where((m) => m.content.trim().isNotEmpty || m.images.isNotEmpty)
        .where((m) => !m.interrupted)
        .toList();
    final recent = history.length > maxMessages
        ? history.sublist(history.length - maxMessages)
        : history;
    String cap(String content) => content.length <= maxCharsPerMessage
        ? content
        : '${content.substring(0, maxCharsPerMessage)}\n…（历史消息过长已截断）';
    var imagesKept = false;
    final result = <AiMessage>[];
    for (final m in recent.reversed) {
      var images = const <AiImage>[];
      if (!imagesKept && m.images.isNotEmpty) {
        images = m.images;
        imagesKept = true;
      }
      result.insert(0, AiMessage(role: m.role, content: cap(m.content), images: images));
    }
    return result;
  }
}
