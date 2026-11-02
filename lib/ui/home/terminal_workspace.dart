import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';

import '../../models/session.dart';
import '../../services/serial_connection.dart';
import '../../services/terminal_connection.dart';
import '../../state/app_state.dart';
import '../../theme/app_theme.dart';
import '../../utils/format.dart';
import '../session/quick_connect_dialog.dart';
import '../session/session_edit_dialog.dart';
import '../session/session_log.dart';

/// 右侧终端工作区：标签条 + 终端面板 / 空状态引导。
class TerminalWorkspace extends StatelessWidget {
  const TerminalWorkspace({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();

    if (app.tabs.isEmpty) {
      return const _EmptyWorkspace();
    }
    final activeIndex =
        app.tabs.indexWhere((t) => t.id == app.activeTabId).clamp(0, app.tabs.length - 1);
    final activeId = app.tabs[activeIndex].id;

    return Column(
      children: [
        _TabStrip(tabs: app.tabs, activeId: activeId),
        Divider(
            height: 1, thickness: 1, color: Theme.of(context).colorScheme.outlineVariant),
        Expanded(
          child: IndexedStack(
            index: activeIndex,
            // C4：把「是否活动」下发到 pane，pane 在变为活动时自请焦点。
            children:
                app.tabs.map((t) => _TerminalPane(tab: t, active: t.id == activeId)).toList(),
          ),
        ),
      ],
    );
  }
}

class _TabStrip extends StatelessWidget {
  const _TabStrip({required this.tabs, required this.activeId});

  final List<ConnectionTab> tabs;
  final String activeId;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      child: SizedBox(
        height: 46,
        child: Row(
          children: [
            const _SidebarToggle(),
            Expanded(
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                itemCount: tabs.length,
                itemBuilder: (context, i) =>
                    _TabChip(tab: tabs[i], selected: tabs[i].id == activeId),
              ),
            ),
            const SizedBox(width: 4),
            const _LogToggle(),
            const SizedBox(width: 4),
            const _FontSizeControls(),
            IconButton(
              tooltip: '快速连接',
              icon: const Icon(Icons.add),
              onPressed: () => showQuickConnectDialog(context),
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }
}

/// 侧边栏显示/隐藏切换（标签条最左侧，任何状态下可见）。
///
/// 设置变更由 main 的 AnimatedBuilder 驱动整树重建，这里 read 即可。
class _SidebarToggle extends StatelessWidget {
  const _SidebarToggle();

  @override
  Widget build(BuildContext context) {
    final settings = context.read<AppState>().settings;
    return IconButton(
      tooltip: settings.showSidebar
          ? '隐藏侧边栏 (Ctrl+Shift+B)'
          : '显示侧边栏 (Ctrl+Shift+B)',
      icon: Icon(
        settings.showSidebar
            ? Icons.menu_open_outlined
            : Icons.menu_outlined,
        size: 20,
      ),
      onPressed: () => settings.setShowSidebar(!settings.showSidebar),
    );
  }
}

/// C6：把 hostFingerprint / connectedAt 接入标签悬停提示。
String _tabTooltip(ConnectionTab tab) {
  final conn = tab.connection;
  final address = conn.session.address;
  return switch (conn.status) {
    ConnStatus.connecting => [
        '正在连接 $address',
        if (conn.statusDetail != null) conn.statusDetail!,
      ].join('\n'),
    ConnStatus.connected => () {
        final at = conn.connectedAt;
        final connectedLine =
            at == null ? null : '已连接于 ${formatTimestamp(at)}';
        final fp = conn.hostFingerprint;
        // 串口自动探测：展示探测到的实际波特率。
        final actualBaud = conn is SerialConnection ? conn.detectedBaud : null;
        return [
          address,
          if (actualBaud != null) '实际波特率 $actualBaud bps',
          if (connectedLine != null) connectedLine,
          if (fp != null) '主机密钥 $fp',
        ].join('\n');
      }(),
    ConnStatus.failed => '连接失败 · $address\n${conn.error ?? ''}',
    ConnStatus.closed => '连接已关闭 · $address',
  };
}

/// 活动标签页的会话日志开关：开启时弹系统对话框选位置/文件名，再点停止。
class _LogToggle extends StatelessWidget {
  const _LogToggle();

  Future<void> _toggle(BuildContext context) async {
    final app = context.read<AppState>();
    final conn = app.activeTab?.connection;
    if (conn == null) return;
    if (conn.logging) {
      await conn.stopLogging();
      if (context.mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(
            content: Text('会话日志已停止并保存'),
            behavior: SnackBarBehavior.floating,
            width: 360,
          ));
      }
    } else {
      await startLoggingWithDialog(context, app.settings, conn);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final conn = app.activeTab?.connection;
    final connected = conn?.status == ConnStatus.connected;
    final logging = conn?.logging ?? false;
    final scheme = Theme.of(context).colorScheme;

    return IconButton(
      tooltip: logging
          ? '停止记录日志\n${conn?.logPath ?? ''}'
          : connected
              ? '记录会话日志（选择保存位置和文件名）'
              : '记录会话日志（仅已连接的会话可用）',
      icon: Icon(
        logging ? Icons.description_rounded : Icons.description_outlined,
        size: 20,
        color: logging ? scheme.primary : null,
      ),
      onPressed: (conn == null || !connected) ? null : () => _toggle(context),
    );
  }
}

/// 标签栏右侧的终端字号控制（高 DPI 屏友好）。
class _FontSizeControls extends StatelessWidget {
  const _FontSizeControls();

  @override
  Widget build(BuildContext context) {
    final settings = context.read<AppState>().settings;
    final scheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: settings,
      builder: (context, _) => Row(
        children: [
          IconButton(
            tooltip: '减小终端字号 (Ctrl+-)',
            icon: const Icon(Icons.text_decrease_rounded, size: 20),
            onPressed: () => settings.bumpTerminalFontSize(-1),
          ),
          SizedBox(
            width: 30,
            child: Tooltip(
              message: '终端字号，Ctrl+0 重置',
              child: Text(
                settings.terminalFontSize.toStringAsFixed(0),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontFeatures: [const FontFeature.tabularFigures()],
                    ),
              ),
            ),
          ),
          IconButton(
            tooltip: '增大终端字号 (Ctrl+=)',
            icon: const Icon(Icons.text_increase_rounded, size: 20),
            onPressed: () => settings.bumpTerminalFontSize(1),
          ),
        ],
      ),
    );
  }
}

class _TabChip extends StatelessWidget {
  const _TabChip({required this.tab, required this.selected});

  final ConnectionTab tab;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Tooltip(
        message: _tabTooltip(tab),
        waitDuration: const Duration(milliseconds: 400),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => app.setActive(tab.id),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsetsDirectional.only(start: 12, end: 4),
            height: double.infinity,
            decoration: BoxDecoration(
              color: selected ? scheme.surfaceContainerHigh : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _StatusDot(status: tab.connection.status, scheme: scheme),
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 160),
                  child: Text(
                    tab.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
                          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                        ),
                  ),
                ),
                const SizedBox(width: 4),
                InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => app.closeTab(tab.id),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(Icons.close, size: 14, color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.status, required this.scheme});

  final ConnStatus status;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      ConnStatus.connected => scheme.primary,
      ConnStatus.connecting => scheme.tertiary,
      ConnStatus.failed => scheme.error,
      ConnStatus.closed => scheme.outlineVariant,
    };
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: status == ConnStatus.connected
            ? [BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 6)]
            : null,
      ),
    );
  }
}

/// 单个终端面板。
///
/// P2：TerminalStyle / TerminalTheme 未实现 ==，每次 build 传新实例会令
/// RenderTerminal 判定「主题变更」而失效全部段落缓存（10240 条 Paragraph
/// LRU 全部重排）。这里改为 StatefulWidget，按依赖（字号 / ColorScheme
/// 实例）记忆化，只有真正变化时才生成新实例。
///
/// C4：自管 FocusNode；pane 由非活动转为活动时自请焦点，键盘输入跟随标签。
class _TerminalPane extends StatefulWidget {
  const _TerminalPane({required this.tab, required this.active});

  final ConnectionTab tab;
  final bool active;

  @override
  State<_TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<_TerminalPane> {
  late final FocusNode _focusNode =
      FocusNode(debugLabel: 'terminal-${widget.tab.id}');

  TerminalStyle? _cachedStyle;
  double? _cachedStyleFontSize;

  TerminalTheme? _cachedTheme;
  ColorScheme? _cachedThemeScheme;

  @override
  void initState() {
    super.initState();
    if (widget.active) _requestFocusSoon();
  }

  @override
  void didUpdateWidget(_TerminalPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) _requestFocusSoon();
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _requestFocusSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.active) _focusNode.requestFocus();
    });
  }

  /// 终端区快捷键：Ctrl+= / Ctrl+- 调整字号，Ctrl+0 重置，
  /// Ctrl+Shift+B 显示/隐藏侧边栏。
  /// 这些组合未被 xterm 按键表映射，会从终端焦点向上冒泡到这里。
  static KeyEventResult _onZoomKey(
      FocusNode node, KeyEvent event, ThemeSettings settings) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (!HardwareKeyboard.instance.isControlPressed) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (HardwareKeyboard.instance.isShiftPressed &&
        key == LogicalKeyboardKey.keyB) {
      settings.setShowSidebar(!settings.showSidebar);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.equal ||
        key == LogicalKeyboardKey.numpadAdd) {
      settings.bumpTerminalFontSize(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.minus ||
        key == LogicalKeyboardKey.numpadSubtract) {
      settings.bumpTerminalFontSize(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.digit0 ||
        key == LogicalKeyboardKey.numpad0) {
      settings.resetTerminalFontSize();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  TerminalStyle _styleFor(double fontSize) {
    final cached = _cachedStyle;
    if (cached != null && _cachedStyleFontSize == fontSize) return cached;
    final style = TerminalStyle(
      fontSize: fontSize,
      height: 1.35,
      fontFamilyFallback: const [
        'Cascadia Mono',
        'Consolas',
        'Microsoft YaHei UI',
        'Courier New',
      ],
    );
    _cachedStyle = style;
    _cachedStyleFontSize = fontSize;
    return style;
  }

  TerminalTheme _themeFor(ColorScheme scheme) {
    final cached = _cachedTheme;
    if (cached != null && identical(_cachedThemeScheme, scheme)) return cached;
    final theme = scheme.toTerminalTheme();
    _cachedTheme = theme;
    _cachedThemeScheme = scheme;
    return theme;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final settings = context.read<AppState>().settings;

    return ChangeNotifierProvider<TerminalConnection>.value(
      value: widget.tab.connection,
      child: Consumer<TerminalConnection>(
        builder: (context, conn, _) {
          final blocked = conn.status != ConnStatus.connected;
          return Stack(
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  ignoring: blocked,
                  child: AnimatedBuilder(
                    animation: settings,
                    builder: (context, _) => TerminalView(
                      conn.terminal,
                      // C4：焦点由本 State 自管，活动切换时 requestFocus。
                      focusNode: _focusNode,
                      autofocus: false,
                      // 桌面端必须绕过 xterm 的 TextInput/IME 通道：
                      // 该通道在 Windows 上收不到普通字符（只有回车等
                      // 控制键可用），改走硬件按键事件按 character 注入。
                      hardwareKeyboardOnly: true,
                      padding: const EdgeInsets.all(12),
                      theme: _themeFor(scheme),
                      textStyle: _styleFor(settings.terminalFontSize),
                      onKeyEvent: (node, event) =>
                          _onZoomKey(node, event, settings),
                    ),
                  ),
                ),
              ),
              if (conn.hostKeyMismatch != null)
                Positioned.fill(child: _HostKeyOverlay(conn: conn))
              else ...[
                if (conn.status == ConnStatus.connecting)
                  Positioned.fill(child: _ConnectingOverlay(conn: conn)),
                if (conn.status == ConnStatus.failed)
                  Positioned.fill(child: _FailedOverlay(conn: conn)),
                if (conn.status == ConnStatus.closed)
                  Positioned.fill(child: _ClosedOverlay(conn: conn)),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// S3：主机指纹变化确认页——阻断连接，由用户决定更新记录或放弃。
class _HostKeyOverlay extends StatelessWidget {
  const _HostKeyOverlay({required this.conn});

  final TerminalConnection conn;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final mismatch = conn.hostKeyMismatch!;

    return Center(
      child: Card(
        elevation: 3,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 520),
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.gpp_maybe_outlined, color: scheme.error),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text('主机公钥指纹已变化',
                        style: Theme.of(context).textTheme.titleMedium),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                '${mismatch.host}:${mismatch.port} 的 ${mismatch.keyType} '
                '指纹与首次连接时的记录不一致。若服务器近期重装过系统属于正常；'
                '否则可能存在中间人攻击，请勿盲目更新。',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant, height: 1.5),
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('已记录：${mismatch.storedFingerprint}',
                        style: TextStyle(
                            fontSize: 12,
                            fontFamily: 'Consolas',
                            color: scheme.onSurfaceVariant)),
                    const SizedBox(height: 6),
                    Text('本次连接：${mismatch.actualFingerprint}',
                        style: TextStyle(
                            fontSize: 12,
                            fontFamily: 'Consolas',
                            color: scheme.error)),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => app
                        .closeTab(AppState.tabIdOf(conn.session.id)),
                    child: const Text('关闭标签'),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: conn.dismissHostKeyMismatch,
                    child: const Text('暂不处理'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: () => conn.acceptHostKey(),
                    icon: const Icon(Icons.update_rounded, size: 18),
                    label: const Text('更新指纹并重连'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConnectingOverlay extends StatelessWidget {
  const _ConnectingOverlay({required this.conn});

  final TerminalConnection conn;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Card(
        elevation: 3,
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(strokeWidth: 3),
              const SizedBox(height: 20),
              Text('正在连接 ${conn.session.address}',
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 6),
              Text(
                conn.statusDetail ??
                    (conn.session.transport == SessionTransport.serial
                        ? '打开串口 ${conn.session.host}'
                        : '用户 ${conn.session.username} · 正在协商加密通道'),
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FailedOverlay extends StatelessWidget {
  const _FailedOverlay({required this.conn});

  final TerminalConnection conn;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Card(
        elevation: 3,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 480),
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.error_outline, color: scheme.error),
                  const SizedBox(width: 10),
                  Text('连接失败',
                      style: Theme.of(context).textTheme.titleMedium),
                ],
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.errorContainer.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  conn.error ?? '未知错误',
                  style: TextStyle(
                      color: scheme.onErrorContainer, fontSize: 13, height: 1.4),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () =>
                        app.closeTab(AppState.tabIdOf(conn.session.id)),
                    child: const Text('关闭标签'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: () => conn.reconnect(),
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('重试'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ClosedOverlay extends StatelessWidget {
  const _ClosedOverlay({required this.conn});

  final TerminalConnection conn;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Card(
        elevation: 3,
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.link_off_outlined,
                  size: 32, color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(height: 12),
              Text('连接已关闭', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 20),
              FilledButton.tonalIcon(
                onPressed: () => conn.reconnect(),
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重新连接'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyWorkspace extends StatelessWidget {
  const _EmptyWorkspace();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;

    final recent = [...app.sessions]
      ..where((s) => s.lastConnectedAt != null).toList()
      ..sort((a, b) => (b.lastConnectedAt ?? DateTime(2000))
          .compareTo(a.lastConnectedAt ?? DateTime(2000)));
    final recentSessions =
        recent.where((s) => s.lastConnectedAt != null).take(6).toList();

    // 侧边栏隐藏 + 无标签时，标签条不存在，这里提供恢复入口。
    return Stack(
      children: [
        if (!app.settings.showSidebar)
          Positioned(
            top: 8,
            left: 8,
            child: IconButton(
              tooltip: '显示侧边栏 (Ctrl+Shift+B)',
              icon: const Icon(Icons.menu_outlined, size: 20),
              onPressed: () =>
                  app.settings.setShowSidebar(!app.settings.showSidebar),
            ),
          ),
        Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(40),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
            Container(
              width: 148,
              height: 148,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(Icons.terminal_rounded,
                  size: 68, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 28),
            Text('欢迎使用 EShell',
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(
              '一个秉承 Material You 设计的 SSH 终端',
              style: Theme.of(context)
                  .textTheme
                  .bodyLarge
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 32),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: () => showSessionEditDialog(context),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('新建会话'),
                ),
                const SizedBox(width: 12),
                FilledButton.tonalIcon(
                  onPressed: () => showQuickConnectDialog(context),
                  icon: const Icon(Icons.bolt_rounded, size: 18),
                  label: const Text('快速连接'),
                ),
              ],
            ),
            if (recentSessions.isNotEmpty) ...[
              const SizedBox(height: 36),
              Text('最近连接',
                  style: Theme.of(context)
                      .textTheme
                      .labelLarge
                      ?.copyWith(color: scheme.onSurfaceVariant)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: recentSessions
                    .map((s) => ActionChip(
                          avatar: Icon(Icons.history, size: 16, color: scheme.primary),
                          label: Text(s.displayName),
                          onPressed: () => app.connect(s),
                        ))
                    .toList(),
              ),
            ],
            ],
          ),
        ),
        ),
      ],
    );
  }
}
