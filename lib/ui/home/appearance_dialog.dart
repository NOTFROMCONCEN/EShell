import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';

/// 外观设置：明暗模式 + Material You 种子色 + DPI 缩放 + 日志脱敏。
Future<void> showAppearanceDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => const _AppearanceDialog(),
  );
}

class _AppearanceDialog extends StatelessWidget {
  const _AppearanceDialog();

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

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppState>().settings;
    final scheme = Theme.of(context).colorScheme;

    return AlertDialog(
      icon: Icon(Icons.palette_outlined, color: scheme.primary),
      title: const Text('外观'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // C8：RadioListTile 的 groupValue/onChanged 已废弃，改用
              // SegmentedButton（与界面文字缩放控件保持一致）。
              SegmentedButton<ThemeMode>(
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
              const Divider(),
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 12),
                child: Text('Material You 种子色',
                    style: Theme.of(context)
                        .textTheme
                        .labelLarge
                        ?.copyWith(color: scheme.onSurfaceVariant)),
              ),
              Wrap(
                spacing: 14,
                runSpacing: 14,
                children: [
                  for (final entry in _seeds.entries)
                    _SeedSwatch(
                      color: Color(entry.key),
                      label: entry.value,
                      selected:
                          !settings.preferWallpaper &&
                              settings.seedColor == entry.key,
                      onTap: () => settings.setSeed(Color(entry.key)),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                '种子色将动态生成完整的 Material You 配色（主色、容器色、表面色等），'
                '并同步到终端光标、选区与状态指示。',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const Divider(),
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 4),
                child: Text('终端字号',
                    style: Theme.of(context)
                        .textTheme
                        .labelLarge
                        ?.copyWith(color: scheme.onSurfaceVariant)),
              ),
              Row(
                children: [
                  const Text('Aa', style: TextStyle(fontSize: 11)),
                  Expanded(
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
                  SizedBox(
                    width: 52,
                    child: Text(
                      '${settings.terminalFontSize.toStringAsFixed(0)} px',
                      textAlign: TextAlign.end,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 8),
                child: Text('界面文字缩放',
                    style: Theme.of(context)
                        .textTheme
                        .labelLarge
                        ?.copyWith(color: scheme.onSurfaceVariant)),
              ),
              SegmentedButton<double>(
                segments: const [
                  ButtonSegment(value: 1.0, label: Text('标准')),
                  ButtonSegment(value: 1.1, label: Text('110%')),
                  ButtonSegment(value: 1.25, label: Text('125%')),
                  ButtonSegment(value: 1.5, label: Text('150%')),
                ],
                selected: {settings.uiTextScale},
                onSelectionChanged: (v) => settings.setUiTextScale(v.first),
              ),
              const Divider(),
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 8),
                child: Text('整体界面缩放',
                    style: Theme.of(context)
                        .textTheme
                        .labelLarge
                        ?.copyWith(color: scheme.onSurfaceVariant)),
              ),
              SegmentedButton<double>(
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
              Padding(
                padding: const EdgeInsets.only(left: 4, top: 8),
                child: Text(
                  '整屏等比缩放（文字、图标、间距一起缩小），默认 90%（比系统缩放小一号）；'
                  '终端字号可在上方单独调节。',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
              const Divider(),
              // S2：会话日志脱敏开关（默认关闭，保持原始字节保真）。
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: settings.maskSecretsInLog,
                onChanged: settings.setMaskSecretsInLog,
                title: const Text('会话日志脱敏密码提示'),
                subtitle: Text(
                  '开启后 password: / 密码: 等回显在日志中记为掩码；'
                  '终端显示不受影响。逐包正则匹配，属尽力而为。',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('完成'),
        ),
      ],
    );
  }
}

class _SeedSwatch extends StatelessWidget {
  const _SeedSwatch({
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
        customBorder:
            const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: color,
            border: Border.fromBorderSide(
              selected
                  ? BorderSide(color: scheme.primary, width: 3)
                  : BorderSide(color: scheme.outlineVariant, width: 1),
            ),
          ),
          child: selected
              ? const Icon(Icons.check, size: 18, color: Colors.white)
              : null,
        ),
      ),
    );
  }
}
