import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/session.dart';
import '../../services/serial_port.dart';
import '../../state/app_state.dart';
import '../../utils/connect_target.dart';

/// 新建 / 编辑会话对话框。
///
/// C5：编辑时不再就地改写活动中的会话对象——所有输入只存在控制器里，
/// 点「保存」才通过 copyWith 生成新实例并 upsert 替换；点「取消」原对象
/// 分毫不动。S4：私钥口令使用独立 passphrase 字段，不再占用登录密码。
///
/// 串口支持：连接类型切到「串口」后配置 COM 口（可扫描）与波特率（8N1）。
Future<void> showSessionEditDialog(BuildContext context,
    {Session? initial}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => _SessionEditDialog(initial: initial),
  );
}

class _SessionEditDialog extends StatefulWidget {
  const _SessionEditDialog({this.initial});

  final Session? initial;

  @override
  State<_SessionEditDialog> createState() => _SessionEditDialogState();
}

class _SessionEditDialogState extends State<_SessionEditDialog> {
  late final Session _base;
  late SessionTransport _transport;
  late SshAuthType _authType;
  late int _baud;
  late bool _autoBaud;
  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _passphrase;
  late final TextEditingController _keyPath;
  late final TextEditingController _tag;

  bool _scanning = false;
  List<String> _availablePorts = const [];

  @override
  void initState() {
    super.initState();
    final s = widget.initial;
    _base = s ??
        Session(
          id: DateTime.now().microsecondsSinceEpoch.toRadixString(36),
          name: '',
          host: '',
          username: 'root',
        );
    _transport = _base.transport;
    _authType = _base.authType;
    _baud = kSerialBaudRates.contains(_base.port) ? _base.port : 9600;
    _autoBaud = _base.autoBaud;
    _name = TextEditingController(text: _base.name);
    _host = TextEditingController(text: _base.host);
    _port = TextEditingController(text: _base.port.toString());
    _username = TextEditingController(text: _base.username);
    _password = TextEditingController(text: _base.password ?? '');
    _passphrase = TextEditingController(text: _base.passphrase ?? '');
    _keyPath = TextEditingController(text: _base.privateKeyPath ?? '');
    _tag = TextEditingController(text: _base.tag ?? '');
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _host,
      _port,
      _username,
      _password,
      _passphrase,
      _keyPath,
      _tag
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  bool _validate() {
    if (_transport == SessionTransport.serial) {
      if (!_isValidComName(_host.text)) return false;
      return _baud >= 110 && _baud <= 4000000;
    }    if (_host.text.trim().isEmpty) return false;
    if (_username.text.trim().isEmpty) return false;
    final port = int.tryParse(_port.text.trim());
    if (port == null || port < 1 || port > 65535) return false;
    if (_authType == SshAuthType.publicKey && _keyPath.text.trim().isEmpty) {
      return false;
    }
    return true;
  }

  static bool _isValidComName(String text) =>
      RegExp(r'^com\d+$', caseSensitive: false).hasMatch(text.trim());

  /// 扫描可用串口：模态加载框 + 后台 isolate。
  /// 扫描在 isolate 中运行，加载框动画流畅、UI 不冻结。
  Future<void> _scanPorts() async {
    if (_scanning) return;
    final scheme = Theme.of(context).colorScheme;
    setState(() => _scanning = true);

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(strokeWidth: 3),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('正在扫描串口…',
                        style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 4),
                    Text('枚举 COM1-99 中当前可用的端口',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    var ports = const <String>[];
    try {
      ports = await SerialPort.scanAvailable();
    } catch (_) {
      ports = const <String>[];
    }

    if (!mounted) return;
    Navigator.of(context).pop(); // 关闭加载框
    setState(() {
      _scanning = false;
      _availablePorts = ports;
      if (ports.isNotEmpty && !_isValidComName(_host.text)) {
        _host.text = ports.first;
      }
    });
    if (ports.isEmpty && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          content: Text('未发现可用的串口（COM1-99）'),
          width: 360,
          behavior: SnackBarBehavior.floating,
        ));
    }
  }

  void _save(AppState app, {required bool connect}) {
    if (!_validate()) return;
    // C5：从 base 生成全新实例，base 与已打开标签中的旧实例不被就地修改。
    final updated = _transport == SessionTransport.serial
        ? _base.copyWith(
            name: _name.text.trim(),
            transport: SessionTransport.serial,
            host: _host.text.trim().toUpperCase(),
            port: _baud,
            autoBaud: _autoBaud,
            username: '',
            authType: SshAuthType.password,
            password: null,
            passphrase: null,
            privateKeyPath: null,
            tag: _tag.text.trim().isEmpty ? null : _tag.text.trim(),
          )
        : _base.copyWith(
            name: _name.text.trim(),
            transport: SessionTransport.ssh,
            host: _host.text.trim(),
            port: int.parse(_port.text.trim()),
            username: _username.text.trim(),
            authType: _authType,
            password: _password.text.isEmpty ? null : _password.text,
            passphrase: _passphrase.text.isEmpty ? null : _passphrase.text,
            privateKeyPath: _authType == SshAuthType.publicKey
                ? _keyPath.text.trim()
                : null,
            tag: _tag.text.trim().isEmpty ? null : _tag.text.trim(),
          );

    app.upsert(updated);
    if (connect) app.connect(updated);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isEdit = widget.initial != null;
    final isSerial = _transport == SessionTransport.serial;

    return AlertDialog(
      title: Text(isEdit ? '编辑会话' : '新建会话'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: '名称',
                  hintText: '留空则使用默认名称',
                  prefixIcon: Icon(Icons.label_outline),
                ),
              ),
              const SizedBox(height: 4),
              TextField(
                controller: _tag,
                decoration: const InputDecoration(
                  labelText: '分组标签',
                  hintText: '如：核心交换机、生产环境',
                  prefixIcon: Icon(Icons.folder_outlined),
                ),
              ),
              const SizedBox(height: 18),
              Text('连接类型',
                  style: Theme.of(context)
                      .textTheme
                      .labelLarge
                      ?.copyWith(color: scheme.onSurfaceVariant)),
              const SizedBox(height: 8),
              SegmentedButton<SessionTransport>(
                segments: const [
                  ButtonSegment(
                    value: SessionTransport.ssh,
                    icon: Icon(Icons.lan_outlined),
                    label: Text('SSH'),
                  ),
                  ButtonSegment(
                    value: SessionTransport.serial,
                    icon: Icon(Icons.cable_outlined),
                    label: Text('串口'),
                  ),
                ],
                selected: {_transport},
                onSelectionChanged: (v) =>
                    setState(() => _transport = v.first),
              ),
              const SizedBox(height: 12),
              if (isSerial) ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _host,
                        decoration: InputDecoration(
                          labelText: '串口号 *',
                          hintText: 'COM3',
                          helperText: _availablePorts.isEmpty
                              ? '8N1 · 可点击右侧扫描'
                              : '当前可用：${_availablePorts.join(', ')}',
                          prefixIcon: const Icon(Icons.cable_outlined),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '扫描可用串口（COM1-99）',
                      onPressed: _scanning ? null : _scanPorts,
                      icon: _scanning
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2))
                          : const Icon(Icons.radar_outlined),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: _autoBaud,
                  onChanged: (v) => setState(() => _autoBaud = v),
                  title: const Text('自动探测波特率'),
                  subtitle: Text(
                    _autoBaud
                        ? '按 9600 → 115200 → … 顺序试探（约 2-4 秒）；'
                            '下拉波特率仅作探测失败兜底'
                        : '下拉波特率直接生效；老设备 Console 默认 9600',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
                DropdownButtonFormField<int>(
                  initialValue: _baud,
                  decoration: InputDecoration(
                    labelText: _autoBaud ? '兜底波特率' : '波特率',
                    prefixIcon: const Icon(Icons.speed_outlined),
                    enabled: !_autoBaud,
                  ),
                  items: kSerialBaudRates
                      .map((b) => DropdownMenuItem<int>(
                            value: b,
                            child: Text('$b bps'),
                          ))
                      .toList(),
                  onChanged: _autoBaud
                      ? null
                      : (v) => setState(() => _baud = v ?? 9600),
                ),
              ] else ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: _host,
                        decoration: const InputDecoration(
                          labelText: '主机 *',
                          prefixIcon: Icon(Icons.dns_outlined),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 1,
                      child: TextField(
                        controller: _port,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: '端口',
                          prefixIcon: Icon(Icons.numbers),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                TextField(
                  controller: _username,
                  decoration: const InputDecoration(
                    labelText: '用户名 *',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                ),
                const SizedBox(height: 18),
                Text('认证方式',
                    style: Theme.of(context)
                        .textTheme
                        .labelLarge
                        ?.copyWith(color: scheme.onSurfaceVariant)),
                const SizedBox(height: 8),
                SegmentedButton<SshAuthType>(
                  segments: const [
                    ButtonSegment(
                      value: SshAuthType.password,
                      icon: Icon(Icons.password_outlined),
                      label: Text('密码'),
                    ),
                    ButtonSegment(
                      value: SshAuthType.publicKey,
                      icon: Icon(Icons.key_outlined),
                      label: Text('私钥'),
                    ),
                  ],
                  selected: {_authType},
                  onSelectionChanged: (v) =>
                      setState(() => _authType = v.first),
                ),
                const SizedBox(height: 12),
                if (_authType == SshAuthType.password)
                  TextField(
                    controller: _password,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: '密码',
                      prefixIcon: Icon(Icons.lock_outline),
                    ),
                  )
                else ...[
                  TextField(
                    controller: _keyPath,
                    decoration: const InputDecoration(
                      labelText: '私钥文件路径 *',
                      hintText: 'C:\\Users\\you\\.ssh\\id_rsa',
                      prefixIcon: Icon(Icons.file_open_outlined),
                    ),
                  ),
                  const SizedBox(height: 4),
                  TextField(
                    controller: _passphrase,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: '私钥口令（如有）',
                      prefixIcon: Icon(Icons.lock_outline),
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton.tonal(
          onPressed: !_validate() ? null : () => _save(context.read<AppState>(), connect: false),
          child: Text(isEdit ? '保存' : '仅保存'),
        ),
        FilledButton(
          onPressed: !_validate() ? null : () => _save(context.read<AppState>(), connect: true),
          child: const Text('保存并连接'),
        ),
      ],
    );
  }
}
