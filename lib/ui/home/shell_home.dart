import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';
import 'session_rail.dart';
import 'terminal_workspace.dart';

/// 主布局：左侧会话管理栏 + 右侧终端工作区。
///
/// 侧边栏可显示/隐藏（设置持久化）。终端工作区带稳定 Key：
/// 侧边栏插拔时 Element 按 Key 匹配复用，终端面板不会重挂载，
/// 滚动缓冲与键盘焦点不受影响。
class ShellHome extends StatelessWidget {
  const ShellHome({super.key});

  @override
  Widget build(BuildContext context) {
    final showSidebar = context.watch<AppState>().settings.showSidebar;
    return Scaffold(
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showSidebar) ...[
            const SessionRail(key: ValueKey('rail')),
            const VerticalDivider(width: 1, thickness: 1),
          ],
          const Expanded(
            key: ValueKey('workspace'),
            child: TerminalWorkspace(),
          ),
        ],
      ),
    );
  }
}
