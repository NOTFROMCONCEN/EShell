import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../services/window_protocol.dart';
import '../../state/app_state.dart';
import '../../theme/app_theme.dart';
import 'folder_dialogs.dart';

/// 会话栏独立子窗口入口。
///
/// 远程视图：主窗口是状态权威（500ms 节流推送快照），本窗口渲染
/// 会话列表与连接状态，点击/搜索/对话框请求经通道回传主窗口执行。
Future<void> runRailWindow() async {
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(320, 720),
      minimumSize: Size(260, 400),
      center: true,
      title: 'EShell · 会话栏',
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );
  await windowManager.setPreventClose(true);
  windowManager.addListener(_RailWindowCloseHook());

  final themeSettings = ThemeSettings();
  await themeSettings.loadThemeFromPrefs();

  runApp(
    DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        final resolved = resolveTheme(
          settings: themeSettings,
          lightDynamic: lightDynamic,
          darkDynamic: darkDynamic,
        );
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.of(resolved.light),
          darkTheme: AppTheme.of(resolved.dark),
          themeMode: resolved.mode,
          home: const _RailWindowView(),
        );
      },
    ),
  );
}

class _RailWindowCloseHook with WindowListener {
  @override
  void onWindowClose() {
    // 通知主窗口恢复停靠状态，再真关闭。
    unawaited(() async {
      await const WindowMethodChannel(WindowProtocol.railChannel)
          .invokeMethod(WindowProtocol.railWindowClosed)
          .catchError((_) {});
      await windowManager.setPreventClose(false);
      await windowManager.close();
    }());
  }
}

/// 会话栏远程视图。
class _RailWindowView extends StatefulWidget {
  const _RailWindowView();

  @override
  State<_RailWindowView> createState() => _RailWindowViewState();
}

class _RailWindowViewState extends State<_RailWindowView> {
  RailSnapshot? _snapshot;
  final TextEditingController _search = TextEditingController();

  static const _channel = WindowMethodChannel(WindowProtocol.railChannel);

  Future<void> _action(String type, Map<String, dynamic> payload) async {
    try {
      await _channel.invokeMethod(WindowProtocol.railAction, {
        'type': type,
        ...payload,
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('操作失败：$e')),
        );
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _channel.setMethodCallHandler((call) async {
      if (call.method != WindowProtocol.railPushSnapshot) return null;
      final args = call.arguments as Map? ?? const {};
      final snapshot =
          RailSnapshot.decodeJson(args['snapshot'] as String? ?? '');
      if (snapshot == null || !mounted) return null;
      setState(() => _snapshot = snapshot);
      return null;
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final snapshot = _snapshot;
    return Scaffold(
      body: Material(
        color: scheme.surfaceContainerLow,
        child: SafeArea(
          right: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(context, snapshot),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Row(children: [
                  Expanded(child: TextField(
                  controller: _search,
                  decoration: const InputDecoration(
                    hintText: '搜索会话 / 主机',
                    prefixIcon: Icon(Icons.search, size: 20),
                    isDense: true,
                  ),
                  onChanged: (value) =>
                      _action(WindowProtocol.railActSetFilter, {'value': value}),
                  )),
                  IconButton(
                    tooltip: '新建文件夹',
                    icon: const Icon(Icons.create_new_folder_outlined),
                    onPressed: () async {
                      final name = await showFolderNameDialog(context,
                          existing: _snapshot?.folders ?? const []);
                      if (name != null && mounted) {
                        await _action(WindowProtocol.railActCreateFolder,
                            {'name': name});
                      }
                    },
                  ),
                ]),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: () => _action(
                          WindowProtocol.railActOpenDialog,
                          {'kind': 'session'}),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('新建会话'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _action(
                          WindowProtocol.railActOpenDialog,
                          {'kind': 'quickConnect'}),
                      icon: const Icon(Icons.bolt_rounded, size: 18),
                      label: const Text('快速连接'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _action(
                          WindowProtocol.railActOpenDialog,
                          {'kind': 'telnetScan'}),
                      icon: const Icon(Icons.radar_rounded, size: 18),
                      label: const Text('扫描 Telnet'),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(child: _buildSessionList(context, snapshot)),
              const Divider(height: 1),
              _buildFooter(context, snapshot),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, RailSnapshot? snapshot) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 8, 12),
      child: Row(
        children: [
          Icon(Icons.terminal_rounded, size: 22, color: scheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'EShell',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          IconButton(
            tooltip: 'AI 助手',
            icon: Icon(
              (snapshot?.showAiPanel ?? false)
                  ? Icons.auto_awesome
                  : Icons.auto_awesome_outlined,
              size: 20,
            ),
            onPressed: () =>
                _action(WindowProtocol.railActToggleAiPanel, const {}),
          ),
          IconButton(
            tooltip: '外观设置',
            icon: const Icon(Icons.palette_outlined, size: 20),
            onPressed: () =>
                _action(WindowProtocol.railActOpenDialog, {'kind': 'appearance'}),
          ),
          IconButton(
            tooltip: '收回会话栏',
            icon: const Icon(Icons.dock_rounded, size: 20),
            onPressed: () => _action(WindowProtocol.railWindowClosed, const {}),
          ),
        ],
      ),
    );
  }

  Widget _buildSessionList(BuildContext context, RailSnapshot? snapshot) {
    final scheme = Theme.of(context).colorScheme;
    if (snapshot == null) {
      return const Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    // 与主侧栏一致：按标签分组，保持插入顺序。
    final q = snapshot.filter.trim().toLowerCase();
    final sessions = q.isEmpty
        ? snapshot.sessions
        : snapshot.sessions
            .where((s) =>
                s.displayName.toLowerCase().contains(q) ||
                s.host.toLowerCase().contains(q) ||
                (s.tag ?? '').toLowerCase().contains(q))
            .toList();
    final groups = <String, List<RailSession>>{};
    for (final folder in snapshot.folders) {
      if (q.isEmpty || folder.toLowerCase().contains(q)) groups[folder] = [];
    }
    for (final s in sessions) {
      groups.putIfAbsent(s.tag ?? '', () => []).add(s);
    }
    if (groups.isEmpty) {
      return Center(
        child: Text('没有匹配的会话',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant)),
      );
    }
    // 会话 id -> 活动连接状态。
    final statusBySession = {
      for (final t in snapshot.tabs) t.sessionId: t.status,
    };
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: groups.length,
      itemBuilder: (context, index) {
        final tag = groups.keys.elementAt(index);
        final items = groups[tag]!;
        final collapsed = snapshot.collapsedFolders.contains(tag);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (tag.isNotEmpty)
              ListTile(
                dense: true,
                leading: Icon(collapsed ? Icons.chevron_right : Icons.expand_more,
                    size: 20, color: scheme.primary),
                title: Row(children: [
                  Icon(collapsed ? Icons.folder_outlined : Icons.folder_open_outlined,
                      size: 16, color: scheme.primary),
                  const SizedBox(width: 6),
                  Expanded(child: Text(tag, maxLines: 1,
                      overflow: TextOverflow.ellipsis)),
                ]),
                subtitle: Text('${items.length} 个会话'),
                onTap: () => _action(
                    WindowProtocol.railActToggleFolder, {'name': tag}),
                trailing: PopupMenuButton<String>(
                  tooltip: '管理文件夹',
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'rename', child: Text('重命名')),
                    PopupMenuItem(value: 'delete', child: Text('删除文件夹')),
                  ],
                  onSelected: (action) async {
                    if (action == 'rename') {
                      final renamed = await showFolderNameDialog(context,
                          existing: snapshot.folders, initialName: tag);
                      if (renamed != null && mounted) {
                        await _action(WindowProtocol.railActRenameFolder,
                            {'oldName': tag, 'newName': renamed});
                      }
                    } else if (action == 'delete') {
                      final confirmed = await confirmDeleteFolder(context,
                          name: tag, sessionCount: items.length);
                      if (confirmed && mounted) {
                        await _action(WindowProtocol.railActDeleteFolder,
                            {'name': tag});
                      }
                    }
                  },
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                child: Text('未分组',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant)),
              ),
            if (!collapsed) for (final s in items)
              ListTile(
                dense: true,
                leading: _statusDot(statusBySession[s.id], scheme),
                title: Text(s.displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  '${_transportLabel(s.transport)} · ${s.host}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () =>
                    _action(WindowProtocol.railActConnect, {'sessionId': s.id}),
                trailing: PopupMenuButton<String>(
                  tooltip: '移动会话',
                  onSelected: (value) => _action(
                    WindowProtocol.railActMoveSession,
                    {'sessionId': s.id, 'folder': value.isEmpty ? null : value},
                  ),
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: '', child: Text('移到未分组')),
                    for (final folder in snapshot.folders)
                      PopupMenuItem(value: folder, child: Text('移到：$folder')),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildFooter(BuildContext context, RailSnapshot? snapshot) {
    final scheme = Theme.of(context).colorScheme;
    final connected =
        snapshot?.tabs.where((t) => t.status == 'connected').length ?? 0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.hub_outlined, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${snapshot?.sessions.length ?? 0} 个会话 · $connected 个连接中',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context)
                  .textTheme
                  .labelMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusDot(String? status, ColorScheme scheme) {
    final color = switch (status) {
      'connected' => scheme.primary,
      'connecting' => scheme.tertiary,
      'failed' => scheme.error,
      _ => scheme.outlineVariant,
    };
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }

  String _transportLabel(String transport) => switch (transport) {
        'telnet' => 'Telnet',
        'serial' => '串口',
        _ => 'SSH',
      };
}
