import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/session.dart';
import '../../services/telnet_scanner.dart';
import '../../state/app_state.dart';

/// 「快速扫描机内 Telnet 服务」对话框。
///
/// 面向 EVE-NG 工作流：EVE-NG 把每个运行中的节点控制台映射成
/// `telnet://<主机>:<端口>`（端口通常从 32768 起）。本对话框并发探测
/// 目标主机的端口区间，按「IAC 协商 / 有回显 / 无回显 / 非 Telnet」
/// 分类列出，点「连接」即以 Telnet 打开对应节点的终端。
/// [scanner] 仅供测试注入（默认使用真实端口探测器）。
Future<void> showTelnetScanDialog(
  BuildContext context, {
  TelnetScanner? scanner,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _TelnetScanDialog(scanner: scanner),
  );
}

class _TelnetScanDialog extends StatefulWidget {
  const _TelnetScanDialog({this.scanner});

  final TelnetScanner? scanner;

  @override
  State<_TelnetScanDialog> createState() => _TelnetScanDialogState();
}

class _TelnetScanDialogState extends State<_TelnetScanDialog> {
  late final TextEditingController _host;
  late final TextEditingController _start;
  late final TextEditingController _end;

  bool _scanning = false;
  bool _cancelled = false;
  bool _saveSessions = false;

  int _scanned = 0;
  int _total = 0;
  int _found = 0;
  List<TelnetScanResult> _results = const [];
  String? _error;

  @override
  void initState() {
    super.initState();
    final settings = context.read<AppState>().settings;
    _host = TextEditingController(text: settings.telnetScanHost);
    _start = TextEditingController(text: '${settings.telnetScanStartPort}');
    _end = TextEditingController(text: '${settings.telnetScanEndPort}');
  }

  @override
  void dispose() {
    _host.dispose();
    _start.dispose();
    _end.dispose();
    super.dispose();
  }

  Future<void> _startScan() async {
    final int startPort;
    final int endPort;
    try {
      final range = parsePortRange(_start.text, _end.text);
      startPort = range.start;
      endPort = range.end;
    } on FormatException catch (e) {
      setState(() => _error = e.message);
      return;
    }
    final host = _host.text.trim();
    if (host.isEmpty) {
      setState(() => _error = '目标主机不能为空');
      return;
    }

    final app = context.read<AppState>();
    app.settings.setTelnetScanTarget(
      host: host,
      startPort: startPort,
      endPort: endPort,
    );

    setState(() {
      _error = null;
      _scanning = true;
      _cancelled = false;
      _results = const [];
      _scanned = 0;
      _total = endPort - startPort + 1;
      _found = 0;
    });

    final scanner = widget.scanner ?? TelnetScanner();
    try {
      final results = await scanner.scan(
        host: host,
        startPort: startPort,
        endPort: endPort,
        isCancelled: () => _cancelled,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() {
            _scanned = progress.scanned;
            _found = progress.found;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _results = results;
        _scanned = _total;
        _found = results.length;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _error = '扫描失败：$e';
      });
    }
  }

  Future<void> _connect(TelnetScanResult result) async {
    final app = context.read<AppState>();
    final host = _host.text.trim();
    final session = Session(
      id: 'scan_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}',
      name: '',
      host: host,
      port: result.port,
      transport: SessionTransport.telnet,
      username: '',
      isTemporary: !_saveSessions,
    );
    if (_saveSessions) await app.upsert(session);
    if (!mounted) return;
    app.connect(session);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final busy = _scanning;

    return AlertDialog(
      icon: Icon(Icons.radar_rounded, color: scheme.primary, size: 32),
      title: const Text('扫描 Telnet 服务'),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: _host,
                      decoration: const InputDecoration(
                        labelText: '目标主机',
                        hintText: '127.0.0.1 或 EVE-NG 地址',
                        prefixIcon: Icon(Icons.dns_outlined),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _start,
                            keyboardType: TextInputType.number,
                            decoration:
                                const InputDecoration(labelText: '起始端口'),
                          ),
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 6),
                          child: Padding(
                            padding: EdgeInsets.only(top: 18),
                            child: Text('—'),
                          ),
                        ),
                        Expanded(
                          child: TextField(
                            controller: _end,
                            keyboardType: TextInputType.number,
                            decoration:
                                const InputDecoration(labelText: '结束端口'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '默认扫描本机 32768-32800（EVE-NG 节点控制台常用区间）。'
                'EVE-NG 运行在其他主机/虚拟网卡时，把目标主机改成对应地址即可。',
                style: textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: textTheme.bodySmall?.copyWith(color: scheme.error),
                ),
              ],
              if (busy) ...[
                const SizedBox(height: 16),
                LinearProgressIndicator(
                  value: _total == 0 ? null : _scanned / _total,
                  borderRadius: BorderRadius.zero,
                ),
                const SizedBox(height: 8),
                Text(
                  _cancelled
                      ? '正在停止…（等待进行中的探测结束）'
                      : '已扫描 $_scanned / $_total · 发现 $_found 个开放端口',
                  style: textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
              if (!busy && _total > 0) ...[
                const Divider(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _results.isEmpty
                            ? '未发现开放端口（已扫描 $_total 个端口）'
                            : '发现 ${_results.length} 个开放端口',
                        style: textTheme.labelLarge
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ),
                    if (_results.isNotEmpty)
                      Text(
                        '点击「连接」打开 Telnet 终端',
                        style: textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                  ],
                ),
              ],
              if (_results.isNotEmpty) ...[
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 300),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: _results.length,
                    separatorBuilder: (_, _) =>
                        Divider(height: 1, color: scheme.outlineVariant),
                    itemBuilder: (context, index) =>
                        _ResultTile(
                      result: _results[index],
                      host: _host.text.trim(),
                      onConnect: () => _connect(_results[index]),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: _saveSessions,
                onChanged: busy
                    ? null
                    : (v) => setState(() => _saveSessions = v),
                title: const Text('连接时保存为会话'),
                subtitle: Text(
                  '关闭时以临时标签打开，不写入会话列表',
                  style: textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            // 扫描中关闭：先请求取消，不阻塞界面关闭。
            _cancelled = true;
            Navigator.of(context).pop();
          },
          child: const Text('关闭'),
        ),
        FilledButton.icon(
          onPressed: busy
              ? () => setState(() => _cancelled = true)
              : _startScan,
          icon: Icon(
            busy ? Icons.stop_rounded : Icons.play_arrow_rounded,
            size: 18,
          ),
          label: Text(busy ? '停止' : (_total > 0 ? '重新扫描' : '开始扫描')),
        ),
      ],
    );
  }
}

class _ResultTile extends StatelessWidget {
  const _ResultTile({
    required this.result,
    required this.host,
    required this.onConnect,
  });

  final TelnetScanResult result;
  final String host;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final meta = _kindMeta(result.kind);
    final color = switch (result.kind) {
      TelnetProbeKind.telnet => scheme.primary,
      TelnetProbeKind.console => scheme.tertiary,
      TelnetProbeKind.silent => scheme.onSurfaceVariant,
      TelnetProbeKind.nonTelnet => scheme.error,
      TelnetProbeKind.closed => scheme.outline,
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              border: Border.all(color: color.withValues(alpha: 0.5)),
            ),
            child: Icon(meta.icon, size: 18, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('$host:${result.port}',
                        style: textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        )),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.zero,
                        border: Border.all(color: color.withValues(alpha: 0.5)),
                      ),
                      child: Text(
                        meta.label,
                        style: textTheme.labelSmall?.copyWith(color: color),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  result.banner.isEmpty ? meta.desc : result.banner,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.tonal(
            onPressed: onConnect,
            child: const Text('连接'),
          ),
        ],
      ),
    );
  }
}

({IconData icon, String label, String desc}) _kindMeta(
    TelnetProbeKind kind) =>
    switch (kind) {
      TelnetProbeKind.telnet => (
          icon: Icons.terminal_rounded,
          label: 'Telnet 协商',
          desc: '检测到 Telnet 选项协商',
        ),
      TelnetProbeKind.console => (
          icon: Icons.dvr_outlined,
          label: '有回显',
          desc: '收到可读回显，疑似设备控制台',
        ),
      TelnetProbeKind.silent => (
          icon: Icons.hourglass_empty_rounded,
          label: '无回显',
          desc: '端口开放但无输出（EVE-NG 直通控制台常见）',
        ),
      TelnetProbeKind.nonTelnet => (
          icon: Icons.warning_amber_rounded,
          label: '非 Telnet',
          desc: '响应不像终端（HTTP/SSH/TLS），不建议连接',
        ),
      TelnetProbeKind.closed => (
          icon: Icons.block_rounded,
          label: '未开放',
          desc: '端口未开放',
        ),
    };
