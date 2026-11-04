import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/secret_store.dart';

import '../../services/ai_client.dart';
import '../../state/ai_state.dart';
import '../../state/app_state.dart';

/// AI 设置：OpenAI 兼容接口地址 / 模型 / API Key / 上下文行数 /
/// 思考强度 / 连接测试。
///
/// [target] 缺省用主窗口 AppState.ai；AI 独立子窗口注入本地设置实例，
/// 保存后经 [onSaved] 写盘并通知主窗口重载。
Future<void> showAiSettingsDialog(
  BuildContext context, {
  AiSettings? target,
  VoidCallback? onSaved,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _AiSettingsDialog(target: target, onSaved: onSaved),
  );
}

class _AiSettingsDialog extends StatefulWidget {
  const _AiSettingsDialog({this.target, this.onSaved});

  final AiSettings? target;
  final VoidCallback? onSaved;

  @override
  State<_AiSettingsDialog> createState() => _AiSettingsDialogState();
}

class _AiSettingsDialogState extends State<_AiSettingsDialog> {
  late final TextEditingController _baseUrl;
  late final TextEditingController _model;
  late final TextEditingController _apiKey;
  late int _contextLines;
  late String _reasoningEffort;

  bool _obscureKey = true;
  bool _testing = false;

  static const _effortLabels = {
    'off': '关闭',
    'low': '低',
    'medium': '中',
    'high': '高',
  };

  @override
  void initState() {
    super.initState();
    final ai = widget.target ?? context.read<AppState>().ai;
    _baseUrl = TextEditingController(text: ai.baseUrl);
    _model = TextEditingController(text: ai.model);
    _apiKey = TextEditingController(text: ai.apiKey);
    _contextLines = ai.contextLines;
    _reasoningEffort = ai.reasoningEffort;
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _model.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  AiSettings get _draft => AiSettings()
    ..baseUrl = _baseUrl.text.trim()
    ..model = _model.text.trim()
    ..apiKey = _apiKey.text.trim()
    ..contextLines = _contextLines
    ..reasoningEffort = _reasoningEffort;

  Future<void> _testConnection() async {
    final draft = _draft;
    if (!draft.configured) {
      _showSnack('请先填写 Base URL、模型与 API Key', error: true);
      return;
    }
    setState(() => _testing = true);
    final client = AiClient(
      baseUrl: draft.baseUrl,
      apiKey: draft.apiKey,
      model: draft.model,
    );
    String? first;
    String? error;
    try {
      await for (final chunk in client
          .streamChat(const [AiMessage(role: 'user', content: 'ping')])
          .timeout(const Duration(seconds: 30))) {
        if (!chunk.isEmpty) first = chunk.content;
        break;
      }
    } on AiException catch (e) {
      error = e.message;
    } catch (e) {
      error = '连接失败：$e';
    } finally {
      await client.close();
    }
    if (!mounted) return;
    setState(() => _testing = false);
    if (error != null) {
      _showSnack(error, error: true);
    } else if (first == null) {
      _showSnack('已连通，但服务端没有返回内容（请检查模型名）', error: true);
    } else {
      _showSnack('连接成功：${draft.model} 正常返回');
    }
  }

  void _showSnack(String message, {bool error = false}) {
    final scheme = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(
          message,
          style: TextStyle(
              color: error ? scheme.onErrorContainer : scheme.onInverseSurface),
        ),
        width: 520,
        behavior: SnackBarBehavior.floating,
        backgroundColor: error ? scheme.errorContainer : null,
      ));
  }

  void _save() {
    try {
      SecretStore.protect(_apiKey.text.trim());
    } catch (e) {
      _showSnack('保存 API Key 失败：$e', error: true);
      return;
    }
    final app = widget.target == null ? context.read<AppState>() : null;
    final ai = widget.target ?? app!.ai;
    ai.update(
      baseUrl: _baseUrl.text,
      model: _model.text,
      apiKey: _apiKey.text,
      contextLines: _contextLines,
      reasoningEffort: _reasoningEffort,
    );
    widget.onSaved?.call();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return AlertDialog(
      icon: Icon(Icons.auto_awesome, color: scheme.primary),
      title: const Text('AI 助手设置'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHigh,
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: Text(
                  '支持任意 OpenAI 兼容接口（默认 DeepSeek）。'
                  '每次提问会把「当前会话最近 N 行终端输出 + 你的问题」发送到该服务，'
                  'AI 只做分析、不会执行命令。API Key 在 Windows 上经 DPAPI 加密后本机保存。',
                  style: textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant, height: 1.5),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _baseUrl,
                decoration: const InputDecoration(
                  labelText: 'Base URL',
                  hintText: 'https://api.deepseek.com/v1',
                  prefixIcon: Icon(Icons.link),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _model,
                decoration: const InputDecoration(
                  labelText: '模型',
                  hintText: 'deepseek-chat',
                  prefixIcon: Icon(Icons.memory_outlined),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _apiKey,
                obscureText: _obscureKey,
                decoration: InputDecoration(
                  labelText: 'API Key',
                  hintText: '输入服务商 API Key',
                  prefixIcon: const Icon(Icons.key_outlined),
                  suffixIcon: IconButton(
                    tooltip: _obscureKey ? '显示' : '隐藏',
                    icon: Icon(
                        _obscureKey ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => _obscureKey = !_obscureKey),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text('每次提问携带的终端输出行数：$_contextLines 行',
                  style: textTheme.labelLarge
                      ?.copyWith(color: scheme.onSurfaceVariant)),
              Slider(
                value: _contextLines.toDouble(),
                min: AiSettings.minContextLines.toDouble(),
                max: AiSettings.maxContextLines.toDouble(),
                divisions:
                    (AiSettings.maxContextLines - AiSettings.minContextLines) ~/ 10,
                label: '$_contextLines 行',
                onChanged: (v) => setState(() => _contextLines = v.round()),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Text(
                  '行数越多上下文越完整，但 token 消耗也越高；默认 150 行。',
                  style: textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
              const SizedBox(height: 12),
              Text('思考强度（reasoning_effort）',
                  style: textTheme.labelLarge
                      ?.copyWith(color: scheme.onSurfaceVariant)),
              const SizedBox(height: 6),
              SegmentedButton<String>(
                segments: [
                  for (final effort in kAiReasoningEfforts)
                    ButtonSegment(
                      value: effort,
                      label: Text(_effortLabels[effort] ?? effort),
                    ),
                ],
                selected: {_reasoningEffort},
                onSelectionChanged: (selection) =>
                    setState(() => _reasoningEffort = selection.first),
                showSelectedIcon: false,
              ),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Text(
                  _reasoningEffort == 'off'
                      ? '关闭时不发送该参数；开启后模型会先思考再回答（返回思考过程，可折叠查看）。'
                      : '以 reasoning_effort=${_reasoningEffort.toLowerCase()} 随请求发送，需要模型支持；不支持时请选「关闭」。',
                  style: textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
              const Divider(height: 24),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _testing ? null : _testConnection,
                  icon: _testing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.network_check, size: 18),
                  label: Text(_testing ? '正在测试…' : '测试连接'),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _save,
          child: const Text('保存'),
        ),
      ],
    );
  }
}
