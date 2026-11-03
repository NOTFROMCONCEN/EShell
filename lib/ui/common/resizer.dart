import 'package:flutter/material.dart';

/// 面板宽度分隔条：8px 命中区里居中一根 1px 分隔线（视觉与
/// VerticalDivider 一致），悬停/拖动高亮为 primary，鼠标呈左右
/// 调整光标；拖动把水平增量交给 [onDrag]（由调用方按各自方向
/// 与边界换算宽度），[onDoubleTap] 通常用于恢复默认宽度。
///
/// 增量式（delta）而不是绝对坐标：在整体界面缩放（Transform.scale）
/// 下光标坐标会被正确缩放换算，拖动手感不偏移。
class PanelResizer extends StatefulWidget {
  const PanelResizer({
    super.key,
    required this.onDrag,
    this.onDoubleTap,
    required this.tooltip,
  });

  /// 收到水平拖动增量 delta.dx（向右为正）。
  final ValueChanged<double> onDrag;

  final VoidCallback? onDoubleTap;

  final String tooltip;

  @override
  State<PanelResizer> createState() => _PanelResizerState();
}

class _PanelResizerState extends State<PanelResizer> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeLeftRight,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: (details) => widget.onDrag(details.delta.dx),
          onDoubleTap: widget.onDoubleTap,
          // Row 非弹性子项收到的是无界宽度约束，Center 会缩到 1px；
          // 用固定宽度的 SizedBox 撑出 8px 命中区，分隔线保持居中。
          child: SizedBox(
            width: 8,
            child: Center(
              child: VerticalDivider(
                width: 1,
                thickness: 1,
                color: _hover ? scheme.primary : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
