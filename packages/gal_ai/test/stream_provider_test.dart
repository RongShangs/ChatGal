import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gal_ai/gal_ai.dart';
import 'package:test/test.dart';

String delta(String text) => 'data: ${jsonEncode({
          'choices': [
            {
              'delta': {'content': text}
            }
          ]
        })}\n\n';

void main() {
  Future<OpenAiCompatibleProvider> serve(
    Future<void> Function(HttpResponse response) send, {
    HttpClient? client,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      await request.drain<void>();
      request.response.bufferOutput = false;
      request.response.headers.contentType =
          ContentType('text', 'event-stream', charset: 'utf-8');
      await send(request.response);
    });
    return OpenAiCompatibleProvider(
      ProviderConfig(
        endpoint: 'http://127.0.0.1:${server.port}/v1',
        model: 'test',
        timeout: const Duration(seconds: 2),
      ),
      client: client,
    );
  }

  test('DONE completes the request without waiting for HTTP EOF', () async {
    final provider = await serve((r) async {
      r.write('${delta('你好')}data: [DONE]\n\n');
      await r.flush();
      // Deliberately leave the HTTP response open after the protocol terminator.
    });
    final visible = StringBuffer();
    final result = await provider.generate(
      const GenerateRequest(messages: [], stream: true),
      onDelta: visible.write,
    );
    expect(result.ok, isTrue,
        reason: '${result.status}: ${result.error}; $visible');
    expect(visible.toString(), '你好');
    expect(result.response!.segments.single.text, '你好');
  });

  test('think tags split at every character never leak or swallow dialogue',
      () async {
    const wire = '前文<think>秘密推理</think>你好<think>另一段</think>尾声<';
    final provider = await serve((r) async {
      for (final char in wire.split('')) {
        r.write(delta(char));
      }
      r.write('data: [DONE]\n\n');
      await r.close();
    });
    final visible = StringBuffer();
    final result = await provider.generate(
      const GenerateRequest(messages: [], stream: true),
      onDelta: (text) {
        visible.write(text);
        expect(visible.toString(), isNot(contains('秘密')));
        expect(visible.toString(), isNot(contains('<think>')));
      },
    );
    expect(result.ok, isTrue);
    expect(visible.toString(), '前文你好尾声<');
    expect(result.response!.segments.single.text, visible.toString());
  });

  test('filter also applies without onDelta; unfinished thinking is discarded',
      () async {
    final provider = await serve((r) async {
      r.write(delta('正文<think>不应进入记忆'));
      r.write('data: [DONE]\n\n');
      await r.close();
    });
    final result = await provider.generate(
      const GenerateRequest(messages: [], stream: true),
    );
    expect(result.ok, isTrue);
    expect(result.response!.segments.single.text, '正文');
  });

  test('cancelling an unfinished stream still cancels the request', () async {
    final sent = Completer<void>();
    final provider = await serve((r) async {
      r.write(delta('开始'));
      await r.flush();
      sent.complete();
    });
    final cancel = CancelToken();
    final future = provider.generate(
      const GenerateRequest(messages: [], stream: true),
      cancel: cancel,
    );
    await sent.future;
    cancel.cancel();
    expect((await future).status, ProviderStatus.cancelled);
  });

  test('服务器忽略 stream:true（回普通 JSON）时正文不能丢', () async {
    final provider = await serve((r) async {
      r.write(jsonEncode({
        'choices': [
          {
            'message': {'content': '正文<think>心里那句不能说</think>收尾'},
            'finish_reason': 'stop',
          }
        ]
      }));
      await r.close();
    });
    final result = await provider.generate(
      const GenerateRequest(messages: [], stream: true),
    );
    expect(result.ok, isTrue, reason: '${result.status}: ${result.error}');
    expect(result.response!.segments.single.text, '正文收尾');
    // rawText 同样是剥过的：它会被写进日志/记忆，不能带思考内容
    expect(result.rawText, '正文收尾');
  });

  test('HTTP 401 把服务器说的 error message 带出来', () async {
    final provider = await serve((r) async {
      r.statusCode = 401;
      r.write(jsonEncode({
        'error': {'message': '无效的 API Key', 'type': 'invalid_request_error'}
      }));
      await r.close();
    });
    final result = await provider.generate(
      const GenerateRequest(messages: [], stream: true),
    );
    expect(result.status, ProviderStatus.invalid);
    expect(result.error, 'HTTP 401');
    // 只有 `HTTP 401` 没法排查：服务器说的原因必须在 rawText 里
    expect(result.rawText, contains('无效的 API Key'));
  });

  test('关掉流式设置也剥掉 <think>：思考内容不上屏、不进 L1', () async {
    final provider = await serve((r) async {
      r.write(jsonEncode({
        'choices': [
          {
            'message': {'content': '（抬头）在的。<think>他刚才那句话是什么意思</think>'},
            'finish_reason': 'stop',
          }
        ]
      }));
      await r.close();
    });
    final result = await provider.generate(
      const GenerateRequest(messages: [], stream: false),
    );
    expect(result.ok, isTrue, reason: '${result.status}: ${result.error}');
    expect(result.response!.segments.single.text, '（抬头）在的。');
    expect('${result.rawText}', isNot(contains('他刚才那句话')));
    expect('${result.rawText}', isNot(contains('<think>')));
  });

  test('流式与非流式对同一段文本给出同样的可播放正文', () async {
    // 逐字符 delta 会把标签拆开；末尾孤立的 '<' 既不是标签也不算思考内容
    const wire = '前文<think>秘密推理</think>你好<think>另一段</think>尾声<';
    final plain = await serve((r) async {
      r.write(jsonEncode({
        'choices': [
          {
            'message': {'content': wire},
            'finish_reason': 'stop',
          }
        ]
      }));
      await r.close();
    });
    final oneShot =
        await plain.generate(const GenerateRequest(messages: [], stream: false));

    final streamed = await serve((r) async {
      for (final char in wire.split('')) {
        r.write(delta(char));
      }
      r.write('data: [DONE]\n\n');
      await r.close();
    });
    final byDelta =
        await streamed.generate(const GenerateRequest(messages: [], stream: true));

    expect(oneShot.ok, isTrue);
    expect(byDelta.ok, isTrue);
    expect(oneShot.response!.segments.single.text, '前文你好尾声<');
    expect(byDelta.response!.segments.single.text,
        oneShot.response!.segments.single.text);
  });

  test('末条 data: 不带换行也不丢 delta', () async {
    final provider = await serve((r) async {
      r.write(delta('前半'));
      // 最后一条 delta 没有换行就结束连接：以前这段缓冲被直接丢掉
      r.write('data: ${jsonEncode({
            'choices': [
              {
                'delta': {'content': '后半'}
              }
            ]
          })}');
      await r.close();
    });
    final result = await provider.generate(
      const GenerateRequest(messages: [], stream: true),
    );
    expect(result.ok, isTrue, reason: '${result.status}: ${result.error}');
    expect(result.response!.segments.single.text, '前半后半');
  });

  test('不带换行的 data: [DONE] 立刻收手，不等连接关闭', () async {
    final provider = await serve((r) async {
      r.write(delta('你好'));
      r.write('data: [DONE]');
      await r.flush();
      // 刻意不关连接：识别不出 [DONE] 就会一直等到 2s 总超时
    });
    final result = await provider.generate(
      const GenerateRequest(messages: [], stream: true),
    );
    expect(result.ok, isTrue, reason: '${result.status}: ${result.error}');
    expect(result.response!.segments.single.text, '你好');
  });

  test('取消不强关「注入的」HttpClient：那是调用方自己的资源', () async {
    final spy = _SpyClient();
    addTearDown(() => spy.inner.close(force: true));
    final sent = Completer<void>();
    final release = Completer<void>();
    final provider = await serve(
      (r) async {
        r.write(delta('开始'));
        await r.flush();
        sent.complete();
        // 注入的 client 不会被强关，所以只能等这边放行，读流才会结束
        await release.future;
        await r.close();
      },
      client: spy,
    );
    final cancel = CancelToken();
    final future = provider.generate(
      const GenerateRequest(messages: [], stream: true),
      cancel: cancel,
    );
    await sent.future;
    cancel.cancel();
    await Future<void>.delayed(Duration.zero);
    expect(spy.forceClosed, isFalse, reason: '注入的 client 不归本类关');
    release.complete();
    expect((await future).status, ProviderStatus.cancelled);
    expect(spy.forceClosed, isFalse);
  });

  test('流式正文为空时沿用服务端给的 finish_reason（不写死 stop）', () async {
    String frame(Map<String, Object?> choice) => 'data: ${jsonEncode({
          'choices': [choice]
        })}\n\n';
    final provider = await serve((r) async {
      // 内容全在 reasoning_content 里：delta 里没有正文
      r.write(frame({
        'delta': {'reasoning_content': '一直在想'},
        'finish_reason': null,
      }));
      r.write(frame({
        'delta': <String, Object?>{},
        'finish_reason': 'length',
      }));
      r.write('data: [DONE]\n\n');
      await r.close();
    });
    final result = await provider.generate(
      const GenerateRequest(messages: [], stream: true),
    );
    expect(result.ok, isFalse);
    expect(result.error, contains('finish_reason=length'));
    expect(result.error, isNot(contains('finish_reason=stop')));
  });

  test('坏行照旧被跳过，但会记数并体现在错误里', () async {
    final provider = await serve((r) async {
      r.write('data: {这不是 JSON}\n\n');
      // 整段都是未闭合的思考内容 → 可播放正文为空
      r.write(delta('<think>全是内心戏'));
      r.write('data: [DONE]\n\n');
      await r.close();
    });
    final result = await provider.generate(
      const GenerateRequest(messages: [], stream: true),
    );
    expect(result.ok, isFalse);
    expect(result.status, ProviderStatus.formatError);
    expect(result.error, contains('empty content'));
    expect(result.error, contains('跳过'), reason: result.error);
    expect(result.error, contains('1 行'), reason: result.error);
  });
}

/// 只关心「有没有被强关」的 HttpClient；其余成员不会被调到。
class _SpyClient implements HttpClient {
  final HttpClient inner = HttpClient();
  bool forceClosed = false;

  @override
  Future<HttpClientRequest> postUrl(Uri url) => inner.postUrl(url);

  @override
  void close({bool force = false}) {
    if (force) forceClosed = true;
    inner.close(force: force);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}
