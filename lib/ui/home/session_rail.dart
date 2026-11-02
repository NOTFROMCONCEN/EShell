import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/session.dart';
import '../../services/terminal_connection.dart';
import '../../state/app_state.dart';
import '../session/quick_connect_dialog.dart';
import '../session/session_edit_dialog.dart';
import 'appearance_dialog.dart';

/// 左侧会话管理栏。
class SessionRail extends StatelessWidget {
  const SessionRail({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Material(
      color: scheme.surfaceContainerLow,
      child: SizedBox(
        width: 300,
        child: SafeArea(
          right: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: scheme.primaryContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(Icons.terminal_rounded,
                          size: 20, color: scheme.onPrimaryContainer),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'EShell',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              color: scheme.onSurface,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ),
                    IconButton(
                      tooltip: '外观设置',
                      icon: const Icon(Icons.palette_outlined),
                      onPressed: () => showAppearanceDialog(context),
                    ),
                    IconButton(
                      tooltip: '隐藏侧边栏 (Ctrl+Shift+B)',
                      icon: const Icon(Icons.menu_open_outlined),
                      onPressed: () => context
                          .read<AppState>()
                          .settings
                          .setShowSidebar(false),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: _RailSearch(),
              ),              Padding(
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
      backgroundColor:
          WidgetStatePropertyAll(scheme.surfaceContainerHigh),
      side: WidgetStatePropertyAll(
          BorderSide(color: scheme.outlineVariant)),
      onChanged: context.read<AppState>().setFilter,
    );
  }
}

class _SessionList extends StatelessWidget {
  const _SessionList();

  @override
  Widget build(BuildContext context) {
    // P5：列表内容只在分组结果（缓存实例）变化时重建；
    // 连接状态通知不会触发整列表重排。
    final groups =
        context.select<AppState, Map<String, List<Session>>>((app) {
      return app.groupedSessions;
    });
    final filterEmpty =
        context.select<AppState, bool>((app) => app.filter.trim().isEmpty);

    if (groups.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            filterEmpty ? '还没有会话，点击「新建会话」开始' : '没有匹配的会话',
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }

    final children = <Widget>[];
    for (final entry in groups.entries) {
      if (entry.key.isNotEmpty) {
        children.add(_GroupHeader(label: entry.key));
      }
      for (final session in entry.value) {
        children.add(_SessionTile(session: session));
      }
    }
    return ListView(padding: const EdgeInsets.symmetric(vertical: 4), children: children);
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: scheme.primary,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
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
        (app) => app.openSessionIds.contains(session.id));
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: ListTile(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        leading: CircleAvatar(
          radius: 17,
          backgroundColor: scheme.primaryContainer,
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
        subtitle: Text(session.address,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        onTap: () => context.read<AppState>().connect(session),
        trailing: PopupMenuButton<String>(
          icon: Icon(Icons.more_vert, color: scheme.onSurfaceVariant),
          onSelected: (value) => _onMenu(context, value),
          itemBuilder: (context) => const [
            PopupMenuItem(value: 'connect', child: Text('连接')),
            PopupMenuItem(value: 'edit', child: Text('编辑')),
            PopupMenuItem(value: 'duplicate', child: Text('复制会话')),
            PopupMenuItem(value: 'delete', child: Text('删除')),
          ],
        ),
      ),
    );
  }

  void _onMenu(BuildContext context, String action) {
    final app = context.read<AppState>();
    switch (action) {
      case 'connect':
        app.connect(session);
      case 'edit':
        showSessionEditDialog(context, initial: session);
      case 'duplicate':
        // M3：不可变模型，复制即生成新实例。
        app.upsert(session.copyWith(
          id: DateTime.now().microsecondsSinceEpoch.toRadixString(36),
          name: session.name.isEmpty ? '' : '${session.name} 副本',
          lastConnectedAt: null,
        ));
      case 'delete':
        _confirmDelete(context, app);
    }
  }

  void _confirmDelete(BuildContext context, AppState app) {
    final scheme = Theme.of(context).colorScheme;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.delete_outline, color: scheme.error),
        title: const Text('删除会话'),
        content: Text('确定删除「${session.displayName}」吗？此操作不可撤销。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            onPressed: () {
              app.remove(session.id);
              Navigator.pop(ctx);
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
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
            .length);
    final sessionCount =
        context.select<AppState, int>((app) => app.sessions.length);
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.hub_outlined, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Text(
            '$sessionCount 个会话 · $connectedCount 个连接中',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }
}
