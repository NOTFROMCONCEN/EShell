import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 一条对话消息（OpenAI chat 格式）。
class AiMessage {
  const AiMessage({required this.role, required this.content});

  final String role; // system / user / assistant
  final String content;

  Map<String, dynamic> toJson() => {'role': role, 'content': content};
}

/// AI 请求失败（错误信息可直接展示给用户）。
class AiException implements Exception {
  AiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class AiIncompleteResponseException extends AiException {
  AiIncompleteResponseException() : super('AI 响应意外中断，已保留收到的内容。');
}

/// 可注入的流式客户端接口（面板/测试共用）。
abstract class AiStreamingClient {
  /// 逐段产出 assistant 回复增量（正文与思考过程分离）；调用方取消时关闭。
  Stream<AiStreamChunk> streamChat(List<AiMessage> messages);

  /// 取消进行中的请求（幂等）。
  Future<void> close();
}

/// 一段流式增量：正文（content）或思考过程（reasoning）。
///
/// 两者互斥出现（OpenAI 兼容服务一条 delta 只带其一），
/// [finishReason] 出现在最后一个 delta 上（stop=正常结束 / length=被
/// 最大 token 数截断等）；三者都空表示该行无可展示内容。
class AiStreamChunk {
  const AiStreamChunk({
    this.content = '',
    this.reasoning = '',
    this.finishReason,
  });

  final String content;
  final String reasoning;

  /// 本条 delta 的结束原因（服务端通过 choices[0].finish_reason 下发）。
  final String? finishReason;

  bool get isEmpty => content.isEmpty && reasoning.isEmpty;
}

/// 思考强度档位（OpenAI `reasoning_effort` 约定值）。
const List<String> kAiReasoningEfforts = ['off', 'low', 'medium', 'high'];

/// 解析一行 SSE：返回增量（正文或思考过程）。
///
/// 兼容 DeepSeek/Qwen/vLLM 的 `reasoning_content` 与
/// OpenRouter 的 `reasoning` 字段。
/// 非 `data:` 行、`[DONE]`、心跳/空内容、解析失败均返回 null。
AiStreamChunk? extractSseChunk(String line) {
  final trimmed = line.trim();
  if (!trimmed.startsWith('data:')) return null;
  final payload = trimmed.substring(5).trim();
  if (payload.isEmpty || payload == '[DONE]') return null;
  try {
    final json = jsonDecode(payload);
    if (json is! Map<String, dynamic>) return null;
    final choices = json['choices'];
    if (choices is! List || choices.isEmpty) return null;
    final first = choices.first;
    if (first is! Map<String, dynamic>) return null;
    final delta = first['delta'];
    if (delta is! Map<String, dynamic>) return null;
    final content = delta['content'];
    final reasoning = delta['reasoning_content'] ?? delta['reasoning'];
    final finishReason = first['finish_reason'];
    final chunk = AiStreamChunk(
      content: content is String ? content : '',
      reasoning: reasoning is String ? reasoning : '',
      finishReason: finishReason is String && finishReason.isNotEmpty
          ? finishReason
          : null,
    );
    return chunk.isEmpty && chunk.finishReason == null ? null : chunk;
  } catch (_) {
    return null;
  }
}

/// 是否为流结束标记 `data: [DONE]`。
bool isSseDone(String line) {
  final trimmed = line.trim();
  return trimmed.startsWith('data:') && trimmed.substring(5).trim() == '[DONE]';
}

/// OpenAI 兼容的流式聊天客户端（DeepSeek / OpenAI / 通义 / Kimi 等）。
///
/// 只发 `/chat/completions` 请求并解析 SSE；不做任何本地命令执行。
class AiClient implements AiStreamingClient {
  AiClient({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    this.reasoningEffort = 'off',
    this.connectTimeout = const Duration(seconds: 20),
    this.idleTimeout = const Duration(seconds: 120),
    this.temperature = 0.3,
    this.maxTokens = 4096,
  });

  final String baseUrl;
  final String apiKey;
  final String model;

  /// 思考强度：'off' 表示不发送该参数（由服务端自行决定）。
  final String reasoningEffort;
  final Duration connectTimeout;
  final Duration idleTimeout;
  final double temperature;
  final int maxTokens;

  HttpClient? _http;
  bool _cancelled = false;

  /// 实际请求端点：允许用户直接填到 `/chat/completions`，否则自动补全。
  Uri get endpoint {
    var base = baseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    if (base.isEmpty) base = 'https://api.deepseek.com/v1';
    if (base.endsWith('/chat/completions')) return Uri.parse(base);
    return Uri.parse('$base/chat/completions');
  }

  @override
  Future<void> close() async {
    _cancelled = true;
    _http?.close(force: true);
    _http = null;
  }

  @override
  Stream<AiStreamChunk> streamChat(List<AiMessage> messages) async* {
    _cancelled = false;
    final http = HttpClient()
      ..connectionTimeout = connectTimeout
      ..userAgent = 'EShell-AI/0.1';
    _http = http;

    try {
      HttpClientRequest request;
      try {
        request = await http.postUrl(endpoint).timeout(connectTimeout);
      } catch (e) {
        throw AiException('无法连接 AI 服务（$endpoint）：$e\n请检查网络、Base URL 与代理设置。');
      }

      request.headers
        ..contentType = ContentType.json
        ..set(HttpHeaders.authorizationHeader, 'Bearer $apiKey')
        ..set(HttpHeaders.acceptHeader, 'text/event-stream');
      request.add(utf8.encode(jsonEncode({
        'model': model,
        'messages': [
          for (final m in messages) m.toJson(),
        ],
        'stream': true,
        'temperature': temperature,
        'max_tokens': maxTokens,
        // 思考强度（OpenAI reasoning_effort 约定）：off 时不发送，
        // 避免不支持该参数的服务端直接报 400。
        if (reasoningEffort.trim().isNotEmpty &&
            reasoningEffort.trim() != 'off')
          'reasoning_effort': reasoningEffort.trim(),
      })));

      HttpClientResponse response;
      try {
        response = await request.close().timeout(connectTimeout);
      } catch (e) {
        if (_cancelled) return;
        throw AiException('请求 AI 服务失败：$e');
      }

      if (response.statusCode != HttpStatus.ok) {
        String body;
        try {
          body = await response
              .transform(utf8.decoder)
              .join()
              .timeout(const Duration(seconds: 10));
        } catch (_) {
          body = '';
        }
        throw AiException(
          _friendlyHttpError(response.statusCode, body),
          statusCode: response.statusCode,
        );
      }

      final lines = response
          .timeout(idleTimeout)
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      var completed = false;
      await for (final line in lines) {
        if (_cancelled) return;
        if (isSseDone(line)) return;
        final chunk = extractSseChunk(line);
        if (chunk != null) {
          if (chunk.finishReason != null) completed = true;
          yield chunk;
        }
      }
      if (!completed && !_cancelled) throw AiIncompleteResponseException();
    } finally {
      http.close(force: true);
      if (identical(_http, http)) _http = null;
    }
  }

  static String _friendlyHttpError(int statusCode, String body) {
    final detail = _extractErrorDetail(body);
    final suffix = detail == null ? '' : '\n服务端信息：$detail';
    return switch (statusCode) {
      400 => '请求参数有误（400），请检查模型名与上下文长度。$suffix',
      401 => 'API Key 无效或未授权（401），请到 AI 设置中检查 Key。$suffix',
      402 => '账户余额不足（402），请充值或更换 Key。$suffix',
      403 => '无访问权限（403），请检查 Key 的权限或地区限制。$suffix',
      404 => '接口地址或模型不存在（404），请检查 Base URL 与模型名。$suffix',
      429 => '请求过于频繁或额度用尽（429），请稍后再试。$suffix',
      >= 500 => 'AI 服务端错误（$statusCode），请稍后重试。$suffix',
      _ => 'AI 服务返回 HTTP $statusCode。$suffix',
    };
  }

  /// 从常见错误 JSON（`{"error":{"message":...}}`）中提取可读信息。
  static String? _extractErrorDetail(String body) {
    final text = body.trim();
    if (text.isEmpty) return null;
    try {
      final json = jsonDecode(text);
      if (json is Map<String, dynamic>) {
        final error = json['error'];
        if (error is Map<String, dynamic>) {
          final message = error['message'];
          if (message is String && message.isNotEmpty) {
            return message.length > 300 ? message.substring(0, 300) : message;
          }
        }
        final message = json['message'];
        if (message is String && message.isNotEmpty) {
          return message.length > 300 ? message.substring(0, 300) : message;
        }
      }
    } catch (_) {
      // 非 JSON：截断原文返回。
    }
    return text.length > 300 ? text.substring(0, 300) : text;
  }
}
