import 'dart:convert';
import 'dart:io';

import 'package:eshell/services/ai_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('extractSseChunk / isSseDone', () {
    test('解析 content 增量', () {
      final chunk = extractSseChunk(
          'data: {"choices":[{"delta":{"content":"你好"}}]}');
      expect(chunk, isNotNull);
      expect(chunk!.content, '你好');
      expect(chunk.reasoning, isEmpty);

      final chunk2 = extractSseChunk(
          'data:{"choices":[{"delta":{"content":"code"}}],"id":"x"}');
      expect(chunk2!.content, 'code');
    });

    test('解析思考过程增量（reasoning_content / reasoning 兼容）', () {
      final deepseek = extractSseChunk(
          'data: {"choices":[{"delta":{"reasoning_content":"让我想想"}}]}');
      expect(deepseek!.reasoning, '让我想想');
      expect(deepseek.content, isEmpty);

      final openrouter = extractSseChunk(
          'data: {"choices":[{"delta":{"reasoning":"think..."}}]}');
      expect(openrouter!.reasoning, 'think...');
    });

    test('解析 finish_reason（空 delta + 结束原因也产出 chunk）', () {
      final length = extractSseChunk(
          'data: {"choices":[{"delta":{},"finish_reason":"length"}]}');
      expect(length!.finishReason, 'length');
      expect(length.isEmpty, isTrue);

      final stop = extractSseChunk(
          'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}');
      expect(stop!.finishReason, 'stop');

      // 空 delta 且无 finish_reason：无信息，返回 null。
      expect(extractSseChunk('data: {"choices":[{"delta":{}}]}'), isNull);
    });

    test('DONE / 空内容 / 非 data 行 / 坏 JSON 返回 null', () {
      expect(extractSseChunk('data: [DONE]'), isNull);
      expect(extractSseChunk('data: {"choices":[{"delta":{}}]}'), isNull);
      expect(extractSseChunk('data: {"choices":[]}'), isNull);
      expect(extractSseChunk(': keep-alive'), isNull);
      expect(extractSseChunk('data: not-json'), isNull);
    });

    test('isSseDone', () {
      expect(isSseDone('data: [DONE]'), isTrue);
      expect(isSseDone('data: [DONE] '), isTrue);
      expect(isSseDone('data: {"choices":[]}'), isFalse);
      expect(isSseDone('event: done'), isFalse);
    });
  });

  group('AiClient.endpoint', () {
    test('自动补全 /chat/completions，容忍尾部斜杠与完整端点', () {
      expect(
        AiClient(baseUrl: 'https://api.deepseek.com/v1', apiKey: 'k', model: 'm')
            .endpoint
            .toString(),
        'https://api.deepseek.com/v1/chat/completions',
      );
      expect(
        AiClient(baseUrl: 'https://api.deepseek.com/v1/', apiKey: 'k', model: 'm')
            .endpoint
            .toString(),
        'https://api.deepseek.com/v1/chat/completions',
      );
      expect(
        AiClient(
                baseUrl: 'https://proxy.local/v1/chat/completions',
                apiKey: 'k',
                model: 'm')
            .endpoint
            .toString(),
        'https://proxy.local/v1/chat/completions',
      );
    });
  });

  group('AiClient 流式请求（本地假 OpenAI 兼容服务）', () {
    test('服务端提前 EOF 时报告响应中断', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        await request.drain<void>();
        request.response.headers.contentType =
            ContentType('text', 'event-stream', charset: 'utf-8');
        request.response.write('data: {"choices":[{"delta":{"content":"partial"}}]}\n\n');
        await request.response.close();
      });
      final client = AiClient(
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        apiKey: 'test',
        model: 'mock',
      );
      await expectLater(
        client.streamChat(const [AiMessage(role: 'user', content: 'x')]).toList(),
        throwsA(isA<AiIncompleteResponseException>()),
      );
      await client.close();
      await server.close(force: true);
    });
    test('解析 SSE 增量、校验请求头/请求体', () async {
      late String requestBody;
      late String auth;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        requestBody = await utf8.decoder.bind(request).join();
        auth = request.headers.value(HttpHeaders.authorizationHeader) ?? '';
        request.response.statusCode = 200;
        request.response.headers.contentType =
            ContentType('text', 'event-stream', charset: 'utf-8');
        request.response.write('data: {"choices":[{"delta":{"content":"你好"}}]}\n\n');
        await request.response.flush();
        request.response.write('data: {"choices":[{"delta":{"content":"，世界"}}]}\n\n');
        await request.response.flush();
        request.response.write('data: [DONE]\n\n');
        await request.response.close();
      });

      final client = AiClient(
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        apiKey: 'demo-key',
        model: 'mock-model',
      );
      final chunks = await client
          .streamChat(const [AiMessage(role: 'user', content: 'ping')])
          .toList();
      expect(chunks.map((c) => c.content), ['你好', '，世界']);

      final body = jsonDecode(requestBody) as Map<String, dynamic>;
      expect(body['model'], 'mock-model');
      expect(body['stream'], isTrue);
      // 默认 off：不发送 reasoning_effort。
      expect(body.containsKey('reasoning_effort'), isFalse);
      // 输出上限 4096：避免长回答在 2048 被硬截断。
      expect(body['max_tokens'], 4096);
      expect((body['messages'] as List).single,
          {'role': 'user', 'content': 'ping'});
      expect(auth, 'Bearer demo-key');

      await client.close();
      await server.close(force: true);
    });

    test('思考强度非 off 时随请求发送 reasoning_effort', () async {
      late String requestBody;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        requestBody = await utf8.decoder.bind(request).join();
        request.response.statusCode = 200;
        request.response.headers.contentType =
            ContentType('text', 'event-stream', charset: 'utf-8');
        request.response.write('data: {"choices":[{"delta":{"content":"ok"}}]}\n\n');
        request.response.write('data: [DONE]\n\n');
        await request.response.close();
      });

      final client = AiClient(
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        apiKey: 'demo-key',
        model: 'mock-model',
        reasoningEffort: 'high',
      );
      await client
          .streamChat(const [AiMessage(role: 'user', content: 'ping')])
          .drain<void>();
      final body = jsonDecode(requestBody) as Map<String, dynamic>;
      expect(body['reasoning_effort'], 'high');

      await client.close();
      await server.close(force: true);
    });

    test('流式返回思考过程与正文（本地假服务端）', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.statusCode = 200;
        request.response.headers.contentType =
            ContentType('text', 'event-stream', charset: 'utf-8');
        request.response.write(
            'data: {"choices":[{"delta":{"reasoning_content":"先看路由表"}}]}\n\n');
        await request.response.flush();
        request.response.write(
            'data: {"choices":[{"delta":{"content":"结论：缺默认路由"}}]}\n\n');
        await request.response.flush();
        request.response.write('data: [DONE]\n\n');
        await request.response.close();
      });

      final client = AiClient(
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        apiKey: 'demo-key',
        model: 'mock-model',
      );
      final chunks = await client
          .streamChat(const [AiMessage(role: 'user', content: 'ping')])
          .toList();
      expect(chunks, hasLength(2));
      expect(chunks[0].reasoning, '先看路由表');
      expect(chunks[0].content, isEmpty);
      expect(chunks[1].content, '结论：缺默认路由');

      await client.close();
      await server.close(force: true);
    });

    test('401 映射为可读中文错误', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) {
        request.response.statusCode = 401;
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"error":{"message":"invalid api key"}}');
        request.response.close();
      });
      final client = AiClient(
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        apiKey: 'bad',
        model: 'm',
      );
      await expectLater(
        client.streamChat(const [AiMessage(role: 'user', content: 'x')]).toList(),
        throwsA(isA<AiException>()
            .having((e) => e.statusCode, 'statusCode', 401)
            .having((e) => e.message, 'message', contains('API Key 无效'))
            .having((e) => e.message, 'detail', contains('invalid api key'))),
      );
      await client.close();
      await server.close(force: true);
    });
  });
}
