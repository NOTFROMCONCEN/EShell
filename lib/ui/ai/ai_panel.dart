import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../services/ai_agent.dart';
import '../../services/ai_client.dart';
import '../../services/ai_context.dart' as ai_context;
import '../../services/ai_prompt.dart';
import '../../services/clipboard_image.dart';
import '../../state/ai_state.dart';
import '../../state/app_state.dart';
import '../../utils/ai_markdown.dart';
import '../../utils/format.dart';
import 'ai_settings_dialog.dart';

/// AI 助手分析面板（命令经用户确认后发送到终端，AI 不自动执行）。
///
/// 发送内容：当前活动会话最近 N 行终端输出 + 用户问题；
/// 回复以 SSE 流式追加到对话里，代码块可一键复制或一键发送到终端。
///
/// 停靠面板不传注入参数（内部从 AppState 取状态）；AI 独立子窗口
/// 通过 [chatOverride] / [settingsOverride] / [contextProvider] 注入
/// 子窗口本地的对话与设置，终端上下文经 IPC 向主窗口索取。

/// 组装导出 TXT 文本（头部元信息 + 正文原文；纯函数便于单测）。
String buildAiExportText({
  required String content,
  required String model,
  required DateTime time,
  String? sessionName,
}) {
  final header = StringBuffer()
    ..writeln('EShell AI 导出')
    ..writeln('时间: ${formatTimestamp(time)}')
    ..writeln('模型: $model');
  if (sessionName != null && sessionName.isNotEmpty) {
    header.writeln('会话: $sessionName');
  }
  header.writeln();
  return '$header$content\n';
}
class AiAssistantPanel extends StatefulWidget {
  const AiAssistantPanel({
    super.key,
    this.clientFactory,
    this.chatOverride,
    this.settingsOverride,
    this.contextProvider,
    this.sessionNameProvider,
    this.onCloseOverride,
    this.onPopOut,
    this.onSettingsSaved,
    this.exportWriter,
    this.commandSender,
    this.outputDeltaProvider,
    this.scanProvider,
  });

  /// 测试可注入假的流式客户端；默认按设置构造真实 [AiClient]。
  final AiStreamingClient Function(AiSettings settings)? clientFactory;

  /// 子窗口注入：本地对话状态（缺省用 AppState.aiChat）。
  final AiChat? chatOverride;

  /// 子窗口注入：本地 AI 设置（缺省用 AppState.ai）。
  final AiSettings? settingsOverride;

  /// 终端上下文获取（缺省从 AppState 直接构建）。
  /// 子窗口传 IPC 版本：向主窗口索取活动会话的终端输出。
  final Future<String> Function()? contextProvider;

  /// 活动会话名（导出 TXT 头部元信息用；缺省取 AppState 活动标签）。
  final String Function()? sessionNameProvider;

  /// 关闭面板动作（缺省隐藏停靠面板；子窗口传关闭自身窗口）。
  final VoidCallback? onCloseOverride;

  /// 弹出为独立窗口（非空时头部显示弹出按钮）。
  final VoidCallback? onPopOut;

  /// 设置保存后的回调（子窗口：写盘并通知主窗口重载）。
  final VoidCallback? onSettingsSaved;

  /// 写出导出文件（默认真实写盘；测试注入内存实现——
  /// testWidgets 的 FakeAsync zone 里 dart:io 异步写盘不会完成）。
  final Future<void> Function(String path, String text)? exportWriter;

  /// 把命令写入当前终端（AI「发送到终端」按钮；用户点击确认后才执行）。
  /// 返回 null=成功，非 null=用户可读错误。缺省（null）时命令块不显示
  /// 发送按钮；子窗口传 IPC 版本（主窗口代为执行）。
  final Future<String?> Function(String command)? commandSender;

  /// 取「上一次命令发送后」的新增终端输出（Agent 增量回传，避免每步
  /// 重发整屏上下文造成 token 膨胀）。缺省时回退为整屏上下文采样。
  final Future<String> Function()? outputDeltaProvider;

  /// Telnet 端口扫描能力（Agent ```scan 块执行用）。缺省时扫描动作
  /// 回传「扫描不可用」；子窗口传 IPC 版本（主窗口代为执行）。
  final Future<String> Function(AgentScanRequest request)? scanProvider;

  @override
  State<AiAssistantPanel> createState() => _AiAssistantPanelState();
}

class _AiAssistantPanelState extends State<AiAssistantPanel> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  AiStreamingClient? _client;
  AiChat? _chat;
  int _requestId = 0;
  bool _requestActive = false;

  /// 待发送的图片附件（Ctrl+V 粘贴 / 选择文件；发送后清空）。
  final List<AiImage> _pendingImages = [];
  bool _attaching = false;

  /// 单条消息最多附带的图片数（视觉 token 与请求体量控制）。
  static const int _maxImagesPerMessage = 4;

  AiChat get _effectiveChat =>
      widget.chatOverride ?? context.read<AppState>().aiChat;

  AiSettings get _effectiveSettings =>
      widget.settingsOverride ?? context.read<AppState>().ai;

  @override
  void initState() {
    super.initState();
    final chat = _effectiveChat;
    _chat = chat;
    chat.addListener(_onChatChanged);
  }

  @override
  void didUpdateWidget(AiAssistantPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final chat = _effectiveChat;
    if (!identical(chat, _chat)) {
      _chat?.removeListener(_onChatChanged);
      _chat = chat;
      chat.addListener(_onChatChanged);
    }
  }

  @override
  void dispose() {
    _chat?.removeListener(_onChatChanged);
    _requestId++;
    unawaited(_client?.close());
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onChatChanged() {
    // 流式追加时自动滚到底部。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    });
  }

  Future<bool> _ensureConfigured() async {
    if (_effectiveSettings.configured) return true;
    await showAiSettingsDialog(
      context,
      target: widget.settingsOverride,
      onSaved: widget.onSettingsSaved,
    );
    if (!mounted) return false;
    return _effectiveSettings.configured;
  }

  /// 发送一条用户提问（面板输入框 / 快捷提问入口）。
  Future<void> _send(String prompt) async {
    // 允许「只有图片没有文字」：给默认说明让模型结合图分析。
    final text = prompt.trim().isEmpty && _pendingImages.isNotEmpty
        ? '请结合附图分析。'
        : prompt.trim();
    if (text.isEmpty) return;
    final chat = _effectiveChat;
    if (chat.sending || _requestActive) {
      // 静默丢弃会让用户以为「消息没发出去/失忆」，明确提示。
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          content: Text('上一条回复仍在生成：请等待完成或点停止后再发送'),
          width: 380,
          behavior: SnackBarBehavior.floating,
        ));
      return;
    }
    final images = List<AiImage>.of(_pendingImages);
    _requestActive = true;
    try {
      if (!await _ensureConfigured()) return;
      if (!mounted) return;
      final gen = ++_requestId;
      await _runCompletion(text, addUser: true, generation: gen, images: images);
      // Agent 模式：自动执行回复中的 ```run 命令块并继续多步任务。
      if (mounted && gen == _requestId && _effectiveSettings.agentMode) {
        await _runAgentLoop(gen, text);
      }
    } finally {
      _requestActive = false;
    }
  }

  /// 重新生成：移除最后一条 assistant 回复，用上一条用户提问（含图片）重发。
  Future<void> _regenerate() async {
    final chat = _effectiveChat;
    if (chat.sending || _requestActive || chat.messages.isEmpty) return;
    final last = chat.messages.last;
    if (last.role != 'assistant' || last.pending) return;
    AiChatMessage? userMessage;
    for (var i = chat.messages.length - 2; i >= 0; i--) {
      if (chat.messages[i].role == 'user') {
        userMessage = chat.messages[i];
        break;
      }
    }
    final prompt = userMessage?.content.trim();
    if (prompt == null || prompt.isEmpty) return;
    _requestActive = true;
    try {
      chat.popLastAssistant();
      await _runCompletion(prompt,
          images: userMessage?.images ?? const <AiImage>[]);
    } finally {
      _requestActive = false;
    }
  }

  /// 构造上下文并发起一次流式补全（发送 / 重新生成 / Agent 续步共用）。
  ///
  /// [generation] 由调用方持有整个请求链路的代际号（Agent 循环跨多次
  /// 请求共用一个代际号，停止即整链终止）；缺省时自增开启新链路。
  /// [includeContext] 为 false 时不附带整屏终端上下文（Agent 续步用）。
  /// [images] 为本条用户消息附带的图片（多模态，需模型支持视觉）。
  Future<void> _runCompletion(
    String text, {
    bool addUser = false,
    int? generation,
    bool includeContext = true,
    List<AiImage> images = const [],
  }) async {
    final chat = _effectiveChat;
    final settings = _effectiveSettings;
    final requestId = generation ?? ++_requestId;
    final contextText = includeContext
        ? await (widget.contextProvider?.call() ??
            Future.value(ai_context.buildContextFromAppState(
                context.read<AppState>())))
        : '';
    if (!mounted || requestId != _requestId) return;
    final history = chat.historyForRequest();
    if (addUser) {
      chat.addUser(text, images: images);
      _input.clear();
      if (images.isNotEmpty && mounted) {
        setState(() => _pendingImages.clear());
      }
    }
    chat.beginAssistant();

    final client = widget.clientFactory?.call(settings) ??
        AiClient(
          baseUrl: settings.baseUrl,
          apiKey: settings.apiKey,
          model: settings.model,
          reasoningEffort: settings.reasoningEffort,
        );
    _client = client;

    try {
      final messages = buildAiMessages(
        context: contextText,
        prompt: text,
        history: history,
        promptImages: images,
        agentMode: settings.agentMode,
      );
      var truncated = false;
      await for (final chunk in client.streamChat(messages)) {
        if (!mounted || requestId != _requestId) return;
        if (chunk.reasoning.isNotEmpty) chat.appendReasoning(chunk.reasoning);
        if (chunk.content.isNotEmpty) chat.appendChunk(chunk.content);
        if (chunk.finishReason == 'length') truncated = true;
      }
      if (mounted && requestId == _requestId) {
        chat.finishAssistant(truncated: truncated);
      }
    } on AiIncompleteResponseException catch (e) {
      if (mounted && requestId == _requestId) chat.interrupt(e.message);
    } on AiException catch (e) {
      if (mounted && requestId == _requestId) chat.fail(e.message);
    } catch (e) {
      if (mounted && requestId == _requestId) chat.fail('请求失败：$e');
    } finally {
      if (identical(_client, client)) _client = null;
      await client.close();
    }
  }

  /// Agent 自动执行链路：分析回复里的 ```run 命令块 → 安全分级 →
  /// 执行（危险命令弹确认）→ 回传最新终端输出 → 让模型继续，直到
  /// 没有待执行命令 / 用户停止 / 达到步数上限。
  ///
  /// [task] 为用户本次的原始任务文本：每步续步都把它锚定在提示词里，
  /// 防止历史窗口滚动后模型忘记目标（表现为「丢失记忆」）。
  Future<void> _runAgentLoop(int gen, String task) async {
    final sender = widget.commandSender;
    for (var step = 1; step <= agentMaxSteps; step++) {
      if (!mounted || gen != _requestId) return;
      final chat = _effectiveChat;
      final last = chat.messages.lastOrNull;
      if (last == null || last.role != 'assistant' || last.pending) return;

      // ---- 端口扫描动作（```scan 块，优先于命令执行） ----
      final scanRaw = extractScanBlock(last.content);
      if (scanRaw != null) {
        AgentScanRequest request;
        try {
          request = parseScanRequest(scanRaw);
        } on FormatException catch (e) {
          if (!mounted || gen != _requestId) return;
          chat.addUser('【扫描请求无效】${e.message}\n'
              '请修正 JSON 后重试（示例：{"host":"127.0.0.1",'
              '"startPort":32768,"endPort":32800}）。');
          await _runAgentContinuation(gen, task);
          continue;
        }
        // 远程主机扫描需用户确认（本机直接执行）。
        if (!isLocalScanHost(request.host)) {
          final ok = await _confirmRemoteScan(request);
          if (!mounted || gen != _requestId) return;
          if (!ok) {
            chat.addUser('【用户跳过扫描】${request.label} 未执行。');
            await _runAgentContinuation(gen, task);
            continue;
          }
        }
        final scanProvider = widget.scanProvider;
        if (scanProvider == null) {
          chat.addUser('【扫描不可用】当前环境未启用端口扫描能力。');
          await _runAgentContinuation(gen, task);
          continue;
        }
        final summary = await scanProvider(request);
        if (!mounted || gen != _requestId) return;
        chat.addUser('【Telnet 扫描结果 · ${request.label}】\n$summary');
        await _runAgentContinuation(gen, task);
        continue;
      }

      final command = extractRunCommand(last.content);
      if (command == null || command.trim().isEmpty) return; // 链路自然结束
      if (sender == null) return; // 无发送通道（只读兜底）

      // ---- 安全分级 ----
      final verdict = classifyAgentCommand(command);
      if (verdict == AgentCommandVerdict.blocked) {
        if (!mounted || gen != _requestId) return;
        chat.addUser('【自动执行被拦截】以下命令命中安全策略，不会自动执行，'
            '请用户手动处理或让 AI 给出替代方案：\n```\n$command\n```');
        await _runAgentContinuation(gen, task);
        continue;
      }
      if (verdict == AgentCommandVerdict.confirm) {
        final ok = await _confirmAgentCommand(command);
        if (!mounted || gen != _requestId) return;
        if (!ok) {
          chat.addUser('【用户跳过执行】以下命令未执行：\n```\n$command\n```');
          await _runAgentContinuation(gen, task);
          continue;
        }
      }

      // ---- 执行 ----
      final error = await sender(command);
      if (!mounted || gen != _requestId) return;
      if (error != null) {
        chat.addUser('【发送失败】命令未执行：$error');
        return;
      }
      final output = await _captureStableDelta();
      if (!mounted || gen != _requestId) return;
      chat.addUser('【命令执行结果 · 第 $step 步】\n$output');

      // ---- 回传输出，让模型继续 ----
      await _runAgentContinuation(gen, task);
    }
    if (mounted && gen == _requestId) {
      _effectiveChat.addUser('【系统提示】已达单次自动执行步数上限'
          '（$agentMaxSteps 步），链路已暂停。回复「继续」可再执行，'
          '或改用命令块上的发送按钮手动执行。');
    }
  }

  /// Agent 续步请求（提示词仅进入请求，不作为可见气泡）。
  ///
  /// 不再附带整屏终端上下文：上一步的命令输出已作为「命令执行结果」
  /// 消息进入历史，重复附带会让每步请求 token 线性膨胀。
  /// 注：这里显式锚定「原始任务」——历史窗口滚动后模型仍知道目标，
  /// 不会因为看不到最初的用户消息而重新问需求（「丢失记忆」修复）。
  Future<void> _runAgentContinuation(int gen, String task) async {
    final anchor = task.trim();
    final brief =
        anchor.length > 500 ? '${anchor.substring(0, 500)}…' : anchor;
    await _runCompletion(
      '（上一步命令已执行完毕，请基于最新终端输出继续分析。\n'
      '原始任务：$brief\n'
      '需要更多输出就再给一个 ```run 代码块，分析完成就输出'
      '「=== 结论 ===」总结并停止给 run 块。）',
      generation: gen,
      includeContext: false,
    );
  }

  /// 命令执行后等待输出稳定再取回传内容。
  ///
  /// 优先用增量通道（只回传该命令新增的输出）；未注入时回退为整屏
  /// 上下文采样（旧行为，token 较大但兼容）。
  Future<String> _captureStableDelta() async {
    final deltaProvider = widget.outputDeltaProvider;
    if (deltaProvider == null) return _captureStableOutput();
    var prev = await deltaProvider();
    for (var i = 0; i < 3; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 800));
      if (!mounted) return prev;
      final next = await deltaProvider();
      if (next == prev) return next;
      prev = next;
    }
    return prev;
  }

  /// 整屏上下文采样（无增量通道时的回退）。
  Future<String> _captureStableOutput() async {
    Future<String> capture() {
      final provider = widget.contextProvider;
      if (provider != null) return provider();
      return Future.value(ai_context.buildContextFromAppState(
          context.read<AppState>()));
    }

    var prev = await capture();
    for (var i = 0; i < 3; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 800));
      if (!mounted) return prev;
      final next = await capture();
      if (next == prev) return next;
      prev = next;
    }
    return prev;
  }

  /// 高危命令确认对话框（Agent 模式）：返回是否执行。
  Future<bool> _confirmAgentCommand(String command) async {
    final scheme = Theme.of(context).colorScheme;
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: scheme.error, size: 22),
            const SizedBox(width: 8),
            const Text('确认执行该命令'),
          ],
        ),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Agent 模式下的以下命令存在变更/破坏风险，需要你确认：',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: scheme.errorContainer.withValues(alpha: 0.5),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: SelectableText(
                  command,
                  style: const TextStyle(
                    fontFamily: 'Consolas',
                    fontFamilyFallback: ['Cascadia Mono', 'Courier New'],
                    fontSize: 12.5,
                    height: 1.5,
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('跳过不执行'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认执行'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  /// 远程主机扫描确认对话框（本机地址直接执行）。
  Future<bool> _confirmRemoteScan(AgentScanRequest request) async {
    final scheme = Theme.of(context).colorScheme;
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.radar, color: scheme.error, size: 22),
            const SizedBox(width: 8),
            const Text('确认扫描远程主机'),
          ],
        ),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Agent 请求对非本机地址发起 TCP 端口扫描，'
                '可能触发目标侧安全告警或策略限制：',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: scheme.errorContainer.withValues(alpha: 0.5),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: SelectableText(
                  request.label,
                  style: const TextStyle(
                    fontFamily: 'Consolas',
                    fontFamilyFallback: ['Cascadia Mono', 'Courier New'],
                    fontSize: 12.5,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '共 ${request.endPort - request.startPort + 1} 个端口。'
                '仅在你确认拥有该设备的测试/运维授权时执行。',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('跳过不扫描'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认扫描'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  void _stop() {
    _requestId++;
    _effectiveChat.stop();
    unawaited(_client?.close());
    _client = null;
  }

  /// 从文件选择器附加图片。
  Future<void> _attachFromFile() async {
    final file = await openFile(acceptedTypeGroups: const [
      XTypeGroup(
          label: '图片', extensions: ['png', 'jpg', 'jpeg', 'webp', 'bmp']),
    ]);
    if (file == null) return;
    final bytes = await file.readAsBytes();
    await _attachImageBytes(bytes, fromClipboard: false);
  }

  /// 输入框按键：Ctrl+V 且剪贴板有位图时附加图片；否则放行（文本粘贴）。
  KeyEventResult _onComposerKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (!HardwareKeyboard.instance.isControlPressed) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey != LogicalKeyboardKey.keyV) {
      return KeyEventResult.ignored;
    }
    // 没有位图时不拦截：走 TextField 自己的文本粘贴。
    if (!ClipboardImage.hasImage()) return KeyEventResult.ignored;
    unawaited(_attachImageBytes(null, fromClipboard: true));
    return KeyEventResult.handled;
  }

  /// 附加一张图片（剪贴板或文件），统一压缩到最长边 1568 的 PNG。
  Future<void> _attachImageBytes(
    Uint8List? fileBytes, {
    required bool fromClipboard,
  }) async {
    if (_attaching) return;
    if (_pendingImages.length >= _maxImagesPerMessage) {
      _snack('最多附加 $_maxImagesPerMessage 张图片');
      return;
    }
    setState(() => _attaching = true);
    Uint8List? png;
    try {
      png = fromClipboard
          ? await ClipboardImage.readImagePng()
          : await ClipboardImage.normalizeImageBytes(fileBytes!);
    } catch (_) {
      png = null;
    }
    if (!mounted) return;
    setState(() {
      _attaching = false;
      if (png != null) {
        _pendingImages.add(AiImage(mime: 'image/png', bytes: png));
      }
    });
    if (png == null) _snack('图片读取失败或格式不支持');
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        width: 380,
        behavior: SnackBarBehavior.floating,
      ));
  }

  /// 导出一条 AI 回复为 TXT（系统对话框选保存位置）。
  Future<void> _exportMessage(AiChatMessage message) async {
    final sessionName = widget.sessionNameProvider?.call();
    final location = await getSaveLocation(
      suggestedName:
          'eshell-ai-${DateTime.now().toLocal().millisecondsSinceEpoch}.txt',
      acceptedTypeGroups: const [
        XTypeGroup(label: '文本文件', extensions: ['txt']),
      ],
    );
    if (location == null || !mounted) return;
    final text = buildAiExportText(
      content: message.content,
      model: _effectiveSettings.model,
      time: DateTime.now(),
      sessionName: sessionName,
    );
    try {
      final writer = widget.exportWriter ??
          (path, text) =>
              File(path).writeAsString(text, flush: true);
      await writer(location.path, text);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text('已导出到 ${location.path}'),
          behavior: SnackBarBehavior.floating,
          width: 420,
        ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text('导出失败：$e'),
          behavior: SnackBarBehavior.floating,
          width: 420,
          backgroundColor: Theme.of(context).colorScheme.errorContainer,
        ));
    }
  }

  @override
  Widget build(BuildContext context) {
    // 子窗口注入模式：provider 树里没有 AppState，全部走注入；
    // 停靠模式从 AppState 取（watch 保持原有重建时机）。
    final docked = widget.chatOverride == null;
    final app = docked ? context.watch<AppState>() : null;
    final chat = widget.chatOverride ?? app!.aiChat;
    final settings = widget.settingsOverride ?? app!.ai;
    // 对话/设置状态变化（流式追加、上下文行数）只重建面板内部。
    return ListenableBuilder(
      listenable: Listenable.merge([chat, settings]),
      builder: (context, _) => Material(
        color: Theme.of(context).colorScheme.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(context, chat, settings),
            const Divider(height: 1),
            _buildContextBar(context, settings),
            const Divider(height: 1),
            Expanded(child: _buildMessages(context, chat)),
            const Divider(height: 1),
            _buildError(context, chat),
            _buildComposer(context, settings, chat),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, AiChat chat, AiSettings settings) {
    final scheme = Theme.of(context).colorScheme;
    // 面板宽度可拖动调整：窄面板时隐藏「命令需确认执行」徽标避免溢出
    // （安全提示在底部输入区的说明行里仍有保留）。
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 2),
      child: LayoutBuilder(builder: (context, constraints) {
        final compact = constraints.maxWidth < 320;
        return Row(
          children: [
            Icon(Icons.auto_awesome, size: 18, color: scheme.primary),
            const SizedBox(width: 8),
            Flexible(
              child: Text('AI 助手',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600)),
            ),
            if (!compact) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  border: Border.all(color: scheme.outlineVariant),
                  borderRadius: BorderRadius.zero,
                ),
                child: Text('命令需确认执行',
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(color: scheme.onSurfaceVariant)),
              ),
            ],
            const SizedBox(width: 2),
            // Agent 自动执行开关（run 块自动执行，高危命令仍弹确认）。
            IconButton(
              tooltip: settings.agentMode
                  ? 'Agent 自动执行：开（点击关闭）'
                  : 'Agent 自动执行：关（点击开启后，run 代码块将自动执行）',
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              icon: Icon(
                Icons.bolt_rounded,
                color: settings.agentMode ? scheme.primary : scheme.onSurfaceVariant,
              ),
              onPressed: () {
                settings.setAgentMode(!settings.agentMode);
                // 子窗口：写盘并通知主窗口重载；停靠模式由 AppState 监听落盘。
                widget.onSettingsSaved?.call();
              },
            ),
            const Spacer(),
            if (widget.onPopOut != null)
              IconButton(
                tooltip: '弹出为独立窗口',
                iconSize: 18,
                icon: const Icon(Icons.open_in_new_rounded),
                onPressed: widget.onPopOut,
              ),
            IconButton(
              tooltip: 'AI 设置（Base URL / 模型 / API Key）',
              iconSize: 18,
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => showAiSettingsDialog(
                context,
                target: widget.settingsOverride,
                onSaved: widget.onSettingsSaved,
              ),
            ),
            IconButton(
              tooltip: '清空对话',
              iconSize: 18,
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: chat.messages.isEmpty ? null : chat.clear,
            ),
            IconButton(
              tooltip: '关闭 AI 面板',
              iconSize: 18,
              icon: const Icon(Icons.close),
              onPressed: widget.onCloseOverride ??
                  () => context
                      .read<AppState>()
                      .settings
                      .setShowAiPanel(false),
            ),
          ],
        );
      }),
    );
  }

  Widget _buildContextBar(BuildContext context, AiSettings settings) {
    final scheme = Theme.of(context).colorScheme;
    final sessionName = widget.sessionNameProvider?.call();
    // 独立子窗口：上下文经 IPC 来自主窗口，无会话名时说明来源。
    final label = switch ((sessionName, widget.contextProvider != null)) {
      (null, true) => '终端上下文来自主窗口 · 每次提问实时获取',
      (final name?, _) => '$name · 最近 ${settings.contextLines} 行',
      (null, false) => '无活动会话（可做通用问答）',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Icon(Icons.link, size: 14, color: scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          if (!settings.configured)
            TextButton(
              onPressed: () => showAiSettingsDialog(
                context,
                target: widget.settingsOverride,
                onSaved: widget.onSettingsSaved,
              ),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 28),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('去配置'),
            ),
        ],
      ),
    );
  }

  Widget _buildMessages(BuildContext context, AiChat chat) {
    final scheme = Theme.of(context).colorScheme;
    if (chat.messages.isEmpty) {
      return _buildEmptyState(context, scheme);
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.all(12),
      itemCount: chat.messages.length,
      itemBuilder: (context, index) {
        final message = chat.messages[index];
        final done = !message.pending && message.content.trim().isNotEmpty;
        final isLastAssistant =
            message.role == 'assistant' && index == chat.messages.length - 1;
        return _MessageView(
          message: message,
          // 只有最后一条 AI 回复可重新生成（避免截断后续对话的歧义）。
          onRegenerate: done && isLastAssistant ? _regenerate : null,
          onExport: done ? () => _exportMessage(message) : null,
          commandSender: widget.commandSender,
        );
      },
    );
  }

  Widget _buildEmptyState(BuildContext context, ColorScheme scheme) {
    final textTheme = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Icon(Icons.auto_awesome_outlined,
            size: 40, color: scheme.onSurfaceVariant),
        const SizedBox(height: 12),
        Text('AI 会读取当前终端最近输出，帮你解释报错、'
            '分析设备状态、生成排查命令。', style: textTheme.bodySmall),
        const SizedBox(height: 6),
        Text('AI 不会自动执行命令：代码块上的「发送」按钮由你确认后'
            '才写入当前终端。', style: textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant)),
        const SizedBox(height: 16),
        for (final quick in aiQuickPrompts)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: OutlinedButton(
              onPressed: () => _send(quick.prompt),
              child: Row(
                children: [
                  Expanded(
                    child: Text(quick.label, textAlign: TextAlign.left),
                  ),
                  const Icon(Icons.arrow_forward, size: 16),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildError(BuildContext context, AiChat chat) {
    final scheme = Theme.of(context).colorScheme;
    final error = chat.error;
    if (error == null) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.5),
        border: Border.all(color: scheme.error.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 16, color: scheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(
              error,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onErrorContainer, height: 1.4),
            ),
          ),
          IconButton(
            tooltip: '关闭错误提示',
            iconSize: 16,
            icon: const Icon(Icons.close),
            onPressed: chat.dismissError,
          ),
        ],
      ),
    );
  }

  Widget _buildComposer(
      BuildContext context, AiSettings settings, AiChat chat) {
    final scheme = Theme.of(context).colorScheme;
    final sending = chat.sending;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_pendingImages.isNotEmpty) ...[
            SizedBox(
              height: 66,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _pendingImages.length,
                separatorBuilder: (_, __) => const SizedBox(width: 6),
                itemBuilder: (context, index) {
                  final image = _pendingImages[index];
                  return Stack(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: scheme.outlineVariant),
                        ),
                        child: Image.memory(
                          image.bytes,
                          width: 88,
                          height: 64,
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                        ),
                      ),
                      Positioned(
                        top: 2,
                        right: 2,
                        child: InkWell(
                          onTap: () =>
                              setState(() => _pendingImages.removeAt(index)),
                          child: Container(
                            padding: const EdgeInsets.all(2),
                            color: scheme.error,
                            child: Icon(Icons.close,
                                size: 12, color: scheme.onError),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            const SizedBox(height: 6),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Focus(
                  // Ctrl+V：剪贴板有图片时附加图片；否则按文本粘贴走原逻辑。
                  onKeyEvent: _onComposerKey,
                  child: CallbackShortcuts(
                    bindings: {
                      const SingleActivator(LogicalKeyboardKey.enter,
                              control: true):
                          () => _send(_input.text),
                    },
                    child: TextField(
                      controller: _input,
                      minLines: 1,
                      maxLines: 5,
                      textInputAction: TextInputAction.newline,
                      decoration: InputDecoration(
                        hintText: _pendingImages.isEmpty
                            ? '问 AI：分析当前终端 / 解释报错 / 生成排查命令…'
                            : '描述图片中的目标（Ctrl+Enter 发送）…',
                        isDense: true,
                        suffixIcon: sending
                            ? IconButton(
                                tooltip: '停止生成',
                                icon: const Icon(Icons.stop_circle_outlined),
                                onPressed: _stop,
                              )
                            : IconButton(
                                tooltip: '发送（Ctrl+Enter）',
                                icon: const Icon(Icons.send),
                                onPressed: () => _send(_input.text),
                              ),
                      ),
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: '附加图片：可 Ctrl+V 粘贴截图，或选择图片文件\n'
                    '需模型支持视觉（如 gpt-4o / qwen-vl / gemini）',
                icon: _attaching
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.image_outlined),
                onPressed:
                    _attaching ? null : () => unawaited(_attachFromFile()),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            settings.agentMode
                ? '发送到 ${settings.baseUrl} · Agent 模式：```run 代码块自动执行（高危仍需确认）'
                : '发送到 ${settings.baseUrl} · 命令经你确认后才会发送到终端',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// 单条消息气泡。
class _MessageView extends StatelessWidget {
  const _MessageView({
    required this.message,
    this.onRegenerate,
    this.onExport,
    this.commandSender,
  });

  final AiChatMessage message;

  /// 非 null 时气泡底部显示对应小按钮（重新生成 / 导出 TXT）。
  final VoidCallback? onRegenerate;
  final VoidCallback? onExport;

  /// 非 null 时命令代码块显示「发送到终端」按钮。
  final Future<String?> Function(String command)? commandSender;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isUser = message.role == 'user';
    if (isUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(bottom: 10, left: 24),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (message.images.isNotEmpty) ...[
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  alignment: WrapAlignment.end,
                  children: [
                    for (final image in message.images)
                      Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: scheme.outlineVariant),
                        ),
                        child: Image.memory(
                          image.bytes,
                          width: 180,
                          height: 120,
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                        ),
                      ),
                  ],
                ),
                if (message.content.isNotEmpty) const SizedBox(height: 8),
              ],
              if (message.content.isNotEmpty)
                SelectableText(
                  message.content,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(
                          color: scheme.onPrimaryContainer, height: 1.45),
                ),
            ],
          ),
        ),
      );
    }

    final hasReasoning = message.reasoning.trim().isNotEmpty;
    final blocks = parseAiMarkdown(message.content);
    return Container(
      margin: const EdgeInsets.only(bottom: 12, right: 12),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (hasReasoning) _ReasoningView(message: message),
          // 思考中占位：还没有思考内容也没有正文时才显示（有思考时
          // 折叠区头部自带指示器，避免双 spinner）。
          if (message.pending &&
              message.content.trim().isEmpty &&
              !hasReasoning)
            Row(
              children: [
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Text('思考中…',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant)),
              ],
            )
          else
            for (final block in blocks)
              _blockView(context, block),
          if (message.pending && message.content.trim().isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 6),
                    Text('生成中…',
                        style: Theme.of(context)
                            .textTheme
                            .labelSmall
                            ?.copyWith(color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
            ),
          if (!message.pending && message.truncated)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.content_cut_rounded,
                      size: 14, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '回复因达到最大输出长度被截断，可发送「继续」让 AI 接着写。',
                      style: Theme.of(context)
                          .textTheme
                          .labelSmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ),
          if (!message.pending && message.interrupted)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '连接中断，以上回复可能不完整。',
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: scheme.error),
              ),
            ),
          if (!message.pending && (onRegenerate != null || onExport != null))
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                children: [
                  if (onRegenerate != null) ...[
                    _MessageAction(
                      icon: Icons.refresh_rounded,
                      label: '重新生成',
                      onPressed: onRegenerate!,
                    ),
                    const SizedBox(width: 4),
                  ],
                  if (onExport != null)
                    _MessageAction(
                      icon: Icons.ios_share_rounded,
                      label: '导出 TXT',
                      onPressed: onExport!,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _blockView(BuildContext context, AiBlock block) {
    return switch (block) {
      AiTextBlock(:final text) => Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: _InlineText(text),
        ),
      AiHeadingBlock(:final level, :final text) => Padding(
          padding: const EdgeInsets.only(top: 2, bottom: 4),
          child: Text(
            text,
            style: _headingStyle(context, level),
          ),
        ),
      AiListBlock(:final items, :final ordered) => Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < items.length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 20,
                        child: Text(
                          ordered ? '${i + 1}.' : '•',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant),
                        ),
                      ),
                      Expanded(child: _InlineText(items[i])),
                    ],
                  ),
                ),
            ],
          ),
        ),
      AiQuoteBlock(:final text) => Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            border: Border(
              left: BorderSide(
                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5),
                width: 3,
              ),
            ),
          ),
          child: _InlineText(
            text,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
      AiRuleBlock() => const Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Divider(height: 1),
        ),
      AiCodeBlock(:final code, :final language) => _CodeBlockView(
          code: code,
          language: language,
          onSend: commandSender == null
              ? null
              : () async => await commandSender!(code),
        ),
      AiTableBlock(:final header, :final rows, :final alignments) =>
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _TableView(
            header: header,
            rows: rows,
            alignments: alignments,
          ),
        ),
    };
  }

  TextStyle? _headingStyle(BuildContext context, int level) {
    final textTheme = Theme.of(context).textTheme;
    final color = Theme.of(context).colorScheme.onSurface;
    return switch (level) {
      <= 2 => textTheme.titleSmall
          ?.copyWith(fontWeight: FontWeight.w600, color: color),
      _ => textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600, color: color),
    };
  }
}

/// 气泡底部的小操作按钮（重新生成 / 导出 TXT）：图标 + 小字，扁平无框。
class _MessageAction extends StatelessWidget {
  const _MessageAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: label,
      child: InkWell(
        borderRadius: BorderRadius.zero,
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 13, color: scheme.onSurfaceVariant),
              const SizedBox(width: 4),
              Text(label,
                  style: Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
  }
}

/// 行内 Markdown 渲染：**粗体** / *斜体* / `代码` / [链接](url)。
class _InlineText extends StatelessWidget {
  const _InlineText(this.text, {this.style});

  final String text;
  final TextStyle? style;

  TextSpan _span(AiInline inline, TextStyle base, ColorScheme scheme) {
    return switch (inline.kind) {
      AiInlineKind.text => TextSpan(text: inline.text),
      AiInlineKind.bold => TextSpan(
          text: inline.text, style: base.copyWith(fontWeight: FontWeight.w600)),
      AiInlineKind.italic => TextSpan(
          text: inline.text, style: base.copyWith(fontStyle: FontStyle.italic)),
      AiInlineKind.boldItalic => TextSpan(
          text: inline.text,
          style: base.copyWith(
              fontWeight: FontWeight.w600, fontStyle: FontStyle.italic)),
      AiInlineKind.code => TextSpan(
          text: inline.text,
          style: base.copyWith(
            fontFamily: 'Consolas',
            fontFamilyFallback: const ['Cascadia Mono', 'Courier New'],
            background: Paint()..color = scheme.surfaceContainerHigh,
          ),
        ),
      AiInlineKind.link => TextSpan(
          text: inline.text,
          style: base.copyWith(
            color: scheme.primary,
            decoration: TextDecoration.underline,
            decorationColor: scheme.primary.withValues(alpha: 0.5),
          ),
        ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = (style ?? Theme.of(context).textTheme.bodySmall ?? const TextStyle())
        .copyWith(height: 1.55);
    final span = TextSpan(
      style: base,
      children: [for (final s in parseAiInline(text)) _span(s, base, scheme)],
    );
    return SelectableText.rich(span);
  }
}

/// 思考过程折叠区：默认折叠为 4 行高的滚动视口（底部渐隐提示还有
/// 内容，流式期间自动滚到最新思考），点击头部展开全量显示；
/// 高度切换用 AnimatedSize 动画，chevron 同步旋转。
class _ReasoningView extends StatefulWidget {
  const _ReasoningView({required this.message});

  final AiChatMessage message;

  @override
  State<_ReasoningView> createState() => _ReasoningViewState();
}

class _ReasoningViewState extends State<_ReasoningView> {
  bool _expanded = false;

  /// 折叠视口高度：4 行 × (12px × 1.5 行高) = 72。
  static const double _collapsedHeight = 72;

  final ScrollController _collapsedScroll = ScrollController();

  @override
  void dispose() {
    _collapsedScroll.dispose();
    super.dispose();
  }

  void _toggle() => setState(() => _expanded = !_expanded);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final thinking =
        widget.message.pending && widget.message.content.trim().isEmpty;
    final expanded = _expanded;
    if (!expanded && widget.message.pending) {
      // 折叠视口跟随流式思考滚动到底部。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_collapsedScroll.hasClients) return;
        _collapsedScroll.jumpTo(_collapsedScroll.position.maxScrollExtent);
      });
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: _toggle,
            borderRadius: BorderRadius.zero,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.psychology_outlined,
                      size: 14, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 4),
                  Text('思考过程',
                      style: textTheme.labelSmall
                          ?.copyWith(color: scheme.onSurfaceVariant)),
                  if (thinking) ...[
                    const SizedBox(width: 8),
                    const SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ],
                  const SizedBox(width: 4),
                  AnimatedRotation(
                    turns: expanded ? -0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOutCubic,
                    child: Icon(
                      Icons.expand_more_rounded,
                      size: 16,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topLeft,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: expanded ? double.infinity : _collapsedHeight,
              ),
              child: expanded
                  ? _buildReasoningText(textTheme, scheme)
                  : ShaderMask(
                      // 底部渐隐：提示折叠视口下方还有内容。
                      shaderCallback: (bounds) => const LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Color(0xFFFFFFFF),
                          Color(0xFFFFFFFF),
                          Color(0x00FFFFFF),
                        ],
                        stops: [0, 0.72, 1],
                      ).createShader(bounds),
                      blendMode: BlendMode.dstIn,
                      child: SingleChildScrollView(
                        controller: _collapsedScroll,
                        physics: const ClampingScrollPhysics(),
                        child: _buildReasoningText(textTheme, scheme),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReasoningText(TextTheme textTheme, ColorScheme scheme) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(left: 18, top: 4, bottom: 2),
        child: SelectableText(
          widget.message.reasoning.trim(),
          style: textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
      ),
    );
  }
}

/// AI 回复里的 GFM 表格：全边框 + 表头底色，单元格复用行内标记渲染。
/// 列宽按内容自适应（IntrinsicColumnWidth）；总宽超出面板时横向滚动保底，
/// 未超出时撑满可用宽度（对齐分隔线视觉）。
class _TableView extends StatelessWidget {
  const _TableView({
    required this.header,
    required this.rows,
    required this.alignments,
  });

  final List<String> header;
  final List<List<String>> rows;
  final List<AiTableAlignment> alignments;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bodySmall = Theme.of(context).textTheme.bodySmall;
    final headerStyle =
        bodySmall?.copyWith(fontWeight: FontWeight.w600, color: scheme.onSurface);
    final cellStyle = bodySmall?.copyWith(color: scheme.onSurface);

    TableRow buildRow(List<String> cells, {required bool isHeader}) {
      return TableRow(
        decoration: BoxDecoration(
          color: isHeader ? scheme.surfaceContainerHigh : null,
        ),
        children: [
          for (var i = 0; i < cells.length; i++)
            Align(
              alignment: switch (i < alignments.length
                  ? alignments[i]
                  : AiTableAlignment.left) {
                AiTableAlignment.center => Alignment.center,
                AiTableAlignment.right => Alignment.centerRight,
                AiTableAlignment.left => Alignment.centerLeft,
              },
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                child: _InlineText(
                  cells[i],
                  style: isHeader ? headerStyle : cellStyle,
                ),
              ),
            ),
        ],
      );
    }

    return LayoutBuilder(builder: (context, constraints) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: constraints.maxWidth),
          child: Table(
            columnWidths: {
              for (var i = 0; i < header.length; i++)
                i: const IntrinsicColumnWidth(),
            },
            defaultColumnWidth: const IntrinsicColumnWidth(),
            border: TableBorder.all(color: scheme.outlineVariant, width: 0.5),
            children: [
              buildRow(header, isHeader: true),
              for (final row in rows) buildRow(row, isHeader: false),
            ],
          ),
        ),
      );
    });
  }
}

/// 代码块：等宽字体 + 复制按钮 + 「发送到终端」按钮（发送前需在
/// 命令块上显式点击确认，AI 绝不自动执行）。
/// shell 类语言标终端图标，未标注语言的裸 ``` 按「命令」呈现。
class _CodeBlockView extends StatefulWidget {
  const _CodeBlockView({
    required this.code,
    required this.language,
    this.onSend,
  });

  final String code;
  final String language;

  /// 非 null 时显示「发送到终端」按钮；返回 null=成功，非 null=错误文案。
  final Future<String?> Function()? onSend;

  @override
  State<_CodeBlockView> createState() => _CodeBlockViewState();
}

class _CodeBlockViewState extends State<_CodeBlockView> {
  static const _shellLanguages = {
    'bash', 'sh', 'shell', 'zsh', 'console', 'powershell', 'pwsh',
    'ps1', 'cmd', 'batch', 'bat',
  };

  bool _sending = false;
  bool _sent = false;

  Future<void> _send() async {
    final onSend = widget.onSend;
    if (onSend == null || _sending) return;
    setState(() => _sending = true);
    String? error;
    try {
      error = await onSend();
    } catch (e) {
      error = e.toString();
    }
    if (!mounted) return;
    setState(() {
      _sending = false;
      if (error == null) _sent = true;
    });
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(error ?? '命令已发送到当前终端'),
        width: 320,
        behavior: SnackBarBehavior.floating,
      ));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lang = widget.language.toLowerCase();
    final isRun = lang == 'run';
    final isScan = lang == 'scan';
    final isShell = _shellLanguages.contains(lang) || isRun;
    final code = widget.code;
    final language = widget.language;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        border: Border.all(
          color: isRun || isScan
              ? scheme.primary.withValues(alpha: 0.55)
              : scheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(8, 2, 2, 2),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: scheme.outlineVariant),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  isScan
                      ? Icons.radar
                      : isRun
                          ? Icons.bolt_rounded
                          : isShell
                              ? Icons.terminal_rounded
                              : Icons.code_rounded,
                  size: 13,
                  color: isRun || isScan
                      ? scheme.primary
                      : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    language.isEmpty
                        ? (isShell ? '命令' : '代码')
                        : isScan
                            ? 'Telnet 扫描（自动执行）'
                            : isRun
                                ? 'Agent 命令（自动执行）'
                                : language,
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
                // scan 块由 Agent 循环执行，不提供发送到终端按钮。
                if (widget.onSend != null && !isScan)
                  IconButton(
                    tooltip: _sent
                        ? '再次发送到当前终端并执行'
                        : '发送到当前终端并执行',
                    iconSize: 16,
                    visualDensity: VisualDensity.compact,
                    icon: _sending
                        ? const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : Icon(
                            _sent
                                ? Icons.check_rounded
                                : Icons.play_arrow_rounded,
                            color: _sent ? scheme.primary : null,
                          ),
                    onPressed: _send,
                  ),
                IconButton(
                  tooltip: '复制代码',
                  iconSize: 16,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.copy_rounded),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: code));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context)
                        ..hideCurrentSnackBar()
                        ..showSnackBar(const SnackBar(
                          content: Text('代码已复制到剪贴板'),
                          behavior: SnackBarBehavior.floating,
                          width: 260,
                        ));
                    }
                  },
                ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(8),
            child: SelectableText(
              code,
              style: const TextStyle(
                fontFamily: 'Consolas',
                fontFamilyFallback: ['Cascadia Mono', 'Courier New'],
                fontSize: 12.5,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
