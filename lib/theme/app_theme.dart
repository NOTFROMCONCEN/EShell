import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../state/app_state.dart';

class ResolvedTheme {
  const ResolvedTheme({
    required this.mode,
    required this.light,
    required this.dark,
  });

  final ThemeMode mode;
  final ColorScheme light;
  final ColorScheme dark;
}

/// 结合用户设置与（可用时的）壁纸动态色，生成最终配色方案。
ResolvedTheme resolveTheme({
  required ThemeSettings settings,
  required ColorScheme? lightDynamic,
  required ColorScheme? darkDynamic,
}) {
  // 条件内联到各分支：流分析在条件表达式的 then 分支中完成空安全提升，
  // 免去 lightDynamic!/darkDynamic! 的冗余断言（R7）。
  final light = settings.preferWallpaper && lightDynamic != null && darkDynamic != null
      ? lightDynamic.harmonized()
      : ColorScheme.fromSeed(
          seedColor: Color(settings.seedColor), brightness: Brightness.light);
  final dark = settings.preferWallpaper && lightDynamic != null && darkDynamic != null
      ? darkDynamic.harmonized()
      : ColorScheme.fromSeed(
          seedColor: Color(settings.seedColor), brightness: Brightness.dark);

  return ResolvedTheme(mode: settings.mode, light: light, dark: dark);
}

/// 全局视觉风格：**直角 + 1px 细线分隔**。
///
/// 2026-11-02 UI 迭代要求：整体避免圆角 UI，各模块之间用清晰线条分割。
/// 因此这里统一把组件主题里的圆角改成 0，并给 Card/Dialog/Popup 等补上
/// outlineVariant 描边；代码里零散的 `BorderRadius.circular(...)` 也同步改直。
class AppTheme {
  static const fontFamilyFallback = <String>[
    'Segoe UI Variable',
    'Segoe UI',
    'Microsoft YaHei UI',
  ];

  /// 直角边框（全局统一，不再使用圆角）。
  static const RoundedRectangleBorder squareShape =
      RoundedRectangleBorder(borderRadius: BorderRadius.zero);

  /// M4：明暗两套主题当前共用同一实现，仅 ColorScheme 不同——合并为单入口。
  /// 若日后需要为深色模式定制组件主题（如终端外的代码高亮），
  /// 在此按 scheme.brightness 分支即可。
  static ThemeData of(ColorScheme scheme) {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      fontFamilyFallback: fontFamilyFallback,
      splashFactory: InkSparkle.splashFactory,
      visualDensity: VisualDensity.comfortable,
    );

    final outline = BorderSide(color: scheme.outlineVariant);
    final squareWithOutline = RoundedRectangleBorder(
      borderRadius: BorderRadius.zero,
      side: outline,
    );

    return base.copyWith(
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        selectedIconTheme: IconThemeData(color: scheme.onSecondaryContainer),
        unselectedIconTheme: IconThemeData(color: scheme.onSurfaceVariant),
      ),
      // 线条：统一 1px，颜色走 outlineVariant；模块之间靠它分隔。
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: 1,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: scheme.surface,
        shape: squareWithOutline,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surface,
        elevation: 0,
        shape: squareWithOutline,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(shape: squareShape),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(elevation: 0, shape: squareShape),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(shape: squareShape),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(shape: squareShape),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(shape: squareShape),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(shape: const WidgetStatePropertyAll(squareShape)),
      ),
      searchBarTheme: SearchBarThemeData(
        elevation: const WidgetStatePropertyAll(0),
        shape: const WidgetStatePropertyAll(squareShape),
        side: WidgetStatePropertyAll(outline),
        backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerHigh),
      ),
      popupMenuTheme: PopupMenuThemeData(
        elevation: 3,
        color: scheme.surfaceContainer,
        shape: squareWithOutline,
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainer),
          shape: WidgetStatePropertyAll(squareWithOutline),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: scheme.inverseSurface,
          borderRadius: BorderRadius.zero,
        ),
        textStyle: TextStyle(color: scheme.onInverseSurface, fontSize: 12),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: TextStyle(color: scheme.onInverseSurface),
        shape: squareShape,
      ),
      chipTheme: ChipThemeData(
        shape: squareShape,
        side: outline,
        backgroundColor: scheme.surfaceContainerHigh,
      ),
      listTileTheme: const ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      ),
      // 输入框改为直角细线描边，和「线条分明」的整体风格一致。
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.zero),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: outline,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: BorderSide(color: scheme.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: BorderSide(color: scheme.error, width: 1.5),
        ),
      ),
    );
  }
}

/// 终端配色：界面层取自 ColorScheme，ANSI 16 色按明暗背景选择协调的一组。
extension TerminalScheme on ColorScheme {
  TerminalTheme toTerminalTheme() {
    final isDark = brightness == Brightness.dark;
    return TerminalTheme(
      cursor: primary,
      selection: secondaryContainer,
      foreground: isDark ? const Color(0xFFE6E1E5) : const Color(0xFF1D1B20),
      background: isDark ? const Color(0xFF141218) : const Color(0xFFFDF8FD),
      black: isDark ? const Color(0xFF49454F) : const Color(0xFF6750A4).withValues(alpha: 0.87),
      red: isDark ? const Color(0xFFFFB4AB) : const Color(0xFFB3261E),
      green: isDark ? const Color(0xFF9CD67D) : const Color(0xFF3D6D2A),
      yellow: isDark ? const Color(0xFFE9C46A) : const Color(0xFF8A6100),
      blue: isDark ? const Color(0xFFAAC7FA) : const Color(0xFF2A5298),
      magenta: isDark ? const Color(0xFFF0B4E8) : const Color(0xFF8E4585),
      cyan: isDark ? const Color(0xFF85D2E4) : const Color(0xFF1A6880),
      white: isDark ? const Color(0xFFE6E1E5) : const Color(0xFF4A4458),
      brightBlack: isDark ? const Color(0xFF7D7A80) : const Color(0xFF938F99),
      brightRed: isDark ? const Color(0xFFFFDAD6) : const Color(0xFFDC5749),
      brightGreen: isDark ? const Color(0xFFC0EAA8) : const Color(0xFF4F7E39),
      brightYellow: isDark ? const Color(0xFFF5DE9E) : const Color(0xFFA87E1D),
      brightBlue: isDark ? const Color(0xFFD3E3FD) : const Color(0xFF3E68B5),
      brightMagenta: isDark ? const Color(0xFFF8CEE8) : const Color(0xFFA85F9D),
      brightCyan: isDark ? const Color(0xFFB5E5F2) : const Color(0xFF31809A),
      brightWhite: isDark ? const Color(0xFFFFFFFF) : const Color(0xFF1D1B20),
      searchHitBackground: tertiaryContainer.withValues(alpha: 0.55),
      searchHitBackgroundCurrent: primaryContainer.withValues(alpha: 0.75),
      searchHitForeground: onPrimaryContainer,
    );
  }
}
