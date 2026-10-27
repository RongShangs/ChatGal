import 'package:gal_ai/gal_ai.dart';
import 'package:gal_protocol/gal_protocol.dart';
import 'package:test/test.dart';

/// 包把关系变量声明在自己的（中文）id 下并打上 role，所以引擎侧从不写死名字。
const ranges = <String, ({num? min, num? max})>{
  '戒戒好感': (min: 0, max: 100),
};

WorldSnapshot w() => const WorldSnapshot(
      variables: {'戒戒好感': 50},
      characters: {},
      eventHistory: {},
      story: {'day': 1},
      presentation: {},
      rngState: 1,
    );

void main() {
  test('模型回 attributeProposal 也不会改数值：这条通道已删除', () async {
    final mock = MockDialogueProvider(
      script: [
        '{"protocolVersion":1,"segments":[{"id":"s1","speakerId":"jj","expressionId":"happy","text":"谢谢"}],"attributeProposal":{"affection":9,"trust":0,"obedience":0,"depravity":0}}'
      ],
    );
    final coord = TurnCoordinator(provider: mock);
    final out = await coord.submit(
      sessionId: 's1',
      world: w(),
      messages: const [],
      userText: '给你糖',
      ranges: ranges,
    );
    expect(out.accepted, isTrue);
    expect(
      out.world.variables['戒戒好感'],
      50,
      reason: '回合内不改数值：现在只有离场结算与入场改值会动世界状态',
    );
    expect(out.revision, 1);
  });

  test('会话忙时拒绝并发提交', () async {
    final mock = MockDialogueProvider(
      delay: const Duration(milliseconds: 80),
      script: [
        '{"protocolVersion":1,"segments":[{"id":"s1","speakerId":"jj","expressionId":"default","text":"慢"}]}'
      ],
    );
    final coord = TurnCoordinator(provider: mock);
    final f1 = coord.submit(
      sessionId: 's2',
      world: w(),
      messages: const [],
      userText: 'a',
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final f2 = await coord.submit(
      sessionId: 's2',
      world: w(),
      messages: const [],
      userText: 'b',
    );
    expect(f2.accepted, isFalse);
    expect(f2.error, contains('busy'));
    final f1r = await f1;
    expect(f1r.accepted, isTrue);
  });

  test('空的 segments 视为失败，数值保持原样', () async {
    final mock = MockDialogueProvider(
      script: ['{"protocolVersion":1,"segments":[]}'],
    );
    final coord = TurnCoordinator(provider: mock);
    final out = await coord.submit(
      sessionId: 's3',
      world: w(),
      messages: const [],
      userText: 'x',
      ranges: ranges,
    );
    expect(out.accepted, isFalse);
    expect(out.world.variables['戒戒好感'], 50);
  });

  test('预组装上下文原样送出：L1 活跃窗口生效，而不是全量历史', () async {
    final rec = _Recorder();
    final coord = TurnCoordinator(provider: rec);
    final out = await coord.submit(
      sessionId: 's4',
      world: w(),
      // 应用持有的全量历史：这次不该出现在请求里
      messages: const [
        {'role': 'user', 'content': 'DECOY_RAW_HISTORY'},
      ],
      userText: '你好',
      assembledMessages: const [
        {'role': 'system', 'content': 'BASE_PROMPT'},
        {'role': 'system', 'content': '【可用立绘】\n校服_开心\n（逐字选一个）'},
        {'role': 'user', 'content': 'WINDOW_TURN'},
        {'role': 'assistant', 'content': 'WINDOW_REPLY'},
      ],
      audience: const ['jj'],
    );
    expect(out.accepted, isTrue);

    final sent = rec.last!.map((m) => m['content']).join('\n');
    expect(sent, contains('BASE_PROMPT'));
    expect(sent, contains('【可用立绘】'));
    expect(sent, contains('WINDOW_TURN'));
    expect(sent, contains('WINDOW_REPLY'));
    expect(sent, isNot(contains('DECOY_RAW_HISTORY')));
    // 本轮玩家输入永远在最后一条
    expect(rec.last!.last['role'], 'user');
    expect(rec.last!.last['content'], '你好');

    // 写回的消息带上 turnId / audience，供记忆层做知情过滤
    final assistant = out.messages.last;
    expect(assistant['role'], 'assistant');
    expect(assistant['turnId'], isNotNull);
    expect(assistant['audience'], ['jj']);
    expect(out.messages[out.messages.length - 2]['turnId'],
        assistant['turnId']);
  });

  test('开场（opening）不写回玩家消息，只补一条舞台指示', () async {
    final rec = _Recorder();
    final coord = TurnCoordinator(provider: rec);
    final out = await coord.submit(
      sessionId: 'open',
      world: w(),
      messages: const [],
      userText: '',
      assembledMessages: const [
        {'role': 'system', 'content': 'BASE'},
      ],
      opening: true,
    );
    expect(out.accepted, isTrue);
    expect(
      rec.last!.any((m) => (m['content'] ?? '').contains('由你先开口')),
      isTrue,
    );
    // 写回的消息里不能凭空多出一条空的玩家消息
    expect(out.messages.where((m) => m['role'] == 'user'), isEmpty);
    expect(out.messages.last['role'], 'assistant');
  });

  test('玩家那句话原样发出去，也不改动存档里的记录', () async {
    final rec = _Recorder();
    final coord = TurnCoordinator(provider: rec);
    final out = await coord.submit(
      sessionId: 's6',
      world: w(),
      messages: const [],
      userText: '在吗',
      assembledMessages: const [
        {'role': 'system', 'content': 'BASE'},
      ],
    );
    expect(out.accepted, isTrue);
    // 立绘/格式的额外要求已经不在这个请求里（改由立绘 agent 承担），
    // 玩家这句话要原样发出去
    final sentUser = rec.last!.lastWhere((m) => m['role'] == 'user');
    expect('${sentUser['content']}', '在吗');
    final storedUser = out.messages.lastWhere((m) => m['role'] == 'user');
    expect('${storedUser['content']}', '在吗');
  });

  test('AI 选的立绘名（portraitId）透传到结果', () async {
    final rec = _Recorder();
    final coord = TurnCoordinator(provider: rec);
    final out = await coord.submit(
      sessionId: 's5',
      world: w(),
      messages: const [],
      userText: '在吗',
      assembledMessages: const [
        {'role': 'system', 'content': 'BASE'},
      ],
    );
    expect(out.accepted, isTrue);
    expect(out.aiResponse!.segments.last.portraitId, '校服_开心');
    expect(out.aiResponse!.segments.last.expressionId, '开心');
  });

  test('本轮玩家输入只出现一次（组装方附过就不再追加）', () async {
    final rec = _Recorder();
    final coord = TurnCoordinator(provider: rec);
    final out = await coord.submit(
      sessionId: 's6',
      world: w(),
      messages: const [],
      userText: '同一句话',
      assembledMessages: const [
        {'role': 'system', 'content': 'BASE'},
        {'role': 'user', 'content': '同一句话'},
      ],
    );
    expect(out.accepted, isTrue);
    final hits =
        rec.last!.where((m) => m['content'] == '同一句话').length;
    expect(hits, 1, reason: '重复追加会把玩家那句话发两遍');
  });
}

/// 记录最后一次请求的假 provider。
class _Recorder implements DialogueProvider {
  List<Map<String, String>>? last;

  @override
  Future<ProviderResult> generate(
    GenerateRequest request, {
    CancelToken? cancel,
    void Function(String delta)? onDelta,
  }) async {
    last = request.messages;
    return ProviderResult.ok(
      response: const AIResponse(
        protocolVersion: 1,
        segments: [
          DialogueSegment(
            id: 's1',
            speakerId: 'jj',
            expressionId: '开心',
            text: '嗯。',
            portraitId: '校服_开心',
          ),
        ],
      ),
    );
  }
}
