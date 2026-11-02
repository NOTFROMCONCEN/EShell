import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../models/session.dart';
import '../../services/terminal_connection.dart';
import '../../state/app_state.dart';
import '../../utils/format.dart';

/// 会话日志：选择保存位置/文件名并开关记录。

/// 预填文件名：EShell_20261027-015500_会话显示名.log
String suggestLogFileName(Session session) =>
    'EShell_${fileStamp()}_${sanitizeFileName(session.displayName)}.log';

/// 弹出系统「另存为」对话框并开始记录。
Future<void> startLoggingWithDialog(
  BuildContext context,
  ThemeSettings settings,
  TerminalConnection conn,
) async {
  final dir = settings.logDirectory;
  final location = await getSaveLocation(
    initialDirectory: dir.isEmpty ? null : dir,
    suggestedName: suggestLogFileName(conn.session),
    acceptedTypeGroups: const [
      XTypeGroup(label: '会话日志', extensions: ['log', 'txt']),
      XTypeGroup(label: '所有文件'),
    ],
  ).catchError((Object e) {
    if (context.mounted) {
      _showSnack(context, '无法打开保存对话框：$e', error: true);
    }
    return null;
  });
  if (location == null) return;

  final path = location.path;
  final sep = path.lastIndexOf(Platform.pathSeparator);
  if (sep > 0) {
    settings.setLogDirectory(path.substring(0, sep));
  }

  // S2：脱敏开启时日志写入掩码文本（非原始字节）。
  final err = await conn.startLogging(
    path,
    maskSecrets: settings.maskSecretsInLog,
  );
  if (!context.mounted) return;
  if (err != null) {
    _showSnack(context, '日志记录启动失败：$err', error: true);
  } else {
    _showSnack(context, '开始记录会话日志：$path');
  }
}

/// R3：error 参数现在真正生效——错误提示使用 errorContainer 配色。
void _showSnack(BuildContext context, String message, {bool error = false}) {
  final scheme = Theme.of(context).colorScheme;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(
        message,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
            color: error ? scheme.onErrorContainer : scheme.onInverseSurface),
      ),
      width: 560,
      behavior: SnackBarBehavior.floating,
      showCloseIcon: true,
      backgroundColor: error ? scheme.errorContainer : null,
    ));
}
