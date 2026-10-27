import 'package:gal_ai/gal_ai.dart';
import 'package:test/test.dart';

void main() {
  test('parse structured multi-segment reply', () {
    final out = parseAiResponse('''
```json
{
  "protocolVersion": 1,
  "segments": [
    {"id": "s1", "speakerId": "jj", "expressionId": "thinking", "text": "让我先看看。"},
    {"id": "s2", "speakerId": "jj", "expressionId": "happy", "text": "钥匙正好。"}
  ],
  "suggestedReplies": ["进去"]
}
```''');
    expect(out.kind, ParseKind.parsed);
    expect(out.response!.segments, hasLength(2));
    expect(out.response!.segments[1].expressionId, 'happy');
  });

  test('plain text becomes single segment without inventing an expression', () {
    final out = parseAiResponse('（安静地陪着她）');
    expect(out.kind, ParseKind.plainText);
    // 非 JSON 文本：保留台词，但**不编表情**。留空表示「这一段没有表情信息」，
    // 调用方据此走「格式降级」处理；编一个 'default' 会让「没给」和「给错了」
    // 在下游看起来一样（都触发兜底）。
    expect(out.response!.segments.single.expressionId, '');
    expect(out.response!.segments.single.portraitId, isNull);
    expect(out.response!.segments.single.text, '（安静地陪着她）');
  });

  test('扁平响应必须保留模型给的 portraitId / expressionId（复审缺陷）', () {
    final out = parseAiResponse('''
{"text":"你回来啦。","expressionId":"平常","portraitId":"校服_平常"}''');
    expect(out.kind, ParseKind.parsed);
    final seg = out.response!.segments.single;
    // 以前这里只搬 text/expressionId，模型给对的 portraitId 被静默丢掉，
    // 下游就报「模型未给出可用立绘」——看起来像模型的错，其实是解析器丢的。
    expect(seg.portraitId, '校服_平常');
    expect(seg.expressionId, '平常');
    expect(seg.text, '你回来啦。');
  });

  test('扁平响应也认 portrait 这个别名', () {
    final out = parseAiResponse('{"text":"嗯。","portrait":"便服_害羞"}');
    expect(out.response!.segments.single.portraitId, '便服_害羞');
  });

  test('只补立绘的修复回包（没有 text/id/speakerId）也要能解析', () {
    // 立绘修复请求明确要求模型「不要重复台词」，所以回包里常常只有
    // expressionId + portraitId。以前 `text!` 会抛异常、整份响应被判无效，
    // 这种请求就永远救不回来。
    final out = parseAiResponse(
        '{"segments":[{"expressionId":"开心","portraitId":"校服_开心"}]}');
    expect(out.kind, ParseKind.parsed);
    final seg = out.response!.segments.single;
    expect(seg.portraitId, '校服_开心');
    expect(seg.expressionId, '开心');
    expect(seg.text, '');
  });

  test('mock provider returns two expressions and can cancel', () async {
    final mock = MockDialogueProvider(
      delay: const Duration(milliseconds: 50),
      script: [
        // 取消中的请求也已消费一条脚本，重试需要独立的第二条。
        '{"protocolVersion":1,"segments":[{"id":"s1","speakerId":"jj","expressionId":"kx","text":"喵"}]}',
        '{"protocolVersion":1,"segments":[{"id":"s1","speakerId":"jj","expressionId":"kx","text":"喵"}]}'
      ],
    );
    final token = CancelToken();
    final future = mock.generate(
      const GenerateRequest(messages: []),
      cancel: token,
    );
    token.cancel();
    final res = await future;
    expect(res.status, ProviderStatus.cancelled);

    final res2 = await mock.generate(const GenerateRequest(messages: []));
    expect(res2.ok, isTrue);
    expect(res2.response!.segments.single.expressionId, 'kx');
  });

  test('format error path', () async {
    final mock2 = MockDialogueProvider(
      script: ['{"protocolVersion":1,"segments":[]}'],
    );
    final r = await mock2.generate(const GenerateRequest(messages: []));
    expect(r.ok, isFalse);
    expect(r.status, ProviderStatus.formatError);
  });

  test('segments 全是空对白 → formatError，不提交空回复', () async {
    // {"segments":[{}]} 曾被当成成功，最后显示空回复并记入一次交互。
    final mock = MockDialogueProvider(
      script: ['{"protocolVersion":1,"segments":[{}]}'],
    );
    final r = await mock.generate(const GenerateRequest(messages: []));
    expect(r.ok, isFalse);
    expect(r.status, ProviderStatus.formatError);
    expect(r.error, contains('empty dialogue'));
  });

  test('纯文本回退不受空对白规则影响（正文就是台词）', () async {
    final mock = MockDialogueProvider(
      script: ['（安静地陪着她）'],
    );
    final r = await mock.generate(const GenerateRequest(messages: []));
    expect(r.ok, isTrue);
    expect(r.response!.segments.single.text, '（安静地陪着她）');
  });
}
