import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';

/// AI 面板开关按钮（侧栏头部 / 标签条复用）。
///
/// 直接 watch AppState：面板显隐后图标立即切换（settings 通知已桥接到 AppState）。
class AiPanelToggle extends StatelessWidget {
  const AiPanelToggle({super.key, this.size = 20});

  final double size;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final open = app.settings.showAiPanel;
    final poppedOut = app.windowHost?.aiPoppedOut ?? false;
    return IconButton(
      tooltip: poppedOut
          ? 'AI 助手在独立窗口（点击收回并隐藏）'
          : open
              ? '隐藏 AI 助手'
              : 'AI 助手（命令需确认执行）',
      iconSize: size,
      icon: Icon(
        open || poppedOut ? Icons.auto_awesome : Icons.auto_awesome_outlined,
        size: size,
      ),
      onPressed: () {
        // AI 已弹出：先收回子窗口（对话迁回），再隐藏面板。
        if (poppedOut) {
          app.windowHost!.dockAi();
        }
        app.settings.setShowAiPanel(false);
      },
    );
  }
}
