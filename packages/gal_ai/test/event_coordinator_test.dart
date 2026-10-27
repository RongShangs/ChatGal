import 'package:gal_ai/gal_ai.dart';
import 'package:gal_protocol/gal_protocol.dart';
import 'package:test/test.dart';

/// 事件：`events/<id>/event.json` 里一块 = 一张图 + 若干句（**一块一屏**）。
/// 播放在 [EventDef.frames] 上逐格推进（每块一帧，块内多句按换行拼成整屏文字）；
/// 播完交出一份 [EventFinishDraft]，出口块由调用方按**与情景同一套**规则判定。
EventDef _event(
  String id, {
  required List<Map<String, Object?>> slides,
  List<Map<String, Object?>> target = const [],
}) =>
    EventDef.fromJson({'slides': slides, 'target': target}, id: id);

/// 典型的「一图多句」事件：第一块 3 句，第二块（沿用图片）2 句 → 两屏。
EventDef _fiveFrameEvent(String id) => _event(
      id,
      slides: [
        {
          'image': 'cover.png',
          'text': ['第一句', '第二句', '第三句'],
        },
        {
          'image': null,
          'text': ['第四句', '第五句'],
        },
      ],
      target: [
        {
          'kind': [
            {'kind': 'appShell', 'to': 'home'},
          ],
        },
      ],
    );

WorldSnapshot _world({Map<String, Object?> variables = const {'戒戒堕落': 10}}) =>
    WorldSnapshot(
      variables: variables,
      characters: const {},
      eventHistory: const {},
      story: const {'storyId': 'start', 'day': 14},
      presentation: const {},
      rngState: 1,
    );

void main() {
  group('播放序列：一块一屏（frames 每块一帧）', () {
    final e = _fiveFrameEvent('event_a');

    test('frames 的数量 = 块数，块内多句拼成整屏文字', () {
      expect(e.slides, hasLength(2));
      expect(e.frames, hasLength(2));
      expect(e.frames.map((f) => f.text), [
        '第一句\n第二句\n第三句',
        '第四句\n第五句',
      ]);
    });

    test('image: null 已经解析成沿用上一张', () {
      expect(e.frames.map((f) => f.image), ['cover.png', 'cover.png']);
    });

    test('currentFrame 给的是「这一屏」的图和整屏文字', () {
      final c = EventCoordinator(events: {'event_a': e});
      final s = c.open(eventId: 'event_a', eventVisitId: 1);
      expect(c.currentFrame(s)!.text, '第一句\n第二句\n第三句');
      final second = c.advance(s)!;
      expect(c.currentFrame(second)!.text, '第四句\n第五句');
      expect(c.currentFrame(second)!.image, 'cover.png');
    });
  });

  group('逐屏推进', () {
    test('advance 走到最后一屏后 canFinish；再 advance 返回 null', () {
      final c = EventCoordinator(events: {'event_a': _fiveFrameEvent('event_a')});
      var s = c.open(eventId: 'event_a', eventVisitId: 2);
      expect(s.slideIndex, 0);
      expect(c.canFinish(s), isFalse);
      for (var i = 1; i < 2; i++) {
        s = c.advance(s)!;
        expect(s.slideIndex, i);
      }
      expect(c.canFinish(s), isTrue);
      expect(c.advance(s), isNull);
    });

    test('中途恢复播放：访问号与进度都保住', () {
      final c = EventCoordinator(events: {'event_a': _fiveFrameEvent('event_a')});
      final resume = c.open(eventId: 'event_a', eventVisitId: 2, slideIndex: 1);
      expect(resume.eventVisitId, 2);
      expect(resume.slideIndex, 1);
      expect(c.currentFrame(resume)!.text, '第四句\n第五句');
    });

    test('slideIndex 超出范围会被夹到最后一屏', () {
      final c = EventCoordinator(events: {'event_a': _fiveFrameEvent('event_a')});
      final s = c.open(eventId: 'event_a', eventVisitId: 1, slideIndex: 99);
      expect(s.slideIndex, 1);
    });

    test('还没播完就 finish → StateError（不能提前收尾）', () {
      final c = EventCoordinator(events: {'event_a': _fiveFrameEvent('event_a')});
      final s = c.open(eventId: 'event_a', eventVisitId: 1);
      expect(() => c.finish(s), throwsA(isA<StateError>()));
    });

    test('未知事件 → open/finish 报错', () {
      final c = EventCoordinator(events: const {});
      expect(
        () => c.open(eventId: 'ghost', eventVisitId: 1),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('收尾草稿与出口路由', () {
    /// 一直推进到最后一格（finish 只允许在播完之后调用）。
    EventPlayState toEnd(EventCoordinator c, EventPlayState s) {
      var cur = s;
      while (!c.canFinish(cur)) {
        cur = c.advance(cur)!;
      }
      return cur;
    }

    test('finish 的 commitId 带访问号（不同访问不会撞车）', () {
      final c = EventCoordinator(events: {'event_a': _fiveFrameEvent('event_a')});
      final draft = c.finish(
        toEnd(c, c.open(eventId: 'event_a', eventVisitId: 7)),
      );
      expect(draft.eventId, 'event_a');
      expect(draft.eventVisitId, 7);
      expect(draft.commitId, 'ef_event_a_v7_done');
      expect(draft.target, hasLength(1));
      // 访问号不同 → id 必须不同，否则第二次触发会被幂等台账误判成已收尾
      final again = c.finish(
        toEnd(c, c.open(eventId: 'event_a', eventVisitId: 8)),
      );
      expect(again.commitId, isNot(draft.commitId));
    });

    test('草稿只带 target，不再有 onFinish / effects（收尾效果写在出口上）', () {
      final c = EventCoordinator(events: {'event_a': _fiveFrameEvent('event_a')});
      final draft = c.finish(
        toEnd(c, c.open(eventId: 'event_a', eventVisitId: 1)),
      );
      // 播完之后走的是同一套出口块判定：appShell 也能是目的地
      final router = TargetRouter();
      final chosen = router.route(draft.target, _world(), rngState: 1);
      expect(chosen, isNotNull);
      expect(chosen!.kind, 'appShell');
      expect(chosen.to, 'home');
    });

    test('事件出口也能回剧情：条件成立时走 story', () {
      final e = _event(
        'end_demo',
        slides: [
          {
            'image': 'cover.png',
            'text': ['结束了。'],
          },
        ],
        target: [
          {
            'require': '"戒戒堕落" <= 65',
            'kind': [
              {'kind': 'story', 'to': 'endless_human_day'},
            ],
          },
          {
            'kind': [
              {'kind': 'appShell', 'to': 'home'},
            ],
          },
        ],
      );
      final c = EventCoordinator(events: {'end_demo': e});
      final draft = c.finish(c.open(eventId: 'end_demo', eventVisitId: 1));
      final router = TargetRouter();
      final chosen = router.route(draft.target, _world(), rngState: 1);
      expect(chosen!.kind, 'story');
      expect(chosen.to, 'endless_human_day');
      // 堕落度很高 → 条件不成立，落到无条件兜底块
      final fallback = router.route(
        draft.target,
        _world(variables: const {'戒戒堕落': 90}),
        rngState: 1,
      );
      expect(fallback!.kind, 'appShell');
    });
  });

  group('storyVisitId：事件翻页必须保留剧情访问号', () {
    test('open 带入 storyVisitId，advance 后仍保留', () {
      final c = EventCoordinator(events: {'event_a': _fiveFrameEvent('event_a')});
      final s0 = c.open(eventId: 'event_a', eventVisitId: 1, storyVisitId: 5);
      expect(s0.storyVisitId, 5);
      // toCursor 把 storyVisitId 写进 visitId
      final cur = s0.toCursor();
      expect(cur.visitId, 5);
      expect(cur.eventVisitId, 1);
      // 翻页后 storyVisitId 不能被清零
      final s1 = c.advance(s0)!;
      expect(s1.storyVisitId, 5);
      expect(s1.slideIndex, 1);
    });

    test('默认 storyVisitId=0（不传时兼容旧行为）', () {
      final c = EventCoordinator(events: {'event_a': _fiveFrameEvent('event_a')});
      final s = c.open(eventId: 'event_a', eventVisitId: 1);
      expect(s.storyVisitId, 0);
    });
  });
}
