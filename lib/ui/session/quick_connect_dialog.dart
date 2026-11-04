import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/session.dart';
import '../../state/app_state.dart';
import '../../utils/connect_target.dart';

/// 快速连接：输入 user@host[:port] 直接建立会话。
Future<void> showQuickConnectDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => const _QuickConnectDialog(),
  );
}

class _QuickConnectDialog extends StatefulWidget {
  const _QuickConnectDialog();

  @override
  State<_QuickConnectDialog> createState() => _QuickConnectDialogState();
}

class _QuickConnectDialogState extends State<_QuickConnectDialog> {
  final _target = TextEditingController();
  final _password = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _target.dispose();
    _password.dispose();
    super.dispose();
  }

  /// C7：按 传输类型 + user@host:port 查找已保存的同类会话，避免每次保存都新增一条。
  Session? _findExisting(AppState app, ConnectTarget target) {
    for (final s in app.sessions) {
      if (s.transport == target.transport &&
          s.host == target.host &&
          s.port == target.port &&
          s.username == target.username) {
        return s;
      }
    }
    return null;
  }

  /// 输入形如 telnet://… 时不显示密码框（Telnet 无认证环节）。
  bool get _isTelnetInput {
    final text = _target.text.trim().toLowerCase();
    return text.startsWith('telnet://');
  }

  Future<void> _go({required bool save}) async {
    final app = context.read<AppState>();
    final ConnectTarget target;
    try {
      // C3：解析失败/端口越界直接报错，不再静默回退默认值。
      final parsed = parseConnectTarget(_target.text);
      if (parsed == null) return;
      target = parsed;
    } on FormatException catch (e) {
      setState(() => _error = e.message);
      return;
    }
    setState(() => _error = null);

    Session session;
    final existing = save ? _findExisting(app, target) : null;
    if (existing != null) {
      // 复用既有会话；本次输入了密码则顺带更新（仅 SSH）。
      session = target.transport == SessionTransport.ssh &&
              _password.text.isNotEmpty
          ? existing.copyWith(password: _password.text)
          : existing;
    } else {
      session = Session(
        id: DateTime.now().microsecondsSinceEpoch.toRadixString(36),
        name: '',
        host: target.host,
        port: target.port,
        transport: target.transport,
        username: target.username,
        password: target.transport == SessionTransport.ssh &&
                _password.text.isNotEmpty
            ? _password.text
            : null,
      );
    }
    if (save) {
      try {
        await app.upsert(session);
      } catch (e) {
        if (mounted) setState(() => _error = '保存会话失败：$e');
        return;
      }
    }
    if (!mounted) return;
    app.connect(session);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      icon: Icon(Icons.bolt_rounded,
          color: scheme.primary, size: 32),
      title: const Text('快速连接'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _target,
              autofocus: true,
              decoration: InputDecoration(
                labelText: '目标',
                hintText: 'admin@192.0.2.1 或 telnet://127.0.0.1:32768',
                helperText: '支持 [IPv6]:端口 · telnet://主机:端口 · 串口 COM3 或 COM3@115200',
                errorText: _error,
                errorMaxLines: 2,
                prefixIcon: const Icon(Icons.dns_outlined),
              ),
              onChanged: (_) => setState(() => _error = null),
              onSubmitted: (_) => _go(save: false),
            ),
            const SizedBox(height: 4),
            if (!_isTelnetInput)
              TextField(
                controller: _password,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '密码（可选）',
                  prefixIcon: Icon(Icons.lock_outline),
                ),
                onSubmitted: (_) => _go(save: false),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton.tonal(
          onPressed: _target.text.trim().isEmpty ? null : () => _go(save: true),
          child: const Text('连接并保存'),
        ),
        FilledButton(
          onPressed: _target.text.trim().isEmpty ? null : () => _go(save: false),
          child: const Text('连接'),
        ),
      ],
    );
  }
}
