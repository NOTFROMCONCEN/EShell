import 'package:flutter/material.dart';

/// 新建或重命名单层会话文件夹；只返回经过校验的名称。
Future<String?> showFolderNameDialog(
  BuildContext context, {
  required List<String> existing,
  String? initialName,
}) async {
  var draft = initialName ?? '';
  String? error;
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) {
        void submit() {
          final name = draft.trim();
          if (name.isEmpty) {
            setState(() => error = '名称不能为空');
          } else if (existing.any(
            (f) => f != initialName && f.toLowerCase() == name.toLowerCase(),
          )) {
            setState(() => error = '文件夹名称已存在');
          } else {
            Navigator.pop(dialogContext, name);
          }
        }

        return AlertDialog(
          title: Text(initialName == null ? '新建文件夹' : '重命名文件夹'),
          content: TextFormField(
            initialValue: initialName ?? '',
            onChanged: (value) => draft = value,
            autofocus: true,
            maxLength: 64,
            decoration: InputDecoration(
              labelText: '文件夹名称',
              errorText: error,
              prefixIcon: const Icon(Icons.folder_outlined),
            ),
            onFieldSubmitted: (_) => submit(),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(onPressed: submit, child: const Text('保存')),
          ],
        );
      },
    ),
  );
}

Future<bool> confirmDeleteFolder(
  BuildContext context, {
  required String name,
  required int sessionCount,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除文件夹'),
        content: Text('删除「$name」后，其中 $sessionCount 个会话会移到未分组。会话不会删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除文件夹'),
          ),
        ],
      ),
    ) ??
    false;
