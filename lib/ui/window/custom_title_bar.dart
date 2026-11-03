import 'dart:async';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

typedef WindowCommand = Future<void> Function();
typedef WindowMaximizedQuery = Future<bool> Function();

/// 主窗口的自绘标题栏。
///
/// 系统标题栏隐藏后，窗口仍由 Windows 提供边框和调整大小能力；这里仅
/// 绘制品牌区域和窗口控制按钮，并使用 window_manager 提供拖动/窗口操作。
class CustomTitleBar extends StatefulWidget {
  const CustomTitleBar({
    super.key,
    this.height = 42,
    this.queryMaximized,
    this.onMinimize,
    this.onMaximize,
    this.onUnmaximize,
    this.onClose,
  });

  final double height;
  final WindowMaximizedQuery? queryMaximized;
  final WindowCommand? onMinimize;
  final WindowCommand? onMaximize;
  final WindowCommand? onUnmaximize;
  final WindowCommand? onClose;

  @override
  State<CustomTitleBar> createState() => _CustomTitleBarState();
}

class _CustomTitleBarState extends State<CustomTitleBar> with WindowListener {
  bool _isMaximized = false;

  WindowMaximizedQuery get _queryMaximized =>
      widget.queryMaximized ?? windowManager.isMaximized;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    unawaited(_refreshMaximized());
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() {
    if (!mounted) return;
    setState(() => _isMaximized = true);
  }

  @override
  void onWindowUnmaximize() {
    if (!mounted) return;
    setState(() => _isMaximized = false);
  }

  Future<void> _refreshMaximized() async {
    try {
      final maximized = await _queryMaximized();
      if (mounted) setState(() => _isMaximized = maximized);
    } catch (_) {
      // Widget tests and非 Windows 平台没有原生窗口通道时，按未最大化显示。
    }
  }

  Future<bool> _run(WindowCommand command) async {
    try {
      await command();
      return true;
    } catch (error) {
      if (mounted) {
        final messenger = ScaffoldMessenger.maybeOf(context);
        if (messenger != null) {
          try {
            messenger.showSnackBar(SnackBar(content: Text('窗口操作失败：$error')));
          } on AssertionError {
            // 标题栏也可单独用于无 Scaffold 的测试或嵌入场景。
          }
        }
      }
      return false;
    }
  }

  Future<void> _toggleMaximize() async {
    final wasMaximized = _isMaximized;
    final command = wasMaximized
        ? (widget.onUnmaximize ?? windowManager.unmaximize)
        : (widget.onMaximize ?? windowManager.maximize);
    if (await _run(command) && mounted) {
      setState(() => _isMaximized = !wasMaximized);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final titleStyle = Theme.of(context).textTheme.titleSmall?.copyWith(
      color: scheme.onSurface,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.2,
    );
    return Material(
      color: scheme.surface,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
        ),
        child: SizedBox(
          height: widget.height,
          child: Row(
            children: [
              Expanded(
                child: _TitleDragArea(
                  onPanStart: () =>
                      unawaited(_run(windowManager.startDragging)),
                  onDoubleTap: () => unawaited(_toggleMaximize()),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Row(
                      children: [
                        Icon(
                          Icons.terminal_rounded,
                          size: 18,
                          color: scheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            'EShell',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: titleStyle,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              _ChromeButton(
                tooltip: '最小化',
                icon: Icons.remove,
                onPressed: () =>
                    _run(widget.onMinimize ?? windowManager.minimize),
              ),
              _ChromeButton(
                tooltip: _isMaximized ? '还原' : '最大化',
                icon: _isMaximized ? Icons.filter_none : Icons.crop_square,
                onPressed: _toggleMaximize,
              ),
              _ChromeButton(
                tooltip: '关闭',
                icon: Icons.close,
                isClose: true,
                onPressed: () => _run(widget.onClose ?? windowManager.close),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 标题栏拖动区。直接封装手势是为了让双击最大化也走顶栏的注入命令
/// 和统一错误处理，而不是绕过状态层调用插件默认实现。
class _TitleDragArea extends StatelessWidget {
  const _TitleDragArea({
    required this.child,
    required this.onPanStart,
    required this.onDoubleTap,
  });

  final Widget child;
  final VoidCallback onPanStart;
  final VoidCallback onDoubleTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => onPanStart(),
      onDoubleTap: onDoubleTap,
      child: child,
    );
  }
}

/// 将自定义标题栏和主窗口内容组合成完整的客户端布局。
class AppWindowFrame extends StatelessWidget {
  const AppWindowFrame({super.key, required this.child, this.titleBar});

  final Widget child;
  final Widget? titleBar;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        titleBar ?? const CustomTitleBar(),
        Expanded(child: child),
      ],
    );
  }
}

class _ChromeButton extends StatelessWidget {
  const _ChromeButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.isClose = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final bool isClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hoverColor = isClose
        ? scheme.errorContainer
        : scheme.surfaceContainerHighest;
    final iconColor = isClose ? scheme.onErrorContainer : scheme.onSurface;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        child: InkWell(
          onTap: onPressed,
          hoverColor: hoverColor,
          splashColor: hoverColor,
          child: SizedBox(
            width: 46,
            height: double.infinity,
            child: Icon(icon, size: 17, color: iconColor),
          ),
        ),
      ),
    );
  }
}
