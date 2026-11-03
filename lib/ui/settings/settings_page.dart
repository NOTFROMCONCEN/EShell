import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/telnet_scanner.dart';
import '../../state/app_state.dart';
import '../ai/ai_settings_dialog.dart';

/// 程序级设置页：把原本分散在外观、日志、扫描和 AI 弹窗里的选项集中管理。
Future<void> showSettingsPage(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const _SettingsDialog(),
  );
}

enum _SettingsSection { appearance, layout, logging, telnet, ai, about }

class _SettingsDialog extends StatefulWidget {
  const _SettingsDialog();

  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  _SettingsSection _section = _SettingsSection.appearance;
  late final TextEditingController _scanHost;
  late final TextEditingController _scanStart;
  late final TextEditingController _scanEnd;
  String? _scanHostError;
  String? _scanError;

  @override
  void initState() {
    super.initState();
    final settings = context.read<AppState>().settings;
    _scanHost = TextEditingController(text: settings.telnetScanHost);
    _scanStart = TextEditingController(text: '${settings.telnetScanStartPort}');
    _scanEnd = TextEditingController(text: '${settings.telnetScanEndPort}');
  }

  @override
  void dispose() {
    _scanHost.dispose();
    _scanStart.dispose();
    _scanEnd.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final availableHeight = MediaQuery.sizeOf(context).height - 48;
    final dialogHeight = math.min(680.0, availableHeight);
    return Dialog(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 980, maxHeight: availableHeight),
        child: SizedBox(
          height: dialogHeight,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(context),
              Divider(height: 1, color: scheme.outlineVariant),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(width: 220, child: _buildNavigation(context)),
                    VerticalDivider(width: 1, color: scheme.outlineVariant),
                    Expanded(child: _buildContent(context)),
                  ],
                ),
              ),
              Divider(height: 1, color: scheme.outlineVariant),
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('完成'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 16, 14),
      child: Row(
        children: [
          Icon(
            Icons.settings_outlined,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 10),
          Text('程序设置', style: Theme.of(context).textTheme.titleLarge),
          const Spacer(),
          Text(
            '修改会自动保存',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNavigation(BuildContext context) {
    final items = <(_SettingsSection, IconData, String, String)>[
      (
        _SettingsSection.appearance,
        Icons.palette_outlined,
        '外观与终端',
        '主题、字号和缩放',
      ),
      (_SettingsSection.layout, Icons.dashboard_outlined, '布局', '侧栏与 AI 面板'),
      (_SettingsSection.logging, Icons.article_outlined, '日志', '目录与敏感信息'),
      (
        _SettingsSection.telnet,
        Icons.radar_rounded,
        'Telnet 扫描',
        'EVE-NG 默认目标',
      ),
      (_SettingsSection.ai, Icons.auto_awesome_outlined, 'AI 助手', '接口、模型与上下文'),
      (_SettingsSection.about, Icons.info_outline, '关于', '版本与使用说明'),
    ];
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      children: [
        for (final item in items)
          ListTile(
            selected: _section == item.$1,
            leading: Icon(item.$2),
            title: Text(item.$3),
            subtitle: Text(
              item.$4,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.zero,
            ),
            onTap: () => setState(() => _section = item.$1),
          ),
      ],
    );
  }

  Widget _buildContent(BuildContext context) {
    final child = switch (_section) {
      _SettingsSection.appearance => _buildAppearance(context),
      _SettingsSection.layout => _buildLayout(context),
      _SettingsSection.logging => _buildLogging(context),
      _SettingsSection.telnet => _buildTelnet(context),
      _SettingsSection.ai => _buildAi(context),
      _SettingsSection.about => _buildAbout(context),
    };
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
      child: child,
    );
  }

  Widget _buildAppearance(BuildContext context) {
    final settings = context.watch<AppState>().settings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _title(context, '外观与终端', '控制程序颜色、文字大小和终端显示密度。'),
        _SettingSection(
          title: '主题模式',
          child: SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(
                value: ThemeMode.system,
                icon: Icon(Icons.brightness_auto_outlined),
                label: Text('跟随系统'),
              ),
              ButtonSegment(
                value: ThemeMode.light,
                icon: Icon(Icons.light_mode_outlined),
                label: Text('浅色'),
              ),
              ButtonSegment(
                value: ThemeMode.dark,
                icon: Icon(Icons.dark_mode_outlined),
                label: Text('深色'),
              ),
            ],
            selected: {settings.mode},
            onSelectionChanged: (v) => settings.setMode(v.first),
            showSelectedIcon: false,
          ),
        ),
        _SettingSection(
          title: 'Material You 种子色',
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final entry in _seeds.entries)
                _SeedButton(
                  color: Color(entry.key),
                  label: entry.value,
                  selected:
                      !settings.preferWallpaper &&
                      settings.seedColor == entry.key,
                  onTap: () => settings.setSeed(Color(entry.key)),
                ),
            ],
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('优先使用系统壁纸动态色'),
          subtitle: const Text('Windows 不提供动态色时自动回退到上面的种子色。'),
          value: settings.preferWallpaper,
          onChanged: settings.setPreferWallpaper,
        ),
        _SettingSection(
          title: '终端字号 · ${settings.terminalFontSize.toStringAsFixed(0)} px',
          child: Slider(
            value: settings.terminalFontSize,
            min: ThemeSettings.minTerminalFontSize,
            max: ThemeSettings.maxTerminalFontSize,
            divisions:
                (ThemeSettings.maxTerminalFontSize -
                        ThemeSettings.minTerminalFontSize)
                    .round(),
            label: '${settings.terminalFontSize.toStringAsFixed(0)} px',
            onChanged: settings.setTerminalFontSize,
          ),
        ),
        _SettingSection(
          title: '界面文字缩放',
          child: SegmentedButton<double>(
            segments: const [
              ButtonSegment(value: 1.0, label: Text('标准')),
              ButtonSegment(value: 1.1, label: Text('110%')),
              ButtonSegment(value: 1.25, label: Text('125%')),
              ButtonSegment(value: 1.5, label: Text('150%')),
            ],
            selected: {settings.uiTextScale},
            onSelectionChanged: (v) => settings.setUiTextScale(v.first),
            showSelectedIcon: false,
          ),
        ),
        _SettingSection(
          title: '整体界面缩放',
          description: '文字、图标和间距一起缩放；终端字号可以单独调节。',
          child: SegmentedButton<double>(
            segments: const [
              ButtonSegment(value: 0.75, label: Text('75%')),
              ButtonSegment(value: 0.8, label: Text('80%')),
              ButtonSegment(value: 0.9, label: Text('90%')),
              ButtonSegment(value: 1.0, label: Text('100%')),
            ],
            selected: {settings.uiScale},
            onSelectionChanged: (v) => settings.setUiScale(v.first),
            showSelectedIcon: false,
          ),
        ),
      ],
    );
  }

  Widget _buildLayout(BuildContext context) {
    final settings = context.watch<AppState>().settings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _title(context, '布局', '控制主窗口中的侧边栏和 AI 面板。'),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('显示会话侧边栏'),
          subtitle: const Text('隐藏后仍可用 Ctrl+Shift+B 恢复。'),
          value: settings.showSidebar,
          onChanged: settings.setShowSidebar,
        ),
        _SettingSection(
          title: '会话侧边栏宽度 · ${settings.sidebarWidth.toStringAsFixed(0)} px',
          child: Slider(
            value: settings.sidebarWidth,
            min: ThemeSettings.minSidebarWidth,
            max: ThemeSettings.maxSidebarWidth,
            divisions: 26,
            label: '${settings.sidebarWidth.toStringAsFixed(0)} px',
            onChanged: settings.setSidebarWidth,
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('显示 AI 助手面板'),
          subtitle: const Text('打开后会在终端右侧保留 AI 分析区域。'),
          value: settings.showAiPanel,
          onChanged: settings.setShowAiPanel,
        ),
        _SettingSection(
          title: 'AI 面板宽度 · ${settings.aiPanelWidth.toStringAsFixed(0)} px',
          child: Slider(
            value: settings.aiPanelWidth,
            min: ThemeSettings.minAiPanelWidth,
            max: ThemeSettings.maxAiPanelWidth,
            divisions: 26,
            label: '${settings.aiPanelWidth.toStringAsFixed(0)} px',
            onChanged: settings.setAiPanelWidth,
          ),
        ),
      ],
    );
  }

  Widget _buildLogging(BuildContext context) {
    final settings = context.watch<AppState>().settings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _title(context, '日志', '会话日志默认由另存为对话框选择文件名；这里设置默认目录和脱敏规则。'),
        _SettingSection(
          title: '默认保存目录',
          description: settings.logDirectory.isEmpty
              ? '未设置，使用系统默认目录。'
              : settings.logDirectory,
          child: Wrap(
            spacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: () => _pickLogDirectory(context, settings),
                icon: const Icon(Icons.folder_open_outlined),
                label: const Text('选择目录'),
              ),
              if (settings.logDirectory.isNotEmpty)
                TextButton(
                  onPressed: () => settings.setLogDirectory(''),
                  child: const Text('恢复系统默认'),
                ),
            ],
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('日志脱敏密码提示'),
          subtitle: const Text(
            '把常见 password: / 密码: 等回显写成掩码；终端显示不变。跨数据块匹配仍属于尽力而为。',
          ),
          value: settings.maskSecretsInLog,
          onChanged: settings.setMaskSecretsInLog,
        ),
        _SettingSection(
          title: '安全提示',
          child: Text(
            '日志可能包含设备输出、用户名、地址和命令结果。即使开启脱敏，也建议把日志目录放在受控位置，并按敏感文件管理。',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      ],
    );
  }

  Future<void> _pickLogDirectory(
    BuildContext context,
    ThemeSettings settings,
  ) async {
    try {
      final path = await getDirectoryPath(
        initialDirectory: settings.logDirectory.isEmpty
            ? null
            : settings.logDirectory,
        confirmButtonText: '选择目录',
      );
      if (path != null && context.mounted) {
        settings.setLogDirectory(path);
      }
    } on Object catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('选择日志目录失败：$error')));
    }
  }

  Widget _buildTelnet(BuildContext context) {
    final settings = context.watch<AppState>().settings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _title(context, 'Telnet 扫描', '保存 EVE-NG 或终端服务器的常用扫描目标，扫描对话框会直接使用这些值。'),
        _SettingSection(
          title: '目标主机',
          child: TextField(
            controller: _scanHost,
            decoration: InputDecoration(
              labelText: '主机名或 IP 地址',
              prefixIcon: const Icon(Icons.dns_outlined),
              errorText: _scanHostError,
            ),
            onChanged: (value) {
              final host = value.trim();
              setState(() => _scanHostError = host.isEmpty ? '目标主机不能为空' : null);
              if (host.isNotEmpty) {
                settings.setTelnetScanTarget(host: host);
              }
            },
          ),
        ),
        _SettingSection(
          title: '端口范围',
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _scanStart,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '起始端口'),
                  onChanged: (_) => _updateScanPorts(settings),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Text('至'),
              ),
              Expanded(
                child: TextField(
                  controller: _scanEnd,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '结束端口'),
                  onChanged: (_) => _updateScanPorts(settings),
                ),
              ),
            ],
          ),
        ),
        if (_scanError != null) ...[
          const SizedBox(height: 6),
          Text(
            _scanError!,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: Theme.of(context).colorScheme.error),
          ),
        ],
        Text(
          '单次最多扫描 4096 个端口；真正扫描时仍会校验 1–65535 范围。',
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }

  void _updateScanPorts(ThemeSettings settings) {
    try {
      final range = parsePortRange(_scanStart.text, _scanEnd.text);
      setState(() => _scanError = null);
      settings.setTelnetScanTarget(startPort: range.start, endPort: range.end);
    } on FormatException catch (error) {
      setState(() => _scanError = error.message.toString());
    }
  }

  Widget _buildAi(BuildContext context) {
    final ai = context.watch<AppState>().ai;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _title(context, 'AI 助手', 'AI 设置独立保存；API Key 在 Windows 上使用 DPAPI 加密。'),
        _SettingSection(
          title: '当前配置',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              ai.configured
                  ? Icons.check_circle_outline
                  : Icons.warning_amber_outlined,
              color: ai.configured
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.error,
            ),
            title: Text(ai.configured ? '${ai.model} · 已配置' : '尚未完成配置'),
            subtitle: Text(
              ai.baseUrl,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        FilledButton.tonalIcon(
          onPressed: () => showAiSettingsDialog(context),
          icon: const Icon(Icons.tune),
          label: const Text('打开 AI 详细设置'),
        ),
        const SizedBox(height: 12),
        Text(
          'AI 只读取当前终端上下文并生成分析文本，不会自动执行设备命令。',
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _buildAbout(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _title(context, '关于 EShell', '面向网络运维的 Windows SSH / Telnet / 串口终端。'),
        _SettingSection(
          title: '版本',
          child: const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.terminal_rounded),
            title: Text('EShell 0.1.0'),
            subtitle: Text('Flutter · Windows · SSH / Telnet / 串口'),
          ),
        ),
        _SettingSection(
          title: '数据位置',
          child: const Text(
            '会话和程序设置由 SharedPreferences 保存；SSH known_hosts 位于用户目录下的 .eshell/known_hosts。',
          ),
        ),
        _SettingSection(
          title: '重置说明',
          child: const Text('当前设置项会立即保存。删除会话、known_hosts 或密钥等数据仍需通过各自的明确操作完成。'),
        ),
      ],
    );
  }

  Widget _title(BuildContext context, String title, String subtitle) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  static const _seeds = <int, String>{
    0xFF415F91: '钢青',
    0xFF00696E: '湖青',
    0xFF3B6939: '松绿',
    0xFF8F4C38: '琥珀',
    0xFF9C4146: '玛瑙',
    0xFF7D5260: '蔷薇',
    0xFF6750A4: '紫罗兰',
    0xFF27379C: '藏蓝',
  };
}

class _SettingSection extends StatelessWidget {
  const _SettingSection({
    required this.title,
    required this.child,
    this.description,
  });

  final String title;
  final String? description;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          if (description != null) ...[
            const SizedBox(height: 3),
            Text(
              description!,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

class _SeedButton extends StatelessWidget {
  const _SeedButton({
    required this.color,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: label,
      child: InkWell(
        onTap: onTap,
        child: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: color,
            border: Border.all(
              color: selected ? scheme.primary : scheme.outlineVariant,
              width: selected ? 3 : 1,
            ),
          ),
          child: selected
              ? const Icon(Icons.check, color: Colors.white, size: 18)
              : null,
        ),
      ),
    );
  }
}
