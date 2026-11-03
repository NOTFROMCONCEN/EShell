import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/session.dart';
import '../../services/terminal_connection.dart';
import '../../state/app_state.dart';
import '../ai/ai_toggle_button.dart';
import '../session/quick_connect_dialog.dart';
import '../session/session_edit_dialog.dart';
import '../session/telnet_scan_dialog.dart';
import 'folder_dialogs.dart';
import '../settings/settings_page.dart';

/// 左侧会话管理栏。
class SessionRail extends StatelessWidget {
  const SessionRail({super.key, this.width = 300});

  /// 栏宽（逻辑像素）：由 ShellHome 从设置传入，可拖拽分隔条调整。
  final double width;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Material(
      color: scheme.surfaceContainerLow,
      child: SizedBox(
        width: width,
        child: SafeArea(
          right: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 16, 8, 12),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // 侧栏宽度可拖动调整：窄栏隐藏品牌图标块避免溢出。
                    final compact = constraints.maxWidth < 256;
                    return Row(
                      children: [
                        if (!compact) ...[
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: scheme.primaryContainer,
                              borderRadius: BorderRadius.zero,
                              border: Border.all(color: scheme.outlineVariant),
                            ),
                            child: Icon(
                              Icons.terminal_rounded,
                              size: 20,
                              color: scheme.onPrimaryContainer,
                            ),
                          ),
                          const SizedBox(width: 12),
                        ],
                        Expanded(
                          child: Text(
                            'EShell',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(
                                  color: scheme.onSurface,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                        ),
                        IconButton(
                          tooltip: '程序设置',
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.settings_outlined),
                          onPressed: () => showSettingsPage(context),
                        ),
                        const AiPanelToggle(),
                        // 多窗口：把会话栏弹出为独立窗口（未注入 host 的
                        // 环境如测试，不显示入口）。
                        if (context.read<AppState>().windowHost != null)
                          IconButton(
                            tooltip: '弹出会话栏为独立窗口',
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.open_in_new_rounded),
                            onPressed: () => context
                                .read<AppState>()
                                .windowHost!
                                .popOutRail(),
                          ),
                        IconButton(
                          tooltip: '隐藏侧边栏 (Ctrl+Shift+B)',
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.menu_open_outlined),
                          onPressed: () => context
                              .read<AppState>()
                              .settings
                              .setShowSidebar(false),
                        ),
                      ],
                    );
                  },
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: _RailSearch(),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: FilledButton.tonalIcon(
                        onPressed: () => showSessionEditDialog(context),
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('新建会话'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: '快速连接',
                      icon: const Icon(Icons.bolt_rounded),
                      style: IconButton.styleFrom(
                        backgroundColor: scheme.secondaryContainer,
                        foregroundColor: scheme.onSecondaryContainer,
                      ),
                      onPressed: () => showQuickConnectDialog(context),
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      tooltip: '扫描 Telnet 服务（EVE-NG 节点控制台）',
                      icon: const Icon(Icons.radar_rounded),
                      onPressed: () => showTelnetScanDialog(context),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              const Expanded(child: _SessionList()),
              const _RailFooter(),
            ],
          ),
        ),
      ),
    );
  }
}

/// 搜索框：过滤条件只经 onChanged 写回 AppState，自身不 watch 全局状态。
class _RailSearch extends StatelessWidget {
  const _RailSearch();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SearchBar(
      hintText: '搜索会话 / 主机',
      leading: const Padding(
        padding: EdgeInsets.only(left: 8),
        child: Icon(Icons.search, size: 20),
      ),
      elevation: const WidgetStatePropertyAll(0),
      backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerHigh),
      side: WidgetStatePropertyAll(BorderSide(color: scheme.outlineVariant)),
      onChanged: context.read<AppState>().setFilter,
      trailing: [
        IconButton(
          tooltip: '新建文件夹',
          icon: const Icon(Icons.create_new_folder_outlined),
          onPressed: () async {
            final app = context.read<AppState>();
            final name = await showFolderNameDialog(
              context,
              existing: app.folders,
            );
            if (name == null || !context.mounted) return;
            try {
              await app.createFolder(name);
            } catch (e) {
              if (context.mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text('新建文件夹失败：$e')));
              }
            }
          },
        ),
      ],
    );
  }
}

class _SessionList extends StatelessWidget {
  const _SessionList();

  @override
  Widget build(BuildContext context) {
    // P5：列表内容只在分组结果（缓存实例）变化时重建；
    // 连接状态通知不会触发整列表重排。
    final groups = context.select<AppState, Map<String, List<Session>>>((app) {
      return app.groupedSessions;
    });
    final filterEmpty = context.select<AppState, bool>(
      (app) => app.filter.trim().isEmpty,
    );
    final collapsedKey = context.select<AppState, String>(
      (app) => app.collapsedFolders.join('\x00'),
    );

    if (groups.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            filterEmpty ? '还没有会话，点击「新建会话」开始' : '没有匹配的会话',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    final children = <Widget>[];
    for (final entry in groups.entries) {
      if (entry.key.isNotEmpty) {
        children.add(_GroupHeader(label: entry.key, count: entry.value.length));
        if (collapsedKey.split('\x00').contains(entry.key)) continue;
      }
      for (final session in entry.value) {
        children.add(_SessionTile(session: session));
      }
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: children,
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final collapsed = context.select<AppState, bool>(
      (app) => app.collapsedFolders.contains(label),
    );
    return ListTile(
      dense: true,
      leading: Icon(
        collapsed ? Icons.chevron_right : Icons.expand_more,
        size: 20,
        color: scheme.primary,
      ),
      title: Row(
        children: [
          Icon(
            collapsed ? Icons.folder_outlined : Icons.folder_open_outlined,
            size: 16,
            color: scheme.primary,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: scheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
      subtitle: Text('$count 个会话'),
      onTap: () => _toggle(context),
      trailing: PopupMenuButton<String>(
        tooltip: '管理文件夹',
        onSelected: (action) => _onMenu(context, action),
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'rename', child: Text('重命名')),
          PopupMenuItem(value: 'delete', child: Text('删除文件夹')),
        ],
      ),
    );
  }

  Future<void> _toggle(BuildContext context) async {
    try {
      await context.read<AppState>().toggleFolder(label);
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('折叠文件夹失败：$error')));
      }
    }
  }

  Future<void> _onMenu(BuildContext context, String action) async {
    final app = context.read<AppState>();
    try {
      if (action == 'rename') {
        final renamed = await showFolderNameDialog(
          context,
          existing: app.folders,
          initialName: label,
        );
        if (renamed == null || !context.mounted) return;
        await app.renameFolder(label, renamed);
      } else if (action == 'delete') {
        final confirmed = await confirmDeleteFolder(
          context,
          name: label,
          sessionCount: count,
        );
        if (!confirmed || !context.mounted) return;
        await app.deleteFolder(label);
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('操作文件夹失败：$e')));
      }
    }
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({required this.session});

  final Session session;

  @override
  Widget build(BuildContext context) {
    // P5：tile 级 select，只在该会话的开/关状态翻转时重建这一个 tile，
    // 不再 tile 级全局 watch + 每 tile O(n) 扫描。
    final isOpen = context.select<AppState, bool>(
      (app) => app.openSessionIds.contains(session.id),
    );
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: ListTile(
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        leading: Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Text(
            session.displayName.isNotEmpty
                ? session.displayName.substring(0, 1).toUpperCase()
                : '?',
            style: TextStyle(
              color: scheme.onPrimaryContainer,
              fontWeight: FontWeight.w600,
              fontSize: 14,
            ),
          ),
        ),
        title: Row(
          children: [
            Flexible(
              child: Text(
                session.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
            ),
            if (isOpen) ...[
              const SizedBox(width: 6),
              Icon(Icons.circle, size: 8, color: scheme.primary),
            ],
          ],
        ),
        subtitle: Text(
          session.address,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        onTap: () => context.read<AppState>().connect(session),
        trailing: PopupMenuButton<String>(
          icon: Icon(Icons.more_vert, color: scheme.onSurfaceVariant),
          onSelected: (value) => _onMenu(context, value),
          itemBuilder: (context) => [
            const PopupMenuItem(value: 'connect', child: Text('连接')),
            const PopupMenuItem(value: 'edit', child: Text('编辑')),
            const PopupMenuItem(value: 'duplicate', child: Text('复制会话')),
            const PopupMenuDivider(),
            const PopupMenuItem(value: 'move:', child: Text('移到未分组')),
            for (final folder in context.read<AppState>().folders)
              PopupMenuItem(value: 'move:$folder', child: Text('移到：$folder')),
            const PopupMenuDivider(),
            const PopupMenuItem(value: 'delete', child: Text('删除')),
          ],
        ),
      ),
    );
  }

  Future<void> _onMenu(BuildContext context, String action) async {
    final app = context.read<AppState>();
    if (action.startsWith('move:')) {
      final folder = action.substring(5);
      try {
        await app.moveSessionToFolder(
          session.id,
          folder.isEmpty ? null : folder,
        );
      } catch (error) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('移动会话失败：$error')));
        }
      }
      return;
    }
    switch (action) {
      case 'connect':
        app.connect(session);
      case 'edit':
        await showSessionEditDialog(context, initial: session);
      case 'duplicate':
        // M3：不可变模型，复制即生成新实例。
        try {
          await app.upsert(
            session.copyWith(
              id: DateTime.now().microsecondsSinceEpoch.toRadixString(36),
              name: session.name.isEmpty ? '' : '${session.name} 副本',
              lastConnectedAt: null,
            ),
          );
        } catch (error) {
          if (context.mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text('复制会话失败：$error')));
          }
        }
      case 'delete':
        await _confirmDelete(context, app);
    }
  }

  Future<void> _confirmDelete(BuildContext context, AppState app) async {
    final scheme = Theme.of(context).colorScheme;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.delete_outline, color: scheme.error),
        title: const Text('删除会话'),
        content: Text('确定删除「${session.displayName}」吗？此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            onPressed: () {
              Navigator.pop(ctx);
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await app.remove(session.id);
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('删除会话失败：$error')));
      }
    }
  }
}

/// 底部统计：分别 select 两个计数值，只在数值变化时重建（M2 生效的前提）。
class _RailFooter extends StatelessWidget {
  const _RailFooter();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final connectedCount = context.select<AppState, int>(
      (app) => app.tabs
          .where((t) => t.connection.status == ConnStatus.connected)
          .length,
    );
    final sessionCount = context.select<AppState, int>(
      (app) => app.sessions.length,
    );
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.hub_outlined, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$sessionCount 个会话 · $connectedCount 个连接中',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}
