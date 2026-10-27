import 'dart:async';

import 'package:gal_ai/gal_ai.dart';
import 'package:gal_protocol/gal_protocol.dart';
import 'package:test/test.dart';

/// 情景夹具按**扁平**契约写：没有 `enter`/`leave`/`exit`，`fixedEffects` 是
/// 「正数为加、负数为减」，结算写成 `settlement` 数组（**每个变量一个块**：
/// 自己的提示词 + 自己的上限），出口写在 `target` 块数组里。
Map<String, Object?> _sceneJson({
  required String id,
  String? to,
  int enterDayDelta = 0,
  bool settlement = true,
  String onNoEvidence = 'zero',
  String? require,
}) =>
    {
      'displayName': 'scene_$id',
      'characters': [
        {'charId': 'demo', 'state': 'casual', 'emotion': 'normal', 'scenePrompt': 'p'},
      ],
      'fixedEffects': [
        if (enterDayDelta != 0) {'id': 'day', 'value': enterDayDelta},
      ],
      'settlement': [
        if (settlement)
          {
            'var': 'affection',
            'prompt': '本幕更亲近则给正数，更疏远则负数，无证据 0',
            'maxAbsDelta': 3,
            'onNoEvidence': onNoEvidence,
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

SceneDef _scene(String id, {String? to, int enterDayDelta = 0, String? require}) =>
    SceneDef.fromJson(
      _sceneJson(id: id, to: to, enterDayDelta: enterDayDelta, require: require),
      id: id,
    );

SceneGraph _graph() => SceneGraph(
      scenes: {
        'start': _scene('start', to: 's1'),
        's1': _scene('s1', to: 's2', enterDayDelta: 0),
        's2': _scene('s2', to: 's1', enterDayDelta: 1),
      },
      entrypoint: 'start',
    );

WorldSnapshot _worldAtStart() {
  return const WorldSnapshot(
    variables: {'day': 0, 'affection': 50},
    characters: {},
    eventHistory: {},
    story: {'storyId': 'start', 'day': 0},
    presentation: {
      'cursor': {'mode': 'storyChat', 'storyId': 'start', 'visitId': 0},
    },
    rngState: 1,
  );
}

/// 角色变量住在**同一个扁平命名空间**里（「affection」就是变量 id），
/// 注册表提供结算后的上下限夹取。
VariableRegistry _registry() => VariableRegistry.build(
      variables: const [
        VariableDef(id: 'day', type: 'int', defaultValue: 0, min: 0, max: 9999),
        VariableDef(
          id: 'affection',
          type: 'int',
          defaultValue: 50,
          min: 0,
          max: 100,
        ),
        VariableDef(
          id: 'trust',
          type: 'int',
          defaultValue: 50,
          min: 0,
          max: 100,
        ),
      ],
      characterIds: const ['demo'],
    );

TransitionCoordinator _coord({required SceneGraph graph}) =>
    TransitionCoordinator(graph: graph, registry: _registry());

void main() {
  group('SettlementValidator', () {
    test('本幕没声明的变量被拒', () {
      const v = SettlementValidator();
      expect(
        () => v.apply(
          proposal: const SettlementProposal(deltas: {'trust': 1}),
          allowedVars: {'affection'},
          maxAbsDeltaPerVar: const {'affection': 3},
          currentValues: const {'affection': 50, 'trust': 50},
        ),
        throwsA(isA<SettlementValidationError>()),
      );
    });

    test('没注册过的变量也被拒（不是静默忽略）', () {
      const v = SettlementValidator();
      expect(
        () => v.apply(
          proposal: const SettlementProposal(deltas: {'没注册': 1}),
          allowedVars: {'没注册'},
          maxAbsDeltaPerVar: const {'没注册': 3},
          currentValues: const {},
        ),
        throwsA(isA<SettlementValidationError>()),
      );
    });

    test('每个变量按**自己**的上限夹取（不是共用一个上限）', () {
      const v = SettlementValidator();
      final d = v.apply(
        proposal: const SettlementProposal(deltas: {'affection': 10, 'trust': 10}),
        allowedVars: {'affection', 'trust'},
        maxAbsDeltaPerVar: const {'affection': 3, 'trust': 1},
        currentValues: const {'affection': 50, 'trust': 50},
      );
      expect(d['affection'], 3);
      expect(d['trust'], 1, reason: 'trust 自己的上限是 1');
      expect(
        v.apply(
          proposal: const SettlementProposal(deltas: {'affection': -10}),
          allowedVars: {'affection'},
          maxAbsDeltaPerVar: const {'affection': 3},
          currentValues: const {'affection': 50},
        )['affection'],
        -3,
      );
    });
  });

  group('TransitionCoordinator', () {
    test('leave start -> s1 applies settlement', () async {
      final c = _coord(graph: _graph());
      final r = await c.leaveCurrent(
        sessionId: 's',
        world: _worldAtStart(),
        messages: const [],
        baseRevision: 0,
        provider: const MockSettlementProvider(deltas: {'affection': 2}),
      );
      expect(r.accepted, isTrue, reason: r.error);
      expect(r.noExit, isFalse);
      expect(r.nextSceneId, 's1');
      expect(r.appliedDeltas['affection'], 2);
      final aff = (r.world!.variables['affection'] as num).toInt();
      expect(aff, 52);
      expect(r.cursor!.storyId, 's1');
      expect(r.cursor!.visitId, 1);
      // start 没有 fixedEffects，day 不动
      expect(r.world!.variables['day'], 0);
      // 结算过的幂等 id 要交回给调用方落盘
      expect(r.appliedSettlementIds, [
        TransitionCoordinator.settlementIdFor(
          sessionId: 's',
          fromStoryId: 'start',
          fromVisitId: 0,
        ),
      ]);
    });

    test('enter fixedEffects 正数为加：进 s2 时 day + 1', () async {
      final c = _coord(graph: _graph());
      final world = _worldAtStart().copyWith(
        story: const {'storyId': 's1', 'day': 0},
        variables: const {'day': 0, 'affection': 50},
      );
      final r = await c.leaveCurrent(
        sessionId: 's',
        world: world,
        messages: const [],
        baseRevision: 0,
        provider: const MockSettlementProvider(),
      );
      expect(r.accepted, isTrue, reason: r.error);
      expect(r.nextSceneId, 's2');
      expect(r.world!.variables['day'], 1);
      // story 是 day 的镜像
      expect(r.world!.story['day'], 1);
    });

    test('double leave rejects busy', () async {
      final c = _coord(graph: _graph());
      final slow = _DelayedSettlement();
      final f1 = c.leaveCurrent(
        sessionId: 's',
        world: _worldAtStart(),
        messages: const [],
        baseRevision: 0,
        provider: slow,
      );
      await Future<void>.delayed(Duration.zero);
      final f2 = await c.leaveCurrent(
        sessionId: 's',
        world: _worldAtStart(),
        messages: const [],
        baseRevision: 0,
        provider: const MockSettlementProvider(),
      );
      expect(f2.accepted, isFalse);
      expect(f2.noExit, isFalse);
      expect(f2.error, 'busy');
      slow.complete();
      final r1 = await f1;
      expect(r1.accepted, isTrue);
    });

    test('settlement onNoEvidence=abort 时整笔离场被拒、世界不变', () async {
      final c = _coord(
        graph: SceneGraph(
          scenes: {
            'start': _scene('start', to: 's1'),
            's1': SceneDef.fromJson(
              _sceneJson(id: 's1', to: 's2', onNoEvidence: 'abort'),
              id: 's1',
            ),
          },
          entrypoint: 'start',
        ),
      );
      final world = _worldAtStart().copyWith(
        story: const {'storyId': 's1', 'day': 0},
      );
      final before = world.variables['affection'];
      final r = await c.leaveCurrent(
        sessionId: 's',
        world: world,
        messages: const [],
        baseRevision: 0,
        // 没有证据 → 返回 null
        provider: const MockSettlementProvider(),
      );
      expect(r.accepted, isFalse);
      expect(r.error, contains('abort'));
      expect(world.variables['affection'], before);
    });

    test('abort 逐项：proposal 有其他变量但缺 abort 变量 → 拒绝', () async {
      // 两块：affection(zero) + trust(abort)。模型只回了 affection。
      final c = _coord(
        graph: SceneGraph(
          scenes: {
            'start': _scene('start', to: 's1'),
            's1': SceneDef.fromJson(
              {
                'displayName': 's1',
                'characters': [
                  {
                    'charId': 'demo',
                    'state': 'casual',
                    'emotion': 'normal',
                    'scenePrompt': 'p',
                  },
                ],
                'settlement': [
                  {
                    'var': 'affection',
                    'prompt': '亲近？',
                    'maxAbsDelta': 3,
                    'onNoEvidence': 'zero',
                  },
                  {
                    'var': 'trust',
                    'prompt': '信任？',
                    'maxAbsDelta': 3,
                    'onNoEvidence': 'abort',
                  },
                ],
                'target': [
                  {
                    'kind': [
                      {'kind': 'story', 'to': 's2'},
                    ],
                  },
                ],
              },
              id: 's1',
            ),
            's2': _scene('s2'),
          },
          entrypoint: 'start',
        ),
      );
      final world = _worldAtStart().copyWith(
        story: const {'storyId': 's1', 'day': 0},
        variables: const {'day': 0, 'affection': 50, 'trust': 50},
      );
      // 只给了 affection，没有 trust（abort 变量）
      final r = await c.leaveCurrent(
        sessionId: 's',
        world: world,
        messages: const [],
        baseRevision: 0,
        provider: const MockSettlementProvider(deltas: {'affection': 2}),
      );
      expect(r.accepted, isFalse, reason: 'abort 变量缺失必须拒绝');
      expect(r.error, contains('abort'));
      expect(world.variables['affection'], 50, reason: '拒绝后数值不变');
      expect(world.variables['trust'], 50);
    });

    test('abort 逐项：两个变量都有值时照常结算', () async {
      final c = _coord(
        graph: SceneGraph(
          scenes: {
            'start': _scene('start', to: 's1'),
            's1': SceneDef.fromJson(
              {
                'displayName': 's1',
                'characters': [
                  {
                    'charId': 'demo',
                    'state': 'casual',
                    'emotion': 'normal',
                    'scenePrompt': 'p',
                  },
                ],
                'settlement': [
                  {
                    'var': 'affection',
                    'prompt': '亲近？',
                    'maxAbsDelta': 3,
                    'onNoEvidence': 'zero',
                  },
                  {
                    'var': 'trust',
                    'prompt': '信任？',
                    'maxAbsDelta': 3,
                    'onNoEvidence': 'abort',
                  },
                ],
                'target': [
                  {
                    'kind': [
                      {'kind': 'story', 'to': 's2'},
                    ],
                  },
                ],
              },
              id: 's1',
            ),
            's2': _scene('s2'),
          },
          entrypoint: 'start',
        ),
      );
      final r = await c.leaveCurrent(
        sessionId: 's',
        world: _worldAtStart().copyWith(
          story: const {'storyId': 's1', 'day': 0},
          variables: const {'day': 0, 'affection': 50, 'trust': 50},
        ),
        messages: const [],
        baseRevision: 0,
        provider: const MockSettlementProvider(
          deltas: {'affection': 2, 'trust': 1},
        ),
      );
      expect(r.accepted, isTrue, reason: r.error);
      expect(r.appliedDeltas['affection'], 2);
      expect(r.appliedDeltas['trust'], 1);
      expect(r.world!.variables['affection'], 52);
      expect(r.world!.variables['trust'], 51);
    });

    test('settlement onNoEvidence=zero 时照常换幕，只是不加数值', () async {
      final c = _coord(
        graph: SceneGraph(
          scenes: {
            'start': _scene('start', to: 's1'),
            's1': _scene('s1', to: 'start'),
          },
          entrypoint: 'start',
        ),
      );
      final r = await c.leaveCurrent(
        sessionId: 's',
        world: _worldAtStart().copyWith(
          story: const {'storyId': 's1', 'day': 0},
        ),
        messages: const [],
        baseRevision: 0,
        provider: const MockSettlementProvider(),
      );
      expect(r.accepted, isTrue, reason: r.error);
      expect(r.nextSceneId, 'start');
      expect(r.appliedDeltas, isEmpty);
      expect(r.world!.variables['affection'], 50);
    });

    test('本幕没写结算 → 一次都不问 provider', () async {
      final provider = _CountingSettlement();
      final c = _coord(
        graph: SceneGraph(
          scenes: {
            'start': SceneDef.fromJson(
              {
                'displayName': 'start',
                'target': [
                  {
                    'kind': [
                      {'kind': 'story', 'to': 's1'},
                    ],
                  },
                ],
              },
              id: 'start',
            ),
            's1': _scene('s1', to: 'start'),
          },
          entrypoint: 'start',
        ),
      );
      final r = await c.leaveCurrent(
        sessionId: 's',
        world: _worldAtStart(),
        messages: const [],
        baseRevision: 0,
        provider: provider,
      );
      expect(r.accepted, isTrue, reason: r.error);
      expect(provider.calls, 0);
      expect(r.appliedDeltas, isEmpty);
    });

    test('重放同一笔离场不会把数值加两遍（幂等 id）', () async {
      final c = _coord(graph: _graph());
      final first = await c.leaveCurrent(
        sessionId: 's',
        world: _worldAtStart(),
        messages: const [],
        baseRevision: 0,
        provider: const MockSettlementProvider(deltas: {'affection': 2}),
      );
      expect(first.accepted, isTrue, reason: first.error);
      expect(first.appliedSettlementIds, isNotEmpty);
      expect(first.world!.variables['affection'], 52);

      // 从**已结算的世界**再走一次同一笔离场（崩溃后重放就是这个形状），
      // 把已经落地的结算 id 交回去 → 不再结算，也不再加值。
      final replay = await c.leaveCurrent(
        sessionId: 's',
        world: first.world!.copyWith(
          story: const {'storyId': 'start', 'day': 0},
        ),
        messages: const [],
        baseRevision: 0,
        provider: const MockSettlementProvider(deltas: {'affection': 2}),
        appliedSettlementIds: first.appliedSettlementIds,
      );
      expect(replay.accepted, isTrue, reason: replay.error);
      expect(replay.appliedDeltas, isEmpty);
      expect(replay.appliedSettlementIds, isEmpty);
      expect(replay.world!.variables['affection'], 52, reason: '不能再加一遍');
    });

    test('settlementIdFor 只由「存档 + 情景 + 访问号」决定（不再有 ruleId）', () {
      final a = TransitionCoordinator.settlementIdFor(
        sessionId: 's',
        fromStoryId: 'start',
        fromVisitId: 0,
      );
      final b = TransitionCoordinator.settlementIdFor(
        sessionId: 's',
        fromStoryId: 'start',
        fromVisitId: 0,
      );
      expect(a, b, reason: '同一幕重试必须算出同一个 id');
      expect(
        a,
        isNot(TransitionCoordinator.settlementIdFor(
          sessionId: 's',
          fromStoryId: 'start',
          fromVisitId: 1,
        )),
        reason: '换一次访问就是新的一幕',
      );
    });

    test('整数只在解析阶段把关（1.5 直接拒）', () {
      expect(
        () => SettlementProposal.fromJson({
          'deltas': {'affection': 1.5},
        }),
        throwsA(isA<SettlementFormatException>()),
      );
      // 模型把整数写成 1.0 是常见的，必须容忍
      expect(
        SettlementProposal.fromJson({
          'deltas': {'affection': 1.0},
        }).deltas['affection'],
        1,
      );
    });

    test('pending committed residual does not roll back', () {
      final c = _coord(graph: _graph());
      final world = _worldAtStart();
      final r = c.clearCommittedPending(
        sessionId: 's',
        world: world,
        messages: const [],
        committedTransitions: ['tr_1'],
        pending: const PendingOp(
          kind: PendingOp.kindStoryTransition,
          id: 'tr_1',
          baseRevision: 0,
          phase: 'committed_residual',
        ),
      );
      expect(r.accepted, isTrue);
      expect(r.world!.variables['affection'], 50);
    });
  });

  group('没有出口（noExit）', () {
    test('压根没写 target：不报错，留在原情景', () async {
      final c = _coord(
        graph: SceneGraph(
          scenes: {'start': _scene('start')},
          entrypoint: 'start',
        ),
      );
      final r = await c.leaveCurrent(
        sessionId: 's',
        world: _worldAtStart(),
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
        baseRevision: 0,
        provider: const MockSettlementProvider(deltas: {'affection': 9}),
      );
      expect(r.accepted, isFalse);
      expect(r.noExit, isTrue);
      expect(r.error, isNull, reason: '没有出口是合法状态，不是错误');
      expect(r.nextSceneId, isNull);
      expect(r.cursor, isNull);
      // 世界与消息原样退回，玩家留在本幕继续对话
      expect(r.world!.variables['affection'], 50);
      expect(r.messages, hasLength(1));
    });

    test('写了 target 但所有块的 require 都不成立：同样返回 noExit', () async {
      final c = _coord(
        graph: SceneGraph(
          scenes: {
            'start': _scene('start', to: 's1', require: '"day" == 99'),
            's1': _scene('s1', to: 'start'),
          },
          entrypoint: 'start',
        ),
      );
      final r = await c.leaveCurrent(
        sessionId: 's',
        world: _worldAtStart(),
        messages: const [],
        baseRevision: 0,
        provider: const MockSettlementProvider(deltas: {'affection': 9}),
      );
      expect(r.noExit, isTrue);
      expect(r.error, isNull);
      expect(r.world!.variables['affection'], 50, reason: '不换幕就不落地结算');
    });
  });

  _progressGroup();
}

class _DelayedSettlement implements SettlementProvider {
  final _c = Completer<void>();
  void complete() => _c.complete();

  @override
  Future<SettlementProposal?> propose({
    required String sessionId,
    required SceneDef scene,
    required WorldSnapshot world,
    required SettlementEvidence evidence,
  }) async {
    await _c.future;
    return const SettlementProposal(deltas: {'affection': 1});
  }
}

/// 记录被调用了几次：本幕不结算时一次都不该被调用。
class _CountingSettlement implements SettlementProvider {
  int calls = 0;

  @override
  Future<SettlementProposal?> propose({
    required String sessionId,
    required SceneDef scene,
    required WorldSnapshot world,
    required SettlementEvidence evidence,
  }) async {
    calls++;
    return const SettlementProposal(deltas: {'affection': 1});
  }
}

void _progressGroup() {
  group('换场进度回调（给界面显示「在等什么」）', () {
    test('按 记忆 → 结算 → 完成 回调，且第一次就给出总步数', () async {
      final coord = TransitionCoordinator(
        graph: _graph(),
        registry: _registry(),
        memory: MemoryRuntime(provider: const DeterministicMemoryProvider()),
      );
      final bank = MemoryBank();
      bank.recordTurn(
        DialogueTurn(
          turnId: 't1',
          playerText: '今天也一起走吧',
          replyText: '嗯。',
          audience: const ['demo'],
          storyId: 'start',
          visitId: 0,
          at: DateTime.utc(2026, 9, 15),
        ),
      );

      final seen = <String>[];
      final r = await coord.leaveCurrent(
        sessionId: 's',
        world: _worldAtStart(),
        messages: const [],
        baseRevision: 0,
        provider: const MockSettlementProvider(deltas: {'affection': 1}),
        bank: bank,
        onProgress: (phase, done, total, owner) =>
            seen.add('${phase.name}:$done/$total:${owner ?? '-'}'),
      );

      expect(r.accepted, isTrue, reason: r.error);
      // 第一步就得有分母（进度条要能算出比例），所以 total 在第一次回调里已经就绪：
      // 1 个角色的 L1→L2 提炼 + 1 次离场结算 = 2 步。
      expect(seen.first, 'memory:0/2:-');
      expect(seen, contains('memory:1/2:demo'));
      expect(seen, contains('settlement:1/2:-'));
      expect(seen.last, 'done:2/2:-');
    });

    test('本幕不结算时总步数只有提炼那一步', () async {
      final graph = SceneGraph(
        scenes: {
          'start': SceneDef.fromJson(
            _sceneJson(id: 'start', to: 's1', settlement: false),
            id: 'start',
          ),
          's1': _scene('s1', to: 'start'),
        },
        entrypoint: 'start',
      );
      final coord = TransitionCoordinator(
        graph: graph,
        registry: _registry(),
        memory: MemoryRuntime(provider: const DeterministicMemoryProvider()),
      );
      final bank = MemoryBank();
      bank.recordTurn(
        DialogueTurn(
          turnId: 't1',
          playerText: '嗯',
          replyText: '嗯',
          audience: const ['demo'],
          storyId: 'start',
          visitId: 0,
          at: DateTime.utc(2026, 9, 15),
        ),
      );
      final seen = <String>[];
      final r = await coord.leaveCurrent(
        sessionId: 's',
        world: _worldAtStart(),
        messages: const [],
        baseRevision: 0,
        provider: const MockSettlementProvider(deltas: {'affection': 1}),
        bank: bank,
        onProgress: (phase, done, total, owner) =>
            seen.add('${phase.name}:$done/$total'),
      );
      expect(r.accepted, isTrue, reason: r.error);
      expect(seen.first, 'memory:0/1');
      expect(seen.last, 'done:1/1');
      expect(
        seen.any((s) => s.startsWith('settlement')),
        isFalse,
        reason: '本幕没有结算块就不该有结算那一步',
      );
    });
  });
}
