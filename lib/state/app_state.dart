import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/session.dart';
import '../services/secret_store.dart';
import '../services/serial_connection.dart';
import '../services/session_store.dart';
import '../services/ssh_service.dart';
import '../services/telnet_connection.dart';
import '../services/terminal_connection.dart';
import '../services/window_host.dart';
import 'ai_state.dart';

/// 外观设置：明暗模式 + Material You 种子色 + DPI 相关缩放。
class ThemeSettings extends ChangeNotifier {
  /// 持久化键（子窗口独立引擎读取同一份磁盘外观设置）。
  static const kPrefThemeMode = 'eshell.themeMode';
  static const kPrefSeedColor = 'eshell.seedColor';
  static const kPrefPreferWallpaper = 'eshell.preferWallpaper';

  ThemeMode mode = ThemeMode.system;

  /// 默认种子色（钢青蓝），与 EShell 品牌色一致。
  int seedColor = 0xFF415F91;

  /// 壁纸动态色可用时优先使用（Windows 上通常不可用，自动回退种子色）。
  bool preferWallpaper = true;

  /// 终端字号（逻辑像素），高 DPI 屏可自行放大缩小。
  double terminalFontSize = 15.0;

  /// 界面文字缩放；1.0 = 跟随系统，>1 为固定放大。
  double uiTextScale = 1.0;

  /// 整体界面缩放（视觉 DPI）：0.9 = 比系统缩放小一号。
  ///
  /// 与 [uiTextScale]（只放大文字）不同，这里对整屏元素（文字、图标、间距、
  /// 控件尺寸）等比缩放，通过 main.dart 的 Transform 实现。
  double uiScale = 0.9;

  /// 可选的整体缩放档位（外观设置里以 SegmentedButton 呈现）。
  static const List<double> uiScaleOptions = [0.75, 0.8, 0.9, 1.0];

  /// 会话日志上次保存的目录；空表示未设置（由系统对话框决定初始位置）。
  String logDirectory = '';

  /// 会话日志脱敏开关（S2）：开启后日志写入掩码文本而非原始字节。
  bool maskSecretsInLog = false;

  /// 侧边栏显示/隐藏（隐藏时腾出全部宽度给终端）。
  bool showSidebar = true;

  /// 左侧会话栏宽度（逻辑像素），可拖动分隔条调整，随设置持久化。
  double sidebarWidth = defaultSidebarWidth;

  /// 侧栏宽度默认值与拖动边界（硬上限；实际还受窗口可用宽度约束）。
  static const double defaultSidebarWidth = 300;
  static const double minSidebarWidth = 220;
  static const double maxSidebarWidth = 480;

  /// 右侧 AI 助手面板显示/隐藏。
  bool showAiPanel = false;

  /// AI 助手面板宽度（逻辑像素），可拖动分隔条调整，随设置持久化。
  double aiPanelWidth = defaultAiPanelWidth;

  /// AI 面板宽度默认值与拖动边界（硬上限；实际还要受窗口可用宽度约束）。
  static const double defaultAiPanelWidth = 400;
  static const double minAiPanelWidth = 280;
  static const double maxAiPanelWidth = 800;

  /// 「扫描 Telnet 服务」上次使用的目标与端口区间（便于重复扫描 EVE-NG）。
  String telnetScanHost = '127.0.0.1';
  int telnetScanStartPort = 32768;
  int telnetScanEndPort = 32800;

  static const double minTerminalFontSize = 10;
  static const double maxTerminalFontSize = 28;

  /// 从磁盘读入外观设置（AI/会话栏子窗口独立引擎启动时用；
  /// 只需主题三件套，不监听后续变更）。
  Future<void> loadThemeFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final modeIdx = prefs.getInt(kPrefThemeMode);
    if (modeIdx != null && modeIdx >= 0 && modeIdx < ThemeMode.values.length) {
      mode = ThemeMode.values[modeIdx];
    }
    final seed = prefs.getInt(kPrefSeedColor);
    if (seed != null) seedColor = seed;
    preferWallpaper = prefs.getBool(kPrefPreferWallpaper) ?? preferWallpaper;
  }

  void setMode(ThemeMode value) {
    mode = value;
    notifyListeners();
  }

  void setSeed(Color color) {
    seedColor = color.toARGB32();
    preferWallpaper = false;
    notifyListeners();
  }

  void setPreferWallpaper(bool value) {
    preferWallpaper = value;
    notifyListeners();
  }

  void setTerminalFontSize(double value) {
    terminalFontSize = value.clamp(minTerminalFontSize, maxTerminalFontSize);
    notifyListeners();
  }

  /// 快捷键步进（Ctrl+= / Ctrl+-），每步 1px。
  void bumpTerminalFontSize(int step) =>
      setTerminalFontSize(terminalFontSize + step);

  void resetTerminalFontSize() => setTerminalFontSize(15.0);

  void setUiTextScale(double value) {
    uiTextScale = value;
    notifyListeners();
  }

  /// 吸附到最近的可用档位，避免 Segment 选中值与选项不匹配。
  static double snapUiScale(double value) {
    var best = uiScaleOptions.first;
    for (final option in uiScaleOptions) {
      if ((option - value).abs() < (best - value).abs()) best = option;
    }
    return best;
  }

  void setUiScale(double value) {
    final snapped = snapUiScale(value);
    if (snapped == uiScale) return;
    uiScale = snapped;
    notifyListeners();
  }

  void setLogDirectory(String value) {
    if (logDirectory == value) return;
    logDirectory = value;
    notifyListeners();
  }

  void setMaskSecretsInLog(bool value) {
    if (maskSecretsInLog == value) return;
    maskSecretsInLog = value;
    notifyListeners();
  }

  void setShowSidebar(bool value) {
    if (showSidebar == value) return;
    showSidebar = value;
    notifyListeners();
  }

  void setSidebarWidth(double value) {
    final clamped = value.clamp(minSidebarWidth, maxSidebarWidth);
    if (sidebarWidth == clamped) return;
    sidebarWidth = clamped;
    notifyListeners();
  }

  void setShowAiPanel(bool value) {
    if (showAiPanel == value) return;
    showAiPanel = value;
    notifyListeners();
  }

  void setAiPanelWidth(double value) {
    final clamped = value.clamp(minAiPanelWidth, maxAiPanelWidth);
    if (aiPanelWidth == clamped) return;
    aiPanelWidth = clamped;
    notifyListeners();
  }

  void setTelnetScanTarget({String? host, int? startPort, int? endPort}) {
    var changed = false;
    if (host != null && host != telnetScanHost) {
      telnetScanHost = host;
      changed = true;
    }
    if (startPort != null && startPort != telnetScanStartPort) {
      telnetScanStartPort = startPort;
      changed = true;
    }
    if (endPort != null && endPort != telnetScanEndPort) {
      telnetScanEndPort = endPort;
      changed = true;
    }
    if (changed) notifyListeners();
  }
}

/// 一个打开的终端标签页。
class ConnectionTab {
  ConnectionTab({required this.id, required this.connection});

  final String id;
  final TerminalConnection connection;

  String get title => connection.session.displayName;
}

class AppState extends ChangeNotifier {
  final ThemeSettings settings = ThemeSettings();

  /// AI 助手设置（API Key 落盘时经 DPAPI 加密）。
  final AiSettings ai = AiSettings();

  /// AI 面板会话状态（面板关掉再打开仍保留对话）。
  final AiChat aiChat = AiChat();

  /// 多窗口宿主（主窗口弹出/收回 AI 与会话栏子窗口；
  /// 由 main 注入。null = 环境不支持多窗口（如测试），UI 隐藏弹出入口）。
  MultiWindowHost? windowHost;

  /// 注入多窗口宿主，并把它的通知桥接给 AppState
  /// （主窗口布局随弹出状态重建；与 settings 桥接同款手法）。
  void attachWindowHost(MultiWindowHost host) {
    windowHost = host;
    host.addListener(notifyListeners);
  }

  final List<Session> sessions = [];
  final List<String> folders = [];
  final Set<String> collapsedFolders = {};
  final List<ConnectionTab> tabs = [];

  String activeTabId = '';
  String filter = '';

  /// 连接状态监听转发表：tab id -> 移除监听用的回调（M2）。
  final Map<String, VoidCallback> _connectionListeners = {};

  /// 派生数据缓存（P5）：会话列表只在会话/过滤条件变化时重建，
  /// 连接状态通知不再触发整列表重排。
  Map<String, List<Session>>? _groupedCache;
  Set<String>? _openIdsCache;
  Future<void> _stateMutationTail = Future<void>.value();

  /// 串行化会话/文件夹的复合写操作，避免并发调用用旧快照互相覆盖。
  Future<void> _enqueueStateMutation(Future<void> Function() operation) {
    final run = _stateMutationTail.then((_) => operation());
    _stateMutationTail = run.catchError((_) {});
    return run;
  }

  Future<void> load() async {
    await _loadSettings();
    await _loadAiSettings();
    settings.addListener(_schedulePersistSettings);
    ai.addListener(_schedulePersistSettings);
    // ThemeSettings 是独立 ChangeNotifier：桥接给 AppState，保证
    // watch<AppState> 的界面（ShellHome 侧栏布局、空状态恢复按钮、
    // 标签条上的侧栏开关等）在设置变化时同步重建。
    // 否则点「显示侧边栏」后布局不重建，表现为按钮没反应。
    settings.addListener(notifyListeners);
    ai.addListener(notifyListeners);
    sessions.addAll(await SessionStore.loadSessions());
    sessions.sort(_compareSessions);
    await _loadFolders();
  }

  static const _kThemeMode = 'eshell.themeMode';
  static const _kSeedColor = 'eshell.seedColor';
  static const _kPreferWallpaper = 'eshell.preferWallpaper';
  static const _kTerminalFontSize = 'eshell.terminalFontSize';
  static const _kUiTextScale = 'eshell.uiTextScale';
  static const _kUiScale = 'eshell.uiScale';
  static const _kLogDirectory = 'eshell.logDirectory';
  static const _kMaskLog = 'eshell.maskSecretsInLog';
  static const _kShowSidebar = 'eshell.showSidebar';
  static const _kSidebarWidth = 'eshell.sidebarWidth';
  static const _kTelnetScanHost = 'eshell.telnetScanHost';
  static const _kTelnetScanStart = 'eshell.telnetScanStartPort';
  static const _kTelnetScanEnd = 'eshell.telnetScanEndPort';
  static const _kShowAiPanel = 'eshell.showAiPanel';
  static const _kAiPanelWidth = 'eshell.aiPanelWidth';
  static const _kFolders = 'eshell.folders';
  static const _kCollapsedFolders = 'eshell.collapsedFolders';
  // AI 设置键统一定义在 AiSettings（主窗口与 AI 子窗口共用同一份磁盘值）。
  static const _kAiBaseUrl = AiSettings.kPrefBaseUrl;
  static const _kAiModel = AiSettings.kPrefModel;
  static const _kAiApiKey = AiSettings.kPrefApiKey;
  static const _kAiContextLines = AiSettings.kPrefContextLines;
  static const _kAiReasoningEffort = AiSettings.kPrefReasoningEffort;
  static const _maxFolderNameLength = 64;

  Future<void> _loadAiSettings() async {
    final prefs = await SharedPreferences.getInstance();
    ai.update(
      baseUrl: prefs.getString(_kAiBaseUrl) ?? ai.baseUrl,
      model: prefs.getString(_kAiModel) ?? ai.model,
      apiKey: SecretStore.reveal(prefs.getString(_kAiApiKey)) ?? '',
      contextLines: prefs.getInt(_kAiContextLines) ?? ai.contextLines,
      reasoningEffort:
          prefs.getString(_kAiReasoningEffort) ?? ai.reasoningEffort,
    );
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final modeIdx = prefs.getInt(_kThemeMode);
    if (modeIdx != null && modeIdx >= 0 && modeIdx < ThemeMode.values.length) {
      settings.mode = ThemeMode.values[modeIdx];
    }
    final seed = prefs.getInt(_kSeedColor);
    if (seed != null) settings.seedColor = seed;
    settings.preferWallpaper =
        prefs.getBool(_kPreferWallpaper) ?? settings.preferWallpaper;
    final fontSize = prefs.getDouble(_kTerminalFontSize);
    if (fontSize != null) {
      settings.setTerminalFontSize(fontSize);
    }
    final textScale = prefs.getDouble(_kUiTextScale);
    if (textScale != null) {
      settings.uiTextScale = textScale;
    }
    settings.setUiScale(prefs.getDouble(_kUiScale) ?? settings.uiScale);
    settings.logDirectory = prefs.getString(_kLogDirectory) ?? '';
    settings.maskSecretsInLog = prefs.getBool(_kMaskLog) ?? false;
    settings.showSidebar = prefs.getBool(_kShowSidebar) ?? true;
    settings.setSidebarWidth(
      prefs.getDouble(_kSidebarWidth) ?? settings.sidebarWidth,
    );
    settings.telnetScanHost =
        prefs.getString(_kTelnetScanHost) ?? settings.telnetScanHost;
    settings.telnetScanStartPort =
        prefs.getInt(_kTelnetScanStart) ?? settings.telnetScanStartPort;
    settings.telnetScanEndPort =
        prefs.getInt(_kTelnetScanEnd) ?? settings.telnetScanEndPort;
    settings.showAiPanel = prefs.getBool(_kShowAiPanel) ?? settings.showAiPanel;
    settings.setAiPanelWidth(
      prefs.getDouble(_kAiPanelWidth) ?? settings.aiPanelWidth,
    );
  }

  /// P4：设置写盘 500ms 防抖（拖字号滑条不再每档写一次盘）。
  Timer? _persistTimer;

  void _schedulePersistSettings() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 500), () {
      unawaited(_writeSettings());
    });
  }

  /// 立即写盘（退出前的兜底，配合关窗钩子调用）。
  Future<void> flushSettings() async {
    _persistTimer?.cancel();
    _persistTimer = null;
    await _writeSettings();
  }

  Future<void> _writeSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kThemeMode, settings.mode.index);
    await prefs.setInt(_kSeedColor, settings.seedColor);
    await prefs.setBool(_kPreferWallpaper, settings.preferWallpaper);
    await prefs.setDouble(_kTerminalFontSize, settings.terminalFontSize);
    await prefs.setDouble(_kUiTextScale, settings.uiTextScale);
    await prefs.setDouble(_kUiScale, settings.uiScale);
    await prefs.setString(_kLogDirectory, settings.logDirectory);
    await prefs.setBool(_kMaskLog, settings.maskSecretsInLog);
    await prefs.setBool(_kShowSidebar, settings.showSidebar);
    await prefs.setDouble(_kSidebarWidth, settings.sidebarWidth);
    await prefs.setString(_kTelnetScanHost, settings.telnetScanHost);
    await prefs.setInt(_kTelnetScanStart, settings.telnetScanStartPort);
    await prefs.setInt(_kTelnetScanEnd, settings.telnetScanEndPort);
    await prefs.setBool(_kShowAiPanel, settings.showAiPanel);
    await prefs.setDouble(_kAiPanelWidth, settings.aiPanelWidth);
    await prefs.setString(_kAiBaseUrl, ai.baseUrl);
    await prefs.setString(_kAiModel, ai.model);
    await prefs.setString(_kAiApiKey, ai.encryptedApiKey);
    await prefs.setInt(_kAiContextLines, ai.contextLines);
    await prefs.setString(_kAiReasoningEffort, ai.reasoningEffort);
  }

  static int _compareSessions(Session a, Session b) {
    final byTag = (a.tag ?? '').compareTo(b.tag ?? '');
    if (byTag != 0) return byTag;
    return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
  }

  List<Session> get filteredSessions {
    final q = filter.trim().toLowerCase();
    if (q.isEmpty) return sessions;
    return sessions
        .where(
          (s) =>
              s.displayName.toLowerCase().contains(q) ||
              s.host.toLowerCase().contains(q) ||
              s.username.toLowerCase().contains(q) ||
              (s.tag ?? '').toLowerCase().contains(q),
        )
        .toList();
  }

  /// 按标签分组，保持插入顺序（结果缓存，P5）。
  Map<String, List<Session>> get groupedSessions =>
      _groupedCache ??= _buildGroupedSessions();

  Map<String, List<Session>> _buildGroupedSessions() {
    final map = <String, List<Session>>{};
    final q = filter.trim().toLowerCase();
    for (final folder in folders) {
      if (q.isEmpty || folder.toLowerCase().contains(q)) {
        map[folder] = [];
      }
    }
    for (final s in filteredSessions) {
      final key = s.tag ?? '';
      map.putIfAbsent(key, () => []).add(s);
    }
    return map;
  }

  Future<void> _loadFolders() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_kFolders) ?? const <String>[];
    folders.clear();
    collapsedFolders.clear();
    final canonicalByKey = <String, String>{};
    for (final name in [
      ...saved,
      ...sessions.map((s) => s.tag).whereType<String>(),
    ]) {
      final canonical = _canonicalFolderName(name);
      if (canonical == null) continue;
      canonicalByKey.putIfAbsent(canonical.toLowerCase(), () => canonical);
    }
    folders.addAll(canonicalByKey.values);

    var sessionsChanged = false;
    // 旧标签可能只有大小写或前后空格不同，统一映射到同一个文件夹。
    for (var i = 0; i < sessions.length; i++) {
      final session = sessions[i];
      final canonical = _canonicalFolderName(session.tag);
      final mapped = canonical == null
          ? null
          : canonicalByKey[canonical.toLowerCase()];
      if (mapped != session.tag) {
        sessions[i] = session.copyWith(tag: mapped);
        sessionsChanged = true;
      }
    }
    sessions.sort(_compareSessions);

    final persistedCollapsed =
        prefs.getStringList(_kCollapsedFolders) ?? const <String>[];
    final normalizedCollapsed = <String>[];
    final normalizedCollapsedSet = <String>{};
    for (final name in persistedCollapsed) {
      final canonical = _canonicalFolderName(name);
      final mapped = canonical == null
          ? null
          : canonicalByKey[canonical.toLowerCase()];
      if (mapped != null && normalizedCollapsedSet.add(mapped)) {
        collapsedFolders.add(mapped);
        normalizedCollapsed.add(mapped);
      }
    }

    final foldersChanged =
        saved.length != folders.length ||
        saved.asMap().entries.any((entry) => entry.value != folders[entry.key]);
    final collapsedChanged =
        persistedCollapsed.length != normalizedCollapsed.length ||
        persistedCollapsed.asMap().entries.any(
          (entry) => entry.value != normalizedCollapsed[entry.key],
        );
    if (sessionsChanged) {
      await SessionStore.saveSessions(sessions);
    }
    if (foldersChanged || collapsedChanged) {
      await _persistFoldersState(folders, collapsedFolders);
    }
  }

  Future<void> _persistFoldersState(
    List<String> nextFolders,
    Set<String> nextCollapsed,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final foldersSaved = await prefs.setStringList(
      _kFolders,
      List<String>.of(nextFolders),
    );
    if (!foldersSaved) {
      throw StateError('文件夹列表写入失败');
    }
    final collapsedSaved = await prefs.setStringList(
      _kCollapsedFolders,
      nextCollapsed.where(nextFolders.contains).toList(),
    );
    if (!collapsedSaved) {
      throw StateError('文件夹折叠状态写入失败');
    }
  }

  String? _canonicalFolderName(String? name) {
    if (name == null) return null;
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed.runes.length > _maxFolderNameLength) {
      return null;
    }
    if (trimmed.runes.any(
      (codePoint) => codePoint < 0x20 || codePoint == 0x7f,
    )) {
      return null;
    }
    return trimmed;
  }

  /// 规范会话携带的文件夹标签，并优先复用现有文件夹的规范拼写。
  ///
  /// 加载历史数据时非法标签会被迁移到未分组；运行期写入则拒绝非法的
  /// 非空标签，避免用户输入被静默丢弃。
  String? _normalizeSessionFolderTag(String? name) {
    if (name == null) return null;
    final trimmed = name.trim();
    if (trimmed.isEmpty) return null;
    final canonical = _canonicalFolderName(trimmed);
    if (canonical == null) {
      if (trimmed.runes.length > _maxFolderNameLength) {
        throw const FormatException('文件夹名称最长 64 个字符');
      }
      throw const FormatException('文件夹名称不能包含控制字符');
    }
    return folders.firstWhere(
      (folder) => folder.toLowerCase() == canonical.toLowerCase(),
      orElse: () => canonical,
    );
  }

  Future<void> _commitSessionFolderState({
    required List<Session> nextSessions,
    required List<String> nextFolders,
    required Set<String> nextCollapsed,
    required bool persistSessions,
  }) async {
    final candidateSessions = List<Session>.of(nextSessions);
    final candidateFolders = List<String>.of(nextFolders);
    final candidateCollapsed = Set<String>.of(nextCollapsed);
    final previousSessions = List<Session>.of(sessions);
    final previousFolders = List<String>.of(folders);
    final previousCollapsed = Set<String>.of(collapsedFolders);
    try {
      if (persistSessions) {
        await SessionStore.saveSessions(candidateSessions);
      }
      await _persistFoldersState(candidateFolders, candidateCollapsed);
    } catch (error) {
      // SharedPreferences writes are per-key operations. Restore both keys on
      // a partial failure so a later load does not create a second folder.
      try {
        if (persistSessions) {
          await SessionStore.saveSessions(previousSessions);
        }
      } catch (_) {}
      try {
        await _persistFoldersState(previousFolders, previousCollapsed);
      } catch (_) {}
      rethrow;
    }

    sessions
      ..clear()
      ..addAll(candidateSessions)
      ..sort(_compareSessions);
    folders
      ..clear()
      ..addAll(candidateFolders);
    collapsedFolders
      ..clear()
      ..addAll(candidateCollapsed.where(candidateFolders.contains));
    _invalidateDerived();
  }

  String _validatedFolderName(String name, {String? except}) {
    final trimmed = _canonicalFolderName(name);
    if (trimmed == null) {
      final value = name.trim();
      if (value.isEmpty) throw const FormatException('文件夹名称不能为空');
      if (value.runes.length > _maxFolderNameLength) {
        throw const FormatException('文件夹名称最长 64 个字符');
      }
      throw const FormatException('文件夹名称不能包含控制字符');
    }
    if (folders.any(
      (f) => f != except && f.toLowerCase() == trimmed.toLowerCase(),
    )) {
      throw const FormatException('文件夹名称已存在');
    }
    return trimmed;
  }

  Future<void> createFolder(String name) => _enqueueStateMutation(() async {
    final folder = _validatedFolderName(name);
    final nextFolders = [...folders, folder];
    await _commitSessionFolderState(
      nextSessions: sessions,
      nextFolders: nextFolders,
      nextCollapsed: collapsedFolders,
      persistSessions: false,
    );
    notifyListeners();
  });

  Future<void> renameFolder(String oldName, String newName) =>
      _enqueueStateMutation(() async {
        if (!folders.contains(oldName)) throw StateError('文件夹不存在');
        final renamed = _validatedFolderName(newName, except: oldName);
        if (renamed == oldName) return;
        final updated = [
          for (final s in sessions)
            s.tag == oldName ? s.copyWith(tag: renamed) : s,
        ];
        final nextFolders = List<String>.of(folders);
        nextFolders[nextFolders.indexOf(oldName)] = renamed;
        final nextCollapsed = Set<String>.of(collapsedFolders);
        if (nextCollapsed.remove(oldName)) nextCollapsed.add(renamed);
        await _commitSessionFolderState(
          nextSessions: updated,
          nextFolders: nextFolders,
          nextCollapsed: nextCollapsed,
          persistSessions: true,
        );
        for (final tab in tabs) {
          final s = tab.connection.session;
          if (s.tag == oldName) {
            tab.connection.applySession(s.copyWith(tag: renamed));
          }
        }
        notifyListeners();
      });

  Future<void> deleteFolder(String name) => _enqueueStateMutation(() async {
    if (!folders.contains(name)) return;
    final updated = [
      for (final s in sessions) s.tag == name ? s.copyWith(tag: null) : s,
    ];
    final nextFolders = List<String>.of(folders)..remove(name);
    final nextCollapsed = Set<String>.of(collapsedFolders)..remove(name);
    await _commitSessionFolderState(
      nextSessions: updated,
      nextFolders: nextFolders,
      nextCollapsed: nextCollapsed,
      persistSessions: true,
    );
    for (final tab in tabs) {
      final s = tab.connection.session;
      if (s.tag == name) tab.connection.applySession(s.copyWith(tag: null));
    }
    notifyListeners();
  });

  Future<void> moveSessionToFolder(String sessionId, String? folder) =>
      _enqueueStateMutation(() async {
        String? normalizedFolder;
        if (folder != null) {
          final normalized = _normalizeSessionFolderTag(folder);
          if (normalized == null) throw StateError('目标文件夹不存在');
          normalizedFolder = folders
              .where(
                (candidate) =>
                    candidate.toLowerCase() == normalized.toLowerCase(),
              )
              .firstOrNull;
          if (normalizedFolder == null) {
            throw StateError('目标文件夹不存在');
          }
        }
        final session = sessions.where((s) => s.id == sessionId).firstOrNull;
        if (session == null || session.tag == normalizedFolder) return;
        await _upsertInternal(session.copyWith(tag: normalizedFolder));
      });

  Future<void> toggleFolder(String name) => _enqueueStateMutation(() async {
    if (!folders.contains(name)) return;
    final nextCollapsed = Set<String>.of(collapsedFolders);
    if (!nextCollapsed.add(name)) nextCollapsed.remove(name);
    await _commitSessionFolderState(
      nextSessions: sessions,
      nextFolders: folders,
      nextCollapsed: nextCollapsed,
      persistSessions: false,
    );
    notifyListeners();
  });

  /// 已打开标签的会话 id 集合（结果缓存，P5：tile 级 select O(1) 判断）。
  Set<String> get openSessionIds =>
      _openIdsCache ??= tabs.map((t) => t.connection.session.id).toSet();

  void _invalidateDerived() {
    _groupedCache = null;
    _openIdsCache = null;
  }

  Future<void> upsert(Session session) =>
      _enqueueStateMutation(() => _upsertInternal(session));

  Future<void> _upsertInternal(Session session) async {
    final normalizedTag = _normalizeSessionFolderTag(session.tag);
    final normalized = session.copyWith(tag: normalizedTag);
    // 先写入候选列表：加密或写盘失败时不改动界面中的会话。
    final candidate = List<Session>.of(sessions);
    final candidateIndex = candidate.indexWhere((s) => s.id == normalized.id);
    if (candidateIndex >= 0) {
      candidate[candidateIndex] = normalized;
    } else {
      candidate.add(normalized);
    }
    candidate.sort(_compareSessions);
    final nextFolders = List<String>.of(folders);
    if (normalizedTag != null &&
        !nextFolders.any(
          (f) => f.toLowerCase() == normalizedTag.toLowerCase(),
        )) {
      nextFolders.add(normalizedTag);
    }
    final nextCollapsed = Set<String>.of(collapsedFolders)
      ..removeWhere((folder) => !nextFolders.contains(folder));
    await _commitSessionFolderState(
      nextSessions: candidate,
      nextFolders: nextFolders,
      nextCollapsed: nextCollapsed,
      persistSessions: true,
    );
    // M3：不可变模型——已打开的标签同步替换为新实例（标题即时刷新，
    // 下次重连使用新配置），而不是改写旧对象。
    for (final t in tabs) {
      if (t.connection.session.id == normalized.id) {
        t.connection.applySession(normalized);
      }
    }
    notifyListeners();
  }

  Future<void> remove(String id) => _enqueueStateMutation(() async {
    final previousSessions = List<Session>.of(sessions);
    final nextSessions = sessions.where((s) => s.id != id).toList();
    if (nextSessions.length == sessions.length) return;
    // 先写候选快照，写盘失败时保留当前会话和已打开标签，避免 UI 与磁盘分叉。
    try {
      await SessionStore.saveSessions(nextSessions);
    } catch (error) {
      // SharedPreferences 可能已更新进程内缓存后才返回 false，失败时补偿写回旧快照。
      try {
        await SessionStore.saveSessions(previousSessions);
      } catch (_) {}
      rethrow;
    }
    final tabIdx = tabs.indexWhere((t) => t.connection.session.id == id);
    if (tabIdx >= 0) closeTab(tabs[tabIdx].id);
    sessions
      ..clear()
      ..addAll(nextSessions);
    _invalidateDerived();
    notifyListeners();
  });

  Future<void> persist() => SessionStore.saveSessions(sessions);

  void setFilter(String value) {
    filter = value;
    _invalidateDerived();
    notifyListeners();
  }

  /// 按传输类型创建连接对象（SSH 走 dartssh2，Telnet 走原生 Socket，
  /// 串口走 Win32 FFI）。
  TerminalConnection _createConnection(Session session) =>
      switch (session.transport) {
        SessionTransport.serial => SerialConnection(session: session),
        SessionTransport.telnet => TelnetConnection(session: session),
        SessionTransport.ssh => SshConnection(session: session),
      };

  /// 打开（或聚焦到）某会话的终端标签页。
  void connect(Session session) {
    var tab = tabs
        .where((t) => t.connection.session.id == session.id)
        .firstOrNull;
    if (tab == null) {
      final conn = _createConnection(session);
      // M2：连接状态变化转发给 AppState 监听者（底部计数、标签圆点等）。
      void forwarder() => _onConnectionChanged(conn);
      _connectionListeners[tabIdOf(session.id)] = forwarder;
      conn.addListener(forwarder);
      tab = ConnectionTab(id: tabIdOf(session.id), connection: conn);
      tabs.add(tab);
      unawaited(conn.connect());
    }
    activeTabId = tab.id;
    _invalidateDerived();
    notifyListeners();
  }

  static String tabIdOf(String sessionId) => 'tab_$sessionId';

  void _onConnectionChanged(TerminalConnection conn) {
    if (conn.status == ConnStatus.connected) {
      _touchLastConnected(conn.session);
    }
    notifyListeners();
  }

  /// 连接成功后记录 lastConnectedAt：不可变模型下 upsert 副本替换；
  /// 临时会话不进入会话列表，跳过。1 分钟内不重复记录。
  void _touchLastConnected(Session session) {
    final i = sessions.indexWhere((s) => s.id == session.id);
    if (i < 0) return;
    final current = sessions[i];
    final now = DateTime.now();
    final last = current.lastConnectedAt;
    if (last != null && now.difference(last) < const Duration(minutes: 1)) {
      return;
    }
    unawaited(upsert(current.copyWith(lastConnectedAt: now)));
  }

  ConnectionTab? get activeTab =>
      tabs.where((t) => t.id == activeTabId).firstOrNull;

  /// 命令发送前的终端文本快照（Agent 增量输出用）。
  String? _commandOutputSnapshot;

  /// 把命令发送到当前活动会话（AI「发送到终端」共用入口，主窗口与
  /// 多窗口宿主都走这里）。返回 null 表示成功，否则为用户可读的错误。
  String? sendCommandToActiveSession(String command) {
    final connection = activeTab?.connection;
    if (connection == null) return '当前没有打开的终端会话';
    if (connection.status != ConnStatus.connected) return '当前会话未连接';
    // 发送前快照：之后取增量输出时与它求差。
    _commandOutputSnapshot = connection.terminal.buffer.getText();
    connection.sendCommand(command);
    return null;
  }

  /// 取「上一次命令发送后」新增的终端输出（Agent 自动执行回传用）。
  ///
  /// 只返回增量而非整屏上下文，避免每步把最近 N 行反复灌给模型造成
  /// token 膨胀；终端缓冲区滚动导致前缀比对失效时按尾部截断兜底。
  /// 该方法可反复调用做「输出是否稳定」的轮询采样（快照不被清空）。
  String captureCommandOutputDelta({int maxChars = 6000}) {
    final connection = activeTab?.connection;
    if (connection == null) return '（没有活动会话）';
    final after = connection.terminal.buffer.getText();
    final before = _commandOutputSnapshot;
    if (before == null) return _tailText(after.trim(), maxChars);

    final common = _commonPrefixLength(before, after);
    var delta = after.substring(common).trim();
    if (delta.isEmpty) return '（无输出）';
    return _tailText(delta, maxChars);
  }

  static int _commonPrefixLength(String a, String b) {
    final n = a.length < b.length ? a.length : b.length;
    var i = 0;
    while (i < n && a.codeUnitAt(i) == b.codeUnitAt(i)) {
      i++;
    }
    return i;
  }

  static String _tailText(String text, int maxChars) {
    if (text.length <= maxChars) return text;
    return '…（前 ${text.length - maxChars} 字符已截断）…\n'
        '${text.substring(text.length - maxChars)}';
  }

  void setActive(String id) {
    activeTabId = id;
    notifyListeners();
  }

  void closeTab(String id) {
    final tab = tabs.where((t) => t.id == id).firstOrNull;
    if (tab == null) return;
    final forwarder = _connectionListeners.remove(id);
    if (forwarder != null) tab.connection.removeListener(forwarder);
    unawaited(tab.connection.disconnect());
    tabs.removeWhere((t) => t.id == id);
    if (activeTabId == id) {
      activeTabId = tabs.isNotEmpty ? tabs.last.id : '';
    }
    _invalidateDerived();
    notifyListeners();
  }
}
