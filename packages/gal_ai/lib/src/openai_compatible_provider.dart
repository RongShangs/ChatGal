import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'cancel_token.dart';
import 'dialogue_provider.dart';
import 'parse_ai_response.dart';
import 'provider_config.dart';
import 'provider_result.dart';

/// OpenAI-compatible /chat/completions provider。
///
/// **每次请求一个自己的 HttpClient**：取消时靠 `close(force: true)` 直接掐断
/// 连接。共享一个 client 就没法强制关（会连带掐掉别的在飞的请求），而只靠
/// `Future.any` 放弃等待是不够的 —— 输掉的那条分支还在读响应流，连接会一直挂着。
/// 注入进来的 client 例外：那是调用方的资源，本类不关（见 [_closeClient]）。
class OpenAiCompatibleProvider implements DialogueProvider {
  OpenAiCompatibleProvider(this.config, {HttpClient? client})
      : _injected = client;

  final ProviderConfig config;

  /// 测试注入用。非空时不由本类负责关闭。
  final HttpClient? _injected;

  /// 流式收流时留存的原始 body 上限：服务器忽略 `stream:true`（或直接回错误体）
  /// 时，这一段原始 body 必须原样交回 [generate]，否则用户看不到服务器说的话。
  /// 但也别让一个不结束的响应把内存吃光，所以只留头部。
  /// 按 UTF-8 解码后的字符数计（不是字节数），量级够用即可。
  static const int _maxRawChars = 1024 * 1024;

  @override
  Future<ProviderResult> generate(
    GenerateRequest request, {
    CancelToken? cancel,
    void Function(String delta)? onDelta,
  }) async {
    // 本地/局域网服务常常不需要 Key：空 Key 不是配置错误。
    // 有 Key 才附带 Authorization；服务端要鉴权时会回 401，由调用方看到真实错误。
    final useStream = request.stream;
    final body = jsonEncode({
      'model': config.model,
      'messages': request.messages,
      'temperature': config.temperature,
      'max_tokens': request.maxTokens ?? config.maxTokens,
      'stream': useStream,
    });

    final client = _injected ?? _newClient();
    try {
      // 对**完整请求生命周期**设截止时间：postUrl 的 timeout 只覆盖建立连接，
      // 读响应体没有总超时。服务商挂起时会永远停在等待状态。
      final statusCodeFuture = useStream
          ? _sendAndReadStream(client, body, cancel, onDelta)
          : _sendAndRead(client, body, cancel);
      final result = await statusCodeFuture.timeout(
        config.timeout,
        onTimeout: () {
          _closeClient(client);
          throw TimeoutException('full request timeout');
        },
      );
      if (result.cancelled) {
        return const ProviderResult.failed(
          status: ProviderStatus.cancelled,
          error: 'cancelled',
        );
      }
      final raw = result.body;
      final status = result.statusCode;

      if (status == 429) {
        return ProviderResult.failed(
          status: ProviderStatus.rateLimited,
          error: 'HTTP 429',
          rawText: raw,
        );
      }
      if (status != 200) {
        return ProviderResult.failed(
          status: ProviderStatus.invalid,
          error: 'HTTP $status',
          rawText: raw,
        );
      }

      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final choices = decoded['choices'] as List?;
      if (choices == null || choices.isEmpty) {
        return ProviderResult.failed(
          status: ProviderStatus.formatError,
          error: 'no choices',
          rawText: raw,
        );
      }
      final choice = choices.first;
      final message = choice['message'];
      // 思考内容不上屏、不进 L1、不污染记忆：`<think>…</think>` 在流式与非流式
      // 两条路径上必须用同一条剥离逻辑（以前关掉流式设置时思考会上屏）。
      final content = stripThinkTags(_contentOf(message));
      if (content.trim().isEmpty) {
        // 空回复不是「模型没写好」，而是请求本身有问题：把它当成错误报出来，
        // 并带上 finish_reason 与原始响应体 —— 否则解析器会用 `……` 占位，
        // 看起来像模型输出了一段省略号，根本没法排查。
        final finish = '${choice['finish_reason'] ?? '?'}';
        final reasoning =
            message is Map ? '${message['reasoning_content'] ?? ''}' : '';
        final skipped = result.skippedLines > 0
            ? '；跳过 ${result.skippedLines} 行无法解析的数据'
            : '';
        return ProviderResult.failed(
          status: ProviderStatus.formatError,
          error: 'empty content (finish_reason=$finish'
              '${reasoning.isNotEmpty ? ', 内容都在 reasoning_content 里' : ''})'
              '$skipped',
          rawText: raw,
        );
      }
      final outcome = parseAiResponse(content);
      if (!outcome.ok) {
        return ProviderResult.failed(
          status: ProviderStatus.formatError,
          error: outcome.error,
          rawText: content,
        );
      }
      final resp = outcome.response!;
      // JSON 形态的 segments 全无对白正文 → 不算成功。
      // 纯文本回退（plainText）不走这条：它的正文就是台词本身。
      if (outcome.kind == ParseKind.parsed &&
          resp.segments.isNotEmpty &&
          resp.segments.every((s) => s.text.trim().isEmpty)) {
        return ProviderResult.failed(
          status: ProviderStatus.formatError,
          error: 'empty dialogue text',
          rawText: content,
        );
      }
      return ProviderResult.ok(response: resp, rawText: content);
    } on TimeoutException {
      return const ProviderResult.failed(
        status: ProviderStatus.timeout,
        error: 'timeout',
      );
    } on SocketException catch (e) {
      if (cancel?.isCancelled == true) {
        return const ProviderResult.failed(
          status: ProviderStatus.cancelled,
          error: 'cancelled',
        );
      }
      return ProviderResult.failed(
        status: ProviderStatus.offline,
        error: e.message,
      );
    } catch (e) {
      // 被强关的连接会以各种异常形式冒出来（SocketException / HttpException /
      // 流被中止）——统一按取消处理，别让用户看到「network error」。
      if (cancel?.isCancelled == true) {
        return const ProviderResult.failed(
          status: ProviderStatus.cancelled,
          error: 'cancelled',
        );
      }
      return ProviderResult.failed(
        status: ProviderStatus.invalid,
        error: '$e',
      );
    } finally {
      // 流已读完或已强关，这里收尾；注入的 client 交给调用方关。
      _closeClient(client);
    }
  }

  /// 强关连接打断读流 —— 但**只对自己创建的 client**。
  ///
  /// 注入进来的 client 是调用方的资源（测试复用同一条连接），本类既不该关它，
  /// 也就没法靠强关连接来立刻结束读流：这种情况下取消靠 CancelToken 判定，
  /// 超时靠 [ProviderConfig.timeout]。
  void _closeClient(HttpClient client) {
    if (_injected != null) return;
    try {
      client.close(force: true);
    } catch (_) {}
  }

  Future<_HttpOutcome> _sendAndRead(
    HttpClient client,
    String body,
    CancelToken? cancel,
  ) async {
    final req = await client.postUrl(config.chatCompletionsUri);
    req.headers.contentType = ContentType.json;
    if (config.apiKey.isNotEmpty) {
      req.headers
          .set(HttpHeaders.authorizationHeader, 'Bearer ${config.apiKey}');
    }
    req.write(body);

    if (cancel != null && cancel.isCancelled) {
      _closeClient(client);
      return const _HttpOutcome.cancelled();
    }

    // 取消信号一到就强关连接：正在读的响应流会立刻抛，落到 catch，
    // 由 `cancel.isCancelled` 判定为「已取消」而不是「网络错误」。
    final watcher = cancel?.whenCancelled;
    if (watcher != null) {
      unawaited(watcher.then((_) => _closeClient(client)));
    }

    final resp = await req.close();
    final raw = await resp.transform(utf8.decoder).join();
    if (cancel?.isCancelled == true) {
      return const _HttpOutcome.cancelled();
    }
    return _HttpOutcome(statusCode: resp.statusCode, body: raw);
  }

  /// SSE 流式：边收边回调正文增量，结束后拼回「非流式形状」的 JSON body，
  /// 让 [generate] 后半段解析逻辑完全复用。
  Future<_HttpOutcome> _sendAndReadStream(
    HttpClient client,
    String body,
    CancelToken? cancel,
    void Function(String delta)? onDelta,
  ) async {
    final req = await client.postUrl(config.chatCompletionsUri);
    req.headers.contentType = ContentType.json;
    if (config.apiKey.isNotEmpty) {
      req.headers
          .set(HttpHeaders.authorizationHeader, 'Bearer ${config.apiKey}');
    }
    req.write(body);

    if (cancel != null && cancel.isCancelled) {
      _closeClient(client);
      return const _HttpOutcome.cancelled();
    }

    final watcher = cancel?.whenCancelled;
    if (watcher != null) {
      unawaited(watcher.then((_) => _closeClient(client)));
    }

    final resp = await req.close();
    final statusCode = resp.statusCode;

    final full = StringBuffer();

    // 服务器不一定理会 `stream:true`：可能整段回一个普通 JSON，也可能回 401
    // 错误体。这些都不是 SSE，唯一的去向就是原始 body —— 所以边收边留一份。
    final rawHead = StringBuffer();
    var rawTruncated = false;
    void captureRaw(String chunk) {
      final room = _maxRawChars - rawHead.length;
      if (room <= 0) {
        rawTruncated = true;
        return;
      }
      if (chunk.length <= room) {
        rawHead.write(chunk);
      } else {
        rawHead.write(chunk.substring(0, room));
        rawTruncated = true;
      }
    }

    var pendingText = '';
    var inThink = false;
    var sawDataLine = false;
    var skippedLines = 0;
    String? finishReason;

    void emit(String text) {
      if (text.isEmpty) return;
      full.write(text);
      onDelta?.call(text);
    }

    /// 处理一行 SSE。返回 true 表示收到 `[DONE]`，可以不再等下去了。
    bool handleLine(String rawLine) {
      final line = rawLine.trim();
      if (line.isEmpty) return false;
      if (!line.startsWith('data:')) return false;
      sawDataLine = true;
      final payload = line.substring(5).trim();
      if (payload == '[DONE]') return true;
      try {
        final map = jsonDecode(payload);
        if (map is! Map) return false;
        final choices = map['choices'] as List?;
        if (choices == null || choices.isEmpty) return false;
        final first = choices.first;
        if (first is! Map) return false;
        final reason = first['finish_reason'];
        if (reason is String && reason.isNotEmpty) finishReason = reason;
        final text = _contentOf(first['delta']);
        if (text.isEmpty) return false;
        final split = splitThinkTags('$pendingText$text', inThink: inThink);
        pendingText = split.rest;
        inThink = split.inThink;
        emit(split.visible);
      } catch (_) {
        // 坏行照旧直接丢（容错行为不变），但要记个数：静默吞掉会让「正文为空」
        // 这类问题完全无从排查。
        skippedLines++;
      }
      return false;
    }

    var lineBuf = '';
    var done = false;
    try {
      await for (final chunk in resp.transform(utf8.decoder)) {
        if (cancel?.isCancelled == true) {
          return const _HttpOutcome.cancelled();
        }
        captureRaw(chunk);
        // SSE 以行分发；chunk 可能跨行，按累积缓冲再切。
        lineBuf += chunk;
        var start = 0;
        while (!done) {
          final nl = lineBuf.indexOf('\n', start);
          if (nl < 0) break;
          final line = lineBuf.substring(start, nl);
          start = nl + 1;
          if (handleLine(line)) done = true;
        }
        lineBuf = start >= lineBuf.length ? '' : lineBuf.substring(start);
        // `data: [DONE]` 是自终止的：不带换行时也得立刻收手，否则连接不关的
        // 服务器会一直把这次请求卡到总超时。
        if (!done && lineBuf.trim() == 'data: [DONE]') {
          handleLine(lineBuf);
          lineBuf = '';
          done = true;
        }
        if (done) break;
      }
    } catch (e) {
      if (cancel?.isCancelled == true) {
        return const _HttpOutcome.cancelled();
      }
      rethrow;
    }

    if (cancel?.isCancelled == true) {
      return const _HttpOutcome.cancelled();
    }

    // 缓冲余量：最后一条 `data:` 不一定以换行收尾，同样按一行处理，
    // 别把最后一截 delta 悄悄丢掉。
    if (!done && lineBuf.isNotEmpty) {
      handleLine(lineBuf);
    }

    // 普通正文末尾的 '<' 等不是完整标签；未闭合的思考内容仍不展示。
    if (!inThink && pendingText.isNotEmpty) {
      emit(pendingText);
      pendingText = '';
    }

    _logSseSkipped(skippedLines);

    final rawBody = rawTruncated
        ? '${rawHead.toString()}…[gal_ai] 原始响应超过 $_maxRawChars 字符，已截断'
        : rawHead.toString();

    // 非 200：错误体（`{"error":{"message":…}}`）必须原样带出去，否则用户只
    // 看得到 `HTTP 401`，看不到服务器说的原因。
    // 200 且没有任何 `data:` 行：服务器忽略了 stream:true，整段就是一个普通
    // JSON 回包 —— 按非流式口径交回 generate，复用它那一整套解析与错误口径。
    if (statusCode != 200 || (!sawDataLine && rawBody.trim().isNotEmpty)) {
      return _HttpOutcome(statusCode: statusCode, body: rawBody);
    }

    // 拼成非流式响应体，复用 generate 的解析与错误口径。
    final assembled = jsonEncode({
      'choices': [
        {
          'message': {'content': full.toString()},
          // 不写死 'stop'：服务端给的真实 finish_reason（length /
          // content_filter）正是排查「正文为空」的关键线索。
          if (finishReason != null) 'finish_reason': finishReason,
        },
      ],
    });
    return _HttpOutcome(
      statusCode: statusCode,
      body: assembled,
      skippedLines: skippedLines,
    );
  }

  HttpClient _newClient() {
    final c = HttpClient();
    c.connectionTimeout = config.timeout;
    c.idleTimeout = const Duration(seconds: 15);
    return c;
  }
}

/// 坏行不能静默吞掉，但也不能每行都刷屏：**一条流最多报一次**。
///
/// 本包是纯 Dart 包，没有日志设施可用（应用层的 `AppLogger` 在 Flutter 侧，
/// 这里依赖不到），所以用 `print` 并包在 assert 里：debug 下可见，release 下
/// 整段被去掉。用户能看到的确定性信息在「跳过的行数」里，由 `generate` 拼进
/// 错误文本。
void _logSseSkipped(int skipped) {
  if (skipped <= 0) return;
  assert(() {
    print('[gal_ai] SSE 收流跳过了 $skipped 行无法解析的数据');
    return true;
  }());
}

/// 剥掉 `<think>…</think>`，返回**可播放正文**与还判定不了的尾巴。
///
/// 纯函数：结果只由入参决定。流式侧必须容忍标签被 delta 拆开（`<thi` + `nk>`），
/// 所以除了正文，还返回 [rest]（可能是被拆开的标签前缀，也可能是未闭合的思考
/// 内容）和解析结束时是否仍在思考块内的 [inThink]：调用方把 [rest] 接到下一段
/// 文本前面继续解析。
///
/// 未闭合的思考内容不展示（留着 [rest] 里，此时 [inThink] 为 true）。
({String visible, String rest, bool inThink}) splitThinkTags(
  String text, {
  bool inThink = false,
}) {
  final out = StringBuffer();
  var pending = text;
  var thinking = inThink;
  while (pending.isNotEmpty) {
    final tag = thinking ? '</think>' : '<think>';
    final at = pending.indexOf(tag);
    if (at >= 0) {
      if (!thinking && at > 0) out.write(pending.substring(0, at));
      pending = pending.substring(at + tag.length);
      thinking = !thinking;
      continue;
    }
    // 只保留可能属于标签的尾部；标签可以跨任意多个 delta。
    var keep = 0;
    for (var n = 1; n < tag.length && n <= pending.length; n++) {
      if (pending.endsWith(tag.substring(0, n))) keep = n;
    }
    // 尾部之前的部分：不在思考块里就是正文，在思考块里整段丢掉。
    if (!thinking && pending.length > keep) {
      out.write(pending.substring(0, pending.length - keep));
    }
    pending = pending.substring(pending.length - keep);
    break;
  }
  return (visible: out.toString(), rest: pending, inThink: thinking);
}

/// 整段文本（非流式回包，或流已经结束）的可播放正文。
///
/// 与流式共用 [splitThinkTags]：末尾那个孤立的 `<` 不像标签，要照常显示；
/// 未闭合的思考内容则整段丢掉。
String stripThinkTags(String text) {
  final split = splitThinkTags(text);
  return split.inThink ? split.visible : '${split.visible}${split.rest}';
}

class _HttpOutcome {
  const _HttpOutcome({
    required this.statusCode,
    required this.body,
    this.skippedLines = 0,
  }) : cancelled = false;
  const _HttpOutcome.cancelled()
      : statusCode = 0,
        body = '',
        skippedLines = 0,
        cancelled = true;

  final int statusCode;
  final String body;

  /// 流式收流时丢掉、无法解析的 `data:` 行数。
  final int skippedLines;
  final bool cancelled;
}

/// 取出 message.content。
///
/// 有些 OpenAI 兼容端点把 content 返回成**分段数组**
/// （`[{"type":"text","text":"…"}]`），直接 `as String?` 会得到 null → 被判成空回复。
String _contentOf(Object? message) {
  if (message is! Map) return '';
  final c = message['content'];
  if (c is String) return c;
  if (c is List) {
    final buf = StringBuffer();
    for (final part in c) {
      if (part is Map && part['text'] is String) {
        buf.write(part['text']);
      }
    }
    return buf.toString();
  }
  return '';
}
