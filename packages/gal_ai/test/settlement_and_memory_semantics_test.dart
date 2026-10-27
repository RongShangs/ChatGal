import 'package:gal_ai/gal_ai.dart';
import 'package:gal_protocol/gal_protocol.dart';
import 'package:test/test.dart';

/// 结算与离场记忆的语义边界。
///
/// 旧契约里「规则的条件式触发」（`rules[]` + 对象式 `when`）与
/// 「`leave.memory` 三态（enabled / cascade）已经随内容包格式一起删掉：
/// * 一幕**只结算一次**；结算写成 `settlement` 数组，**每个受控变量一个块**
///   （自己的 prompt + 自己的 maxAbsDelta + 自己的 onNoEvidence）；
/// * 出口条件写在 `target` 块里，且读的是**结算之后**的值；
/// * 离场一律做「本幕 L1 → 一条 L2」的提炼，没有开关。
Map<String, Object?> _scene(
  String id, {
  String? to,
  String? require,
  int enterDayDelta = 0,
  String? onNoEvidence,
  int maxAbsDelta = 3,
  Map<String, int>? extraVars,
}) =>
    {
      'displayName': id,
      'characters': [
        {'charId': 'jj', 'state': 'a', 'emotion': 'n', 'scenePrompt': 'p'},
      ],
      'fixedEffects': [
        if (enterDayDelta != 0) {'id': 'day', 'value': enterDayDelta},
      ],
      'settlement': [
        {
          'var': '好感',
          'prompt': '她有没有更亲近：有明确证据才给正数，疏远给负数，看不出来 0。',
          'maxAbsDelta': maxAbsDelta,
          if (onNoEvidence != null) 'onNoEvidence': onNoEvidence,
        },
        if (extraVars != null)
          for (final e in extraVars.entries)
            {
              'var': e.key,
              'prompt': '按本幕表现给整数增量，无证据 0。',
              'maxAbsDelta': e.value,
            },
      ],
      'target': [
        if (to != null)
          {
            if (require != null) 'require': require,
            'kind': [
              {'kind': 'story', 'to': to},
            ],
          },
      ],
    };

SceneGraph _graph(
  String id,
  Map<String, Object?> scene, {
  String? to,
  int nextDayDelta = 0,
}) =>
    SceneGraph(
      scenes: {
        id: SceneDef.fromJson(scene, id: id),
        if (to != null)
          to: SceneDef.fromJson(_scene(to, enterDayDelta: nextDayDelta), id: to),
      },
      entrypoint: id,
    );

VariableRegistry _registry() => VariableRegistry.build(
      variables: const [
        VariableDef(id: 'day', type: 'int', defaultValue: 1, min: 1, max: 9999),
        VariableDef(id: '好感', type: 'int', defaultValue: 40, min: 0, max: 45),
      ],
      characterIds: const ['jj'],
    );

WorldSnapshot _world() => const WorldSnapshot(
      variables: {'day': 3, '好感': 40},
      characters: {},
      eventHistory: {},
      story: {'storyId': 's', 'day': 3},
      presentation: {},
      rngState: 1,
    );

Future<TransitionResult> _leave(
  SceneGraph graph, {
  MemoryBank? bank,
  MemoryRuntime? memory,
  SettlementProvider? provider,
}) =>
    TransitionCoordinator(
      graph: graph,
      registry: _registry(),
      memory: memory,
    ).leaveCurrent(
      sessionId: 's',
      world: _world(),
      messages: const [],
      baseRevision: 0,
      provider: provider ?? const _Deltas({'好感': 2}),
      bank: bank,
      cursor: const RuntimeCursor(storyId: 's', visitId: 0),
    );

void main() {
  group('结算语义', () {
    test('结算落进扁平命名空间，并按 maxAbsDelta 夹取', () async {
      // provider 给 +9，maxAbsDelta 是 3 → 只加 3
      final r = await _leave(
        _graph('s', _scene('s', to: 'next'), to: 'next'),
        provider: const _Deltas({'好感': 9}),
      );
      expect(r.accepted, isTrue, reason: r.error);
      expect(r.appliedDeltas['好感'], 3);
      expect(r.world!.variables['好感'], 43);
    });

    test('注册表上下限是最后一道闸（好感上限 45）', () async {
      final r = await _leave(
        _graph('s', _scene('s', to: 'next'), to: 'next'),
        provider: const _Deltas({'好感': 9}),
      );
      expect(r.world!.variables['好感'], 43);
      // 再来一次夹到上限：43 + 3 = 46 → 45
      final world = r.world!.copyWith(story: const {'storyId': 's', 'day': 3});
      final again = await TransitionCoordinator(
        graph: _graph('s', _scene('s', to: 'next'), to: 'next'),
        registry: _registry(),
      ).leaveCurrent(
        sessionId: 's2',
        world: world,
        messages: const [],
        baseRevision: 0,
        provider: const _Deltas({'好感': 9}),
        cursor: const RuntimeCursor(storyId: 's', visitId: 1),
      );
      expect(again.world!.variables['好感'], 45, reason: '不该越界');
    });

    test('模型给了白名单外的键 → 整笔离场作废，不落半个值', () async {
      final r = await _leave(
        _graph('s', _scene('s', to: 'next'), to: 'next'),
        provider: const _Deltas({'没这个词': 1}),
      );
      expect(r.accepted, isFalse);
      expect(r.error, contains('结算被拒'));
      expect(r.world!.variables['好感'], 40);
      expect(r.noExit, isFalse, reason: '这是错误，不是「没有出口」');
    });

    test('没有证据且 onNoEvidence=abort → 拒绝离场；zero → 照常换幕', () async {
      final abort = await _leave(
        _graph('s', _scene('s', to: 'next', onNoEvidence: 'abort'), to: 'next'),
        provider: const MockSettlementProvider(),
      );
      expect(abort.accepted, isFalse);
      expect(abort.error, contains('abort'));

      final zero = await _leave(
        _graph('s', _scene('s', to: 'next'), to: 'next'),
        provider: const MockSettlementProvider(),
      );
      expect(zero.accepted, isTrue, reason: zero.error);
      expect(zero.appliedDeltas, isEmpty);
      expect(zero.world!.variables['好感'], 40);
    });

    test('出口条件读结算之后的值', () async {
      // 好感 40，结算 +3 → 43，门槛 42 因此成立
      final r = await _leave(
        _graph(
          's',
          _scene('s', to: 'next', require: '"好感" >= 42'),
          to: 'next',
        ),
        provider: const _Deltas({'好感': 3}),
      );
      expect(r.accepted, isTrue, reason: r.error);
      expect(r.nextSceneId, 'next');
      expect(r.world!.variables['好感'], 43);
    });

    test('day 的判定用离场前的快照（day+1 写在下一幕的 fixedEffects 上）', () async {
      // 本幕是第 3 天：require 写 "day" == 3 → 成立，进 next 时 day 才 +1
      final r = await _leave(
        _graph(
          's',
          _scene('s', to: 'next', require: '"day" == 3'),
          to: 'next',
          nextDayDelta: 1,
        ),
        provider: const _Deltas({'好感': 0}),
      );
      expect(r.accepted, isTrue, reason: r.error);
      expect(r.nextSceneId, 'next');
      expect(r.world!.variables['day'], 4, reason: '进入下一幕才 +1');
    });

    test('require 写 "day" == 4 而本幕是第 3 天 → 没有出口', () async {
      final r = await _leave(
        _graph(
          's',
          _scene('s', to: 'next', require: '"day" == 4'),
          to: 'next',
        ),
        provider: const _Deltas({'好感': 0}),
      );
      expect(r.noExit, isTrue);
      expect(r.error, isNull);
    });
  });

  group('离场记忆路径（本幕 L1 → 一条 L2）', () {
    MemoryBank bankWithRounds() {
      final bank = MemoryBank();
      for (var i = 0; i < 3; i++) {
        bank.recordTurn(DialogueTurn(
          turnId: 't$i',
          playerText: '玩家$i',
          replyText: '回答$i',
          audience: const ['jj'],
          storyId: 's',
          visitId: 0,
          at: DateTime.utc(2026, 9, 13),
        ));
      }
      return bank;
    }

    test('默认离场：L1 提炼成一条 L2，窗口清空', () async {
      final bank = bankWithRounds();
      final r = await _leave(
        _graph('s', _scene('s', to: 'next'), to: 'next'),
        bank: bank,
        memory: MemoryRuntime(provider: const DeterministicMemoryProvider()),
      );
      final after = r.memories!;
      expect(after.windowOf('jj').length, 0, reason: '本幕的原始对话不带进下一幕');
      expect(after.treeOf('jj').layerList(2), hasLength(1));
      // 提炼永远在克隆上做：被拒的离场不能留下半提交的记忆
      expect(bank.windowOf('jj').length, 3, reason: '原 bank 不被就地改动');
    });

    test('被拒的离场不返回记忆草稿（all-or-nothing）', () async {
      final bank = bankWithRounds();
      final r = await _leave(
        _graph('s', _scene('s', to: 'next', onNoEvidence: 'abort'), to: 'next'),
        bank: bank,
        memory: MemoryRuntime(provider: const DeterministicMemoryProvider()),
        provider: const MockSettlementProvider(),
      );
      expect(r.accepted, isFalse);
      expect(r.memories, isNull);
      expect(bank.treeOf('jj').layerList(2), isEmpty);
    });

    test('没有 target 时直接返回 noExit，记忆与结算都不动', () async {
      final bank = bankWithRounds();
      final r = await _leave(
        _graph('s', _scene('s')),
        bank: bank,
        memory: MemoryRuntime(provider: const DeterministicMemoryProvider()),
      );
      expect(r.noExit, isTrue);
      expect(r.memories, isNull);
      expect(bank.windowOf('jj').length, 3);
    });
  });

  group('开场白不算结算证据', () {
    test('只有开场白（playerText 为空）时证据为空', () {
      final bank = MemoryBank();
      bank.recordTurn(
        DialogueTurn(
          turnId: 'open1',
          playerText: '',
          replyText: '早上好呀。',
          audience: const ['jj'],
          storyId: 's1',
          visitId: 0,
          at: DateTime.utc(2026, 9, 14),
        ),
      );
      final rt = MemoryRuntime(provider: const DeterministicMemoryProvider());
      final ev = rt.buildEvidence(
        bank: bank,
        owner: 'jj',
        scene: SceneDef.fromJson(
          {'displayName': 's1', 'settlement': <Object?>[]},
          id: 's1',
        ),
        visitId: 0,
        day: 1,
        audience: const ['jj'],
        state: const {},
      );
      expect(ev.shortTerm, isEmpty, reason: '开场白不算证据');
      expect(ev.hasContent, isFalse);
    });

    test('有玩家输入时证据非空', () {
      final bank = MemoryBank();
      bank.recordTurn(
        DialogueTurn(
          turnId: 't1',
          playerText: '你好。',
          replyText: '你好呀。',
          audience: const ['jj'],
          storyId: 's1',
          visitId: 0,
          at: DateTime.utc(2026, 9, 14),
        ),
      );
      final rt = MemoryRuntime(provider: const DeterministicMemoryProvider());
      final ev = rt.buildEvidence(
        bank: bank,
        owner: 'jj',
        scene: SceneDef.fromJson(
          {'displayName': 's1', 'settlement': <Object?>[]},
          id: 's1',
        ),
        visitId: 0,
        day: 1,
        audience: const ['jj'],
        state: const {},
      );
      expect(ev.hasContent, isTrue);
    });

    test('真实结算 provider 在空证据时返回 null（不请求模型）', () async {
      final capture = _CaptureProvider();
      final provider = DialogueSettlementProvider(capture);
      final proposal = await provider.propose(
        sessionId: 's',
        scene: SceneDef.fromJson(
          {
            'displayName': 's1',
            'settlement': [
              {'var': '好感', 'prompt': '亲近？', 'maxAbsDelta': 2},
            ],
          },
          id: 's1',
        ),
        world: WorldSnapshot(
          variables: const {'好感': 50},
          characters: const {},
          eventHistory: const {},
          story: const {},
          presentation: const {},
          rngState: 1,
        ),
        evidence: const SettlementEvidence(
          owner: 'jj',
          sceneId: 's1',
          sceneName: 's1',
          day: 1,
          shortTerm: [],
          state: {},
          audience: [],
        ),
      );
      expect(proposal, isNull);
      expect(capture.called, isFalse, reason: '空证据不应请求模型');
    });

    test('L1 已空但 L2 有真实交互 → 证据非空', () {
      // L1 窗口为空（已提炼），但 L2 有 hasPlayerInteraction=true 的摘要
      final bank = MemoryBank();
      bank.treeOf('jj').add(
        MemoryEntry(
          memId: 'l2_test',
          layer: 2,
          owner: 'jj',
          text: '玩家问了她今天过得怎样，她开心地回答了。',
          audience: const ['jj'],
          createdAt: DateTime.utc(2026, 9, 14),
          source: const {'kind': 'l1_to_l2'},
          sourceScenes: const [
            {'storyId': 's1', 'visitId': 0},
          ],
          hasPlayerInteraction: true,
        ),
      );
      final rt = MemoryRuntime(provider: const DeterministicMemoryProvider());
      final ev = rt.buildEvidence(
        bank: bank,
        owner: 'jj',
        scene: SceneDef.fromJson(
          {'displayName': 's1', 'settlement': <Object?>[]},
          id: 's1',
        ),
        visitId: 0,
        day: 1,
        audience: const ['jj'],
        state: const {},
      );
      expect(ev.hasContent, isTrue, reason: 'L1 空但 L2 有交互摘要应算证据');
      expect(ev.shortTerm.single, contains('玩家问了'));
    });

    test('纯开场白 L2（hasPlayerInteraction=false）不算证据', () {
      final bank = MemoryBank();
      bank.treeOf('jj').add(
        MemoryEntry(
          memId: 'l2_opening',
          layer: 2,
          owner: 'jj',
          text: '角色说了早上好，玩家没有回应。',
          audience: const ['jj'],
          createdAt: DateTime.utc(2026, 9, 14),
          source: const {'kind': 'l1_to_l2_fallback'},
          sourceScenes: const [
            {'storyId': 's1', 'visitId': 0},
          ],
          hasPlayerInteraction: false,
        ),
      );
      final rt = MemoryRuntime(provider: const DeterministicMemoryProvider());
      final ev = rt.buildEvidence(
        bank: bank,
        owner: 'jj',
        scene: SceneDef.fromJson(
          {'displayName': 's1', 'settlement': <Object?>[]},
          id: 's1',
        ),
        visitId: 0,
        day: 1,
        audience: const ['jj'],
        state: const {},
      );
      expect(ev.hasContent, isFalse, reason: '纯开场白摘要不算证据');
      expect(ev.shortTerm, isEmpty);
    });
  });
}

/// 捕获是否被调用的假 provider。
class _CaptureProvider implements DialogueProvider {
  bool called = false;

  @override
  Future<ProviderResult> generate(
    GenerateRequest request, {
    CancelToken? cancel,
    void Function(String delta)? onDelta,
  }) async {
    called = true;
    return ProviderResult.ok(
      response: AIResponse(
        protocolVersion: 1,
        segments: const [],
        suggestedReplies: const [],
      ),
      rawText: '{"deltas": {"好感": 1}}',
    );
  }
}

/// 原样回传一份增量的结算 provider（不看证据、不做白名单过滤）——
/// 专门用来喂「模型报了白名单外的键」这种坏输入。
class _Deltas implements SettlementProvider {
  const _Deltas(this.deltas);
  final Map<String, int> deltas;

  @override
  Future<SettlementProposal?> propose({
    required String sessionId,
    required SceneDef scene,
    required WorldSnapshot world,
    required SettlementEvidence evidence,
  }) async =>
      SettlementProposal(deltas: deltas);
}
