// 通用格式化工具（供会话日志、UI 提示共用，避免重复实现）。

String _p2(int v) => v.toString().padLeft(2, '0');

/// 人类可读时间戳：2026-10-27 03:22:59
String formatTimestamp(DateTime t) =>
    '${t.year}-${_p2(t.month)}-${_p2(t.day)} '
    '${_p2(t.hour)}:${_p2(t.minute)}:${_p2(t.second)}';

/// 文件名安全时间戳：20261027-032259
String fileStamp([DateTime? time]) {
  final n = time ?? DateTime.now();
  return '${n.year}${_p2(n.month)}${_p2(n.day)}-'
      '${_p2(n.hour)}${_p2(n.minute)}${_p2(n.second)}';
}

/// Windows 文件名非法字符。
final _illegalChars = RegExp(r'[\\/:*?"<>|]');

/// 清理文件名中的非法字符；清空后回退为 "session"。
String sanitizeFileName(String name) {
  final cleaned = name.replaceAll(_illegalChars, '_').trim();
  return cleaned.isEmpty ? 'session' : cleaned;
}
