import 'dart:convert';

import '../state/ai_state.dart';

/// 多窗口协议：业务 ID、通道名与方法名、快照编解码。
///
/// 子窗口与主窗口是不同 Flutter 引擎（独立 isolate），一切共享状态
/// 都经 WindowMethodChannel 的 JSON 快照传输。主窗口是状态权威：
/// AI 子窗口「迁移」对话（弹出带走、关闭迁回），侧栏子窗口只做
/// 远程视图（主窗口节流推送快照、子窗口回传动作）。
class WindowProtocol {
  WindowProtocol._();

  /// 窗口业务 ID（创建窗口时经 arguments 传入，main 入口据此分发）。
  static const businessIdMain = 'main';
  static const businessIdAi = 'ai';
  static const businessIdRail = 'rail';

  /// 主窗口 ↔ AI 子窗口配对通道。
  static const aiChannel = 'eshell/ai-window';

  /// 主窗口 ↔ 会话栏子窗口配对通道。
  static const railChannel = 'eshell/rail-window';

  // ---- AI 通道方法 ----

  /// 子→主：子窗口已就绪，请求初始对话快照。
  static const aiRequestInit = 'aiRequestInit';

  /// 主→子：完整对话快照（初始迁移；收回时子→主同方法反向用）。
  static const aiPushSnapshot = 'aiPushSnapshot';

  /// 子→主：定期备份快照（主窗口持续记录，X 直关也不丢对话）。
  static const aiBackupSnapshot = 'aiBackupSnapshot';

  /// 主→子：请求子窗口回传最新快照并自行关闭（收回流程）。
  static const aiCollectAndClose = 'aiCollectAndClose';

  /// 子→主：请求当前活动会话的终端上下文（payload 带 reqId）。
  static const aiGetContext = 'aiGetContext';

  /// 主→子：上下文应答（payload 带 reqId 与 text）。
  static const aiContextReply = 'aiContextReply';

  /// 子→主：AI 设置已在子窗口修改，主窗口从 prefs 重载。
  static const aiSettingsChanged = 'aiSettingsChanged';

  /// 子→主：把 AI 给出的命令发送到主窗口活动会话
  /// （payload 带 reqId 与 command；主窗口侧执行，命令必须经用户点击确认）。
  static const aiSendCommand = 'aiSendCommand';

  /// 主→子：发送结果应答（payload 带 reqId；error 非空表示失败原因）。
  static const aiSendCommandReply = 'aiSendCommandReply';

  /// 子→主：取「上一次命令发送后」的新增终端输出（payload 带 reqId）。
  static const aiGetOutputDelta = 'aiGetOutputDelta';

  /// 主→子：增量输出应答（payload 带 reqId 与 text）。
  static const aiOutputDeltaReply = 'aiOutputDeltaReply';

  /// 子→主：请求执行 Telnet 端口扫描（payload 带 reqId 与 host/
  /// startPort/endPort；Agent ```scan 块）。
  static const aiTelnetScan = 'aiTelnetScan';

  /// 主→子：扫描摘要应答（payload 带 reqId 与 text）。
  static const aiTelnetScanReply = 'aiTelnetScanReply';

  /// 子→主：子窗口即将真正关闭（X / 收回），主窗口恢复停靠状态并把
  /// 最近备份迁回对话。与 [aiBackupSnapshot] 分离：定期备份只镜像
  /// 数据、绝不能动弹出状态（2026-11-03 修复弹出 3 秒后被重置、
  /// 重复创建子窗口）。
  static const aiWindowClosed = 'aiWindowClosed';

  /// 主→子：把已弹出的 AI 子窗口调到前台（重复点击弹出按钮时）。
  static const aiFocusWindow = 'aiFocusWindow';

  // ---- 会话栏通道方法 ----

  /// 主→子：状态快照（sessions/tabs/activeTabId/filter）。
  static const railPushSnapshot = 'railPushSnapshot';

  /// 子→主：用户动作（type + payload）。
  static const railAction = 'railAction';

  /// 主→子：请求子窗口自行关闭（收回流程）。
  static const railCloseWindow = 'railCloseWindow';

  /// 子→主：子窗口已被用户直接关闭（X），主窗口恢复停靠状态。
  static const railWindowClosed = 'railWindowClosed';

  /// 会话栏动作类型。
  static const railActConnect = 'connect';
  static const railActSetActive = 'setActive';
  static const railActSetFilter = 'setFilter';
  static const railActToggleAiPanel = 'toggleAiPanel';
  static const railActOpenDialog = 'openDialog'; // payload: kind
  static const railActCreateFolder = 'createFolder';
  static const railActRenameFolder = 'renameFolder';
  static const railActDeleteFolder = 'deleteFolder';
  static const railActToggleFolder = 'toggleFolder';
  static const railActMoveSession = 'moveSession';

  /// 从创建参数解析业务 ID（主窗口 arguments 为空）。
  static String businessIdOf(String arguments) {
    try {
      if (arguments.isEmpty) return businessIdMain;
      final json = jsonDecode(arguments);
      if (json is Map<String, dynamic>) {
        return json['businessId'] as String? ?? businessIdMain;
      }
    } catch (_) {}
    return businessIdMain;
  }
}

/// AiChat 的可序列化快照（跨窗口迁移/备份用）。
class AiChatSnapshot {
  const AiChatSnapshot({
    required this.messages,
    required this.sending,
    this.error,
  });

  final List<AiChatMessage> messages;
  final bool sending;
  final String? error;

  Map<String, dynamic> encode() => {
        'messages': [
          for (final m in messages)
            {
              'role': m.role,
              'content': m.content,
              'reasoning': m.reasoning,
              'truncated': m.truncated,
              'interrupted': m.interrupted,
            },
        ],
        'sending': sending,
        if (error != null) 'error': error,
      };

  String encodeJson() => jsonEncode(encode());

  static AiChatSnapshot decode(Map<String, dynamic> json) {
    final rawMessages = json['messages'];
    return AiChatSnapshot(
      messages: [
        if (rawMessages is List)
          for (final m in rawMessages)
            if (m is Map<String, dynamic>)
              AiChatMessage(
                role: m['role'] as String? ?? 'assistant',
                content: m['content'] as String? ?? '',
                reasoning: m['reasoning'] as String? ?? '',
                truncated: m['truncated'] as bool? ?? false,
                interrupted: m['interrupted'] as bool? ?? false,
              ),
      ],
      sending: json['sending'] as bool? ?? false,
      error: json['error'] as String?,
    );
  }

  static AiChatSnapshot? decodeJson(String raw) {
    try {
      final json = jsonDecode(raw);
      if (json is Map<String, dynamic>) return decode(json);
    } catch (_) {}
    return null;
  }

  factory AiChatSnapshot.capture(AiChat chat) => AiChatSnapshot(
        messages: [
          for (final m in chat.messages)
            AiChatMessage(
              role: m.role,
              content: m.content,
              reasoning: m.reasoning,
              truncated: m.truncated,
              interrupted: m.interrupted,
            ),
        ],
        sending: chat.sending,
        error: chat.error,
      );

  /// 恢复到 [chat]（覆盖现有内容；流式状态归位为已完成）。
  void applyTo(AiChat chat) {
    chat.restore(messages: messages, error: error);
  }
}

/// 会话栏子窗口的状态快照。
class RailSnapshot {
  const RailSnapshot({
    required this.sessions,
    required this.tabs,
    required this.activeTabId,
    required this.filter,
    required this.showAiPanel,
    this.folders = const [],
    this.collapsedFolders = const [],
  });

  final List<RailSession> sessions;
  final List<RailTab> tabs;
  final String activeTabId;
  final String filter;
  final bool showAiPanel;
  final List<String> folders;
  final List<String> collapsedFolders;

  Map<String, dynamic> encode() => {
        'sessions': [for (final s in sessions) s.encode()],
        'tabs': [for (final t in tabs) t.encode()],
        'activeTabId': activeTabId,
        'filter': filter,
        'showAiPanel': showAiPanel,
        'folders': folders,
        'collapsedFolders': collapsedFolders,
      };

  String encodeJson() => jsonEncode(encode());

  static RailSnapshot? decodeJson(String raw) {
    try {
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) return null;
      final rawSessions = json['sessions'];
      final rawTabs = json['tabs'];
      return RailSnapshot(
        sessions: [
          if (rawSessions is List)
            for (final s in rawSessions)
              if (s is Map<String, dynamic>) RailSession.decode(s),
        ],
        tabs: [
          if (rawTabs is List)
            for (final t in rawTabs)
              if (t is Map<String, dynamic>) RailTab.decode(t),
        ],
        activeTabId: json['activeTabId'] as String? ?? '',
        filter: json['filter'] as String? ?? '',
        showAiPanel: json['showAiPanel'] as bool? ?? false,
        folders: (json['folders'] as List?)?.whereType<String>().toList() ?? const [],
        collapsedFolders:
            (json['collapsedFolders'] as List?)?.whereType<String>().toList() ?? const [],
      );
    } catch (_) {
      return null;
    }
  }
}

/// 快照中的会话条目（只含列表展示与连接所需字段）。
class RailSession {
  const RailSession({
    required this.id,
    required this.displayName,
    required this.host,
    required this.transport,
    this.tag,
    this.lastConnectedAt,
  });

  final String id;
  final String displayName;
  final String host;
  final String transport;
  final String? tag;
  final DateTime? lastConnectedAt;

  Map<String, dynamic> encode() => {
        'id': id,
        'displayName': displayName,
        'host': host,
        'transport': transport,
        if (tag != null) 'tag': tag,
        if (lastConnectedAt != null)
          'lastConnectedAt': lastConnectedAt!.toIso8601String(),
      };

  factory RailSession.decode(Map<String, dynamic> json) => RailSession(
        id: json['id'] as String? ?? '',
        displayName: json['displayName'] as String? ?? '',
        host: json['host'] as String? ?? '',
        transport: json['transport'] as String? ?? 'ssh',
        tag: json['tag'] as String?,
        lastConnectedAt: json['lastConnectedAt'] == null
            ? null
            : DateTime.tryParse(json['lastConnectedAt'] as String),
      );
}

/// 快照中的标签页条目。
class RailTab {
  const RailTab({
    required this.id,
    required this.sessionId,
    required this.title,
    required this.status,
  });

  final String id;

  /// 对应的会话 id（子窗口把列表条目与连接状态对上号）。
  final String sessionId;
  final String title;
  final String status; // ConnStatus.name

  Map<String, dynamic> encode() => {
        'id': id,
        'sessionId': sessionId,
        'title': title,
        'status': status,
      };

  factory RailTab.decode(Map<String, dynamic> json) => RailTab(
        id: json['id'] as String? ?? '',
        sessionId: json['sessionId'] as String? ?? '',
        title: json['title'] as String? ?? '',
        status: json['status'] as String? ?? 'closed',
      );
}
