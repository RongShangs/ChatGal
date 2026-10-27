import 'package:gal_ai/gal_ai.dart';
import 'package:gal_protocol/gal_protocol.dart';
import 'package:test/test.dart';

/// 出口条件写在 story 自己的 `target` 里（`graph.json` / `endingChecks` 已删），
/// 而且是**中缀文本表达式**：`"好感" < 60 & "day" >= 7`。
/// 条件只读**扁平变量命名空间**。
Map<String, Object?> _scene(
  String id, {
  required List<Map<String, Object?>> target,
}) {
  return {
    'displayName': id,
    'characters': [
      {'charId': 'jj', 'state': 'a', 'emotion': 'n', 'scenePrompt': 'p'},
    ],
    'fixedEffects': <Map<String, Object?>>[],
    'target': target,
  };
}

/// 出口块：`require` 可省（无条件兜底），块内多个目的地等概率。
Map<String, Object?> _block(String? require, List<Map<String, Object?>> kinds) =>
    {
      if (require != null) 'require': require,
      'kind': kinds,
    };

TransitionCoordinator _coord() => TransitionCoordinator(
      graph: SceneGraph(
        scenes: {
          'day7_3': SceneDef.fromJson(
            _scene('day7_3', target: [
              _block('"好感" < 60 & "day" == 7', [
                {'kind': 'event', 'to': 'end_badend7'},
              ]),
              _block(null, [
                {'kind': 'story', 'to': 'day8_1'},
              ]),
            ]),
            id: 'day7_3',
          ),
          'day8_1': SceneDef.fromJson(
            _scene('day8_1', target: [
              _block(null, [
                {'kind': 'story', 'to': 'day8_1'},
              ]),
            ]),
            id: 'day8_1',
          ),
        },
        entrypoint: 'day7_3',
      ),
    );

WorldSnapshot _world(int affection) => WorldSnapshot(
      variables: {'day': 7, '好感': affection},
      characters: const {},
      eventHistory: const {},
      story: const {'storyId': 'day7_3', 'day': 7},
      presentation: const {},
      rngState: 1,
    );

Future<TransitionResult> _leave({
  required int affection,
  int visitId = 3,
  int? eventVisitId,
}) =>
    _coord().leaveCurrent(
      sessionId: 's',
      world: _world(affection),
      messages: const [],
      baseRevision: 0,
      provider: const MockSettlementProvider(),
      cursor: RuntimeCursor(
        storyId: 'day7_3',
        visitId: visitId,
        eventVisitId: eventVisitId,
      ),
    );

void main() {
  test('好感低于 60 → 走事件出口（条件来自 target.require）', () async {
    final r = await _leave(affection: 50);
    expect(r.accepted, isTrue, reason: r.error);
    expect(r.targetKind, 'event');
    expect(r.nextEventId, 'end_badend7');
    expect(r.nextSceneId, isNull);
    expect(r.cursor!.mode, RuntimeCursor.modeEventPlay);
    expect(r.cursor!.eventVisitId, 1, reason: '第一次进事件 → 访问号 1');
    // 进事件时记着「从哪一次剧情访问来的」：回剧情后要接着数
    expect(r.cursor!.visitId, 3);
    expect(r.world!.presentation['pendingEvent'], 'end_badend7');
  });

  test('好感达标 → 走剧情出口', () async {
    final r = await _leave(affection: 70);
    expect(r.accepted, isTrue, reason: r.error);
    expect(r.targetKind, 'story');
    expect(r.nextSceneId, 'day8_1');
    expect(r.nextEventId, isNull);
  });

  test('块顺序即优先级：两块都成立时首个被锁定', () async {
    // 50 时两个条件都成立（好感<60 与兜底），必须走事件
    final r = await _leave(affection: 50);
    expect(r.targetKind, 'event');
  });

  test('事件访问号累计递增：同一事件第二次进来不再是 1', () async {
    // 第一次：没有历史访问号 → 1
    final first = await _leave(affection: 50, visitId: 3);
    expect(first.cursor!.eventVisitId, 1);

    // 事件结束回到剧情时会把这个号带回来（chat_page 与 coordinator 都保留），
    // 于是第二次进同一事件必须变成 2 —— 否则 commitId 撞车、幂等台账误判。
    final second = await _leave(
      affection: 50,
      visitId: 4,
      eventVisitId: first.cursor!.eventVisitId,
    );
    expect(second.cursor!.eventVisitId, 2);
    expect(
      second.cursor!.eventVisitId,
      isNot(first.cursor!.eventVisitId),
      reason: 'commitId 由事件 id + 访问号拼成，两个必须不同',
    );
  });

  test('剧情→剧情 也把事件访问号带着走，不会被重置', () async {
    final r = await _leave(affection: 70, eventVisitId: 5);
    expect(r.targetKind, 'story');
    expect(r.cursor!.eventVisitId, 5);
  });

  test('没有任何块的 require 成立 → 没有出口（不是错误）', () async {
    final coord = TransitionCoordinator(
      graph: SceneGraph(
        scenes: {
          'day7_3': SceneDef.fromJson(
            _scene('day7_3', target: [
              _block('"day" == 99', [
                {'kind': 'story', 'to': 'day8_1'},
              ]),
            ]),
            id: 'day7_3',
          ),
          'day8_1': SceneDef.fromJson(
            _scene('day8_1', target: const []),
            id: 'day8_1',
          ),
        },
        entrypoint: 'day7_3',
      ),
    );
    final r = await coord.leaveCurrent(
      sessionId: 's',
      world: _world(70),
      messages: const [],
      baseRevision: 0,
      provider: const MockSettlementProvider(),
      cursor: const RuntimeCursor(storyId: 'day7_3', visitId: 3),
    );
    expect(r.noExit, isTrue);
    expect(r.error, isNull);
    expect(r.nextSceneId, isNull);
    expect(r.nextEventId, isNull);
  });
}
