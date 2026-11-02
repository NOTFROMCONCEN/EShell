import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/session.dart';
import '../services/serial_connection.dart';
import '../services/session_store.dart';
import '../services/ssh_service.dart';
import '../services/terminal_connection.dart';

/// 外观设置：明暗模式 + Material You 种子色 + DPI 相关缩放。
class ThemeSettings extends ChangeNotifier {
  ThemeMode mode = ThemeMode.system;

  /// 默认种子色（钢青蓝），与 EShell 品牌色一致。
  int seedColor = 0xFF415F91;

  /// 壁纸动态色可用时优先使用（Windows 上通常不可用，自动回退种子色）。
  bool preferWallpaper = true;

  /// 终端字号（逻辑像素），高 DPI 屏可自行放大缩小。
  double terminalFontSize = 15.0;

  /// 界面文字缩放；1.0 = 跟随系统，>1 为固定放大。
  double uiTextScale = 1.0;

  /// 会话日志上次保存的目录；空表示未设置（由系统对话框决定初始位置）。
  String logDirectory = '';

  /// 会话日志脱敏开关（S2）：开启后日志写入掩码文本而非原始字节。
  bool maskSecretsInLog = false;

  /// 侧边栏显示/隐藏（隐藏时腾出全部宽度给终端）。
  bool showSidebar = true;

  static const double minTerminalFontSize = 10;
  static const double maxTerminalFontSize = 28;

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

  final List<Session> sessions = [];
  final List<ConnectionTab> tabs = [];

  String activeTabId = '';
  String filter = '';

  /// 连接状态监听转发表：tab id -> 移除监听用的回调（M2）。
  final Map<String, VoidCallback> _connectionListeners = {};

  /// 派生数据缓存（P5）：会话列表只在会话/过滤条件变化时重建，
  /// 连接状态通知不再触发整列表重排。
  Map<String, List<Session>>? _groupedCache;
  Set<String>? _openIdsCache;

  Future<void> load() async {
    await _loadSettings();
    settings.addListener(_schedulePersistSettings);
    sessions.addAll(await SessionStore.loadSessions());
    sessions.sort(_compareSessions);
  }

  static const _kThemeMode = 'eshell.themeMode';
  static const _kSeedColor = 'eshell.seedColor';
  static const _kPreferWallpaper = 'eshell.preferWallpaper';
  static const _kTerminalFontSize = 'eshell.terminalFontSize';
  static const _kUiTextScale = 'eshell.uiTextScale';
  static const _kLogDirectory = 'eshell.logDirectory';
  static const _kMaskLog = 'eshell.maskSecretsInLog';
  static const _kShowSidebar = 'eshell.showSidebar';

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final modeIdx = prefs.getInt(_kThemeMode);
    if (modeIdx != null &&
        modeIdx >= 0 &&
        modeIdx < ThemeMode.values.length) {
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
    settings.logDirectory = prefs.getString(_kLogDirectory) ?? '';
    settings.maskSecretsInLog = prefs.getBool(_kMaskLog) ?? false;
    settings.showSidebar = prefs.getBool(_kShowSidebar) ?? true;
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
    await prefs.setString(_kLogDirectory, settings.logDirectory);
    await prefs.setBool(_kMaskLog, settings.maskSecretsInLog);
    await prefs.setBool(_kShowSidebar, settings.showSidebar);
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
        .where((s) =>
            s.displayName.toLowerCase().contains(q) ||
            s.host.toLowerCase().contains(q) ||
            s.username.toLowerCase().contains(q) ||
            (s.tag ?? '').toLowerCase().contains(q))
        .toList();
  }

  /// 按标签分组，保持插入顺序（结果缓存，P5）。
  Map<String, List<Session>> get groupedSessions =>
      _groupedCache ??= _buildGroupedSessions();

  Map<String, List<Session>> _buildGroupedSessions() {
    final map = <String, List<Session>>{};
    for (final s in filteredSessions) {
      final key = s.tag ?? '';
      map.putIfAbsent(key, () => []).add(s);
    }
    return map;
  }

  /// 已打开标签的会话 id 集合（结果缓存，P5：tile 级 select O(1) 判断）。
  Set<String> get openSessionIds =>
      _openIdsCache ??= tabs.map((t) => t.connection.session.id).toSet();

  void _invalidateDerived() {
    _groupedCache = null;
    _openIdsCache = null;
  }

  Future<void> upsert(Session session) async {
    final i = sessions.indexWhere((s) => s.id == session.id);
    if (i >= 0) {
      sessions[i] = session;
    } else {
      sessions.add(session);
    }
    sessions.sort(_compareSessions);
    // M3：不可变模型——已打开的标签同步替换为新实例（标题即时刷新，
    // 下次重连使用新配置），而不是改写旧对象。
    for (final t in tabs) {
      if (t.connection.session.id == session.id) {
        t.connection.applySession(session);
      }
    }
    _invalidateDerived();
    notifyListeners();
    await persist();
  }

  Future<void> remove(String id) async {
    final tabIdx = tabs.indexWhere((t) => t.connection.session.id == id);
    if (tabIdx >= 0) closeTab(tabs[tabIdx].id);
    sessions.removeWhere((s) => s.id == id);
    _invalidateDerived();
    notifyListeners();
    await persist();
  }

  Future<void> persist() => SessionStore.saveSessions(sessions);

  void setFilter(String value) {
    filter = value;
    _invalidateDerived();
    notifyListeners();
  }

  /// 按传输类型创建连接对象（SSH 走 dartssh2，串口走 Win32 FFI）。
  TerminalConnection _createConnection(Session session) =>
      switch (session.transport) {
        SessionTransport.serial => SerialConnection(session: session),
        SessionTransport.ssh => SshConnection(session: session),
      };

  /// 打开（或聚焦到）某会话的终端标签页。
  void connect(Session session) {
    var tab = tabs.where((t) => t.connection.session.id == session.id).firstOrNull;
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
