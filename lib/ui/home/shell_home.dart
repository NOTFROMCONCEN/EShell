import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';
import '../common/resizer.dart';
import 'session_rail.dart';
import 'terminal_workspace.dart';

/// 主布局：左侧会话管理栏 + 右侧终端工作区。
///
/// 侧边栏可显示/隐藏、宽度可拖拽调整（设置持久化）。终端工作区带稳定
/// Key：侧边栏插拔时 Element 按 Key 匹配复用，终端面板不会重挂载，
/// 滚动缓冲与键盘焦点不受影响。
///
/// 注意：`showSidebar` 在 [ThemeSettings]（独立 ChangeNotifier）里；
/// AppState.load() 已把 settings 的通知桥接给 AppState，因此这里的
/// `watch<AppState>()` 能随设置变化重建（2026-11-02 修复「点按钮没反应」）。
class ShellHome extends StatelessWidget {
  const ShellHome({super.key});

  /// 拖宽侧栏时给终端区保留的最小宽度。
  static const double _minWorkspaceWidth = 320;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final settings = app.settings;
    final host = app.windowHost;
    final railPoppedOut = host?.railPoppedOut ?? false;
    return Scaffold(
      body: LayoutBuilder(builder: (context, constraints) {
        // 侧栏宽度：硬边界 [220, 480] + 窗口约束（保终端区最小宽度），
        // 窗口调窄后持久化的旧宽度在这里被夹回。
        final maxSidebar = math.max(
          ThemeSettings.minSidebarWidth,
          math.min(
            ThemeSettings.maxSidebarWidth,
            constraints.maxWidth - _minWorkspaceWidth,
          ),
        );
        final sidebarWidth =
            settings.sidebarWidth.clamp(ThemeSettings.minSidebarWidth, maxSidebar);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (railPoppedOut)
              // 会话栏已弹出：窄条占位，提供收回入口。
              _RailPoppedStrip(onDock: host!.dockRail)
            else if (settings.showSidebar) ...[
              SessionRail(
                key: const ValueKey('rail'),
                width: sidebarWidth,
              ),
              PanelResizer(
                tooltip: '拖动调整侧栏宽度 · 双击恢复默认',
                onDrag: (d) => settings.setSidebarWidth(
                  (settings.sidebarWidth + d).clamp(
                    ThemeSettings.minSidebarWidth,
                    math.min(ThemeSettings.maxSidebarWidth, maxSidebar),
                  ),
                ),
                onDoubleTap: () => settings
                    .setSidebarWidth(ThemeSettings.defaultSidebarWidth),
              ),
            ],
            const Expanded(
              key: ValueKey('workspace'),
              child: TerminalWorkspace(),
            ),
          ],
        );
      }),
    );
  }
}

/// 会话栏已弹出为独立窗口时的主窗口侧窄条占位。
class _RailPoppedStrip extends StatelessWidget {
  const _RailPoppedStrip({required this.onDock});

  final VoidCallback onDock;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      child: SizedBox(
        width: 44,
        child: SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 12),
              IconButton(
                tooltip: '收回会话栏',
                icon: Icon(Icons.dock_rounded,
                    size: 20, color: scheme.primary),
                onPressed: onDock,
              ),
              const SizedBox(height: 4),
              RotatedBox(
                quarterTurns: 1,
                child: Text(
                  '会话栏在独立窗口',
                  style: Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
