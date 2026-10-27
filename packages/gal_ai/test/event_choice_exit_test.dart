import 'dart:io';

import 'package:gal_ai/gal_ai.dart';
import 'package:gal_protocol/gal_protocol.dart';
import 'package:test/test.dart';

/// 事件的选择题出口在**运行时**这一侧：
/// * `EventCoordinator.choiceOf` 认得出这个事件是不是选择题；
/// * 收尾草稿把 choice 一起交出来（调用方按玩家点的那个选项直接跳）；
/// * 默认包里三个「有后续日常」的结局结尾事件写的就是选择题。
EventDef eventWithChoice({
  String id = 'end_demo',
  List<Map<String, Object?>>? options,
  String title = '要继续留在这里吗？',
}) =>
    EventDef.fromJson(
      {
        'slides': [
          {
            'image': 'cover.png',
            'text': ['结束了。'],
          },
        ],
        'choice': {
          'title': title,
          'options': options ??
              const [
                {'text': '回到主页', 'kind': 'appShell', 'to': 'home'},
                {'text': '继续留在这里', 'kind': 'story', 'to': 'endless_x_day'},
              ],
        },
      },
      id: id,
    );

void main() {
  test('choiceOf：写了选择题就认得出来；没写的为 null', () {
    final plain = EventDef.fromJson(
      {
        'slides': [
          {
            'image': null,
            'text': ['一句'],
          },
        ],
        'target': [
          {
            'kind': [
              {'kind': 'appShell', 'to': 'home'},
            ],
          },
        ],
      },
      id: 'end_plain',
    );
    final c = EventCoordinator(events: {'end_demo': eventWithChoice(), 'end_plain': plain});
    expect(
      c.choiceOf(c.open(eventId: 'end_demo', eventVisitId: 1)),
      isNotNull,
    );
    expect(
      c.choiceOf(c.open(eventId: 'end_plain', eventVisitId: 1)),
      isNull,
    );
  });

  test('choice 为空数组时不算选择题（避免点不到最后一屏就走人）', () {
    final empty = EventDef.fromJson(
      {
        'slides': [
          {
            'image': null,
            'text': ['一句'],
          },
        ],
        'choice': {'options': <Object?>[]},
      },
      id: 'end_empty',
    );
    final c = EventCoordinator(events: {'end_empty': empty});
    expect(c.choiceOf(c.open(eventId: 'end_empty', eventVisitId: 1)), isNull);
  });

  test('收尾草稿带着 choice：选项里有回主页、也有去某情景', () {
    final c = EventCoordinator(events: {'end_demo': eventWithChoice()});
    final state = c.open(eventId: 'end_demo', eventVisitId: 3);
    expect(c.canFinish(state), isTrue);
    final draft = c.finish(state);
    expect(draft.choice, isNotNull);
    expect(draft.choice!.title, '要继续留在这里吗？');
    expect(draft.choice!.options.map((o) => o.target.kind), ['appShell', 'story']);
    expect(draft.choice!.options.map((o) => o.target.to), [
      'home',
      'endless_x_day',
    ]);
    // 幂等 id 不变：选择题不改变「这一幕只收尾一次」的身份
    expect(draft.commitId, 'ef_end_demo_v3_done');
    // 选择题和出口块是二选一：写 choice 的事件不再有 target
    expect(draft.target, isEmpty);
  });

  test('选择题的选项可以指向另一个事件', () {
    final c = EventCoordinator(
      events: {
        'end_demo': eventWithChoice(
          options: const [
            {'text': '看下一段', 'kind': 'event', 'to': 'end_next'},
          ],
        ),
      },
    );
    final draft = c.finish(c.open(eventId: 'end_demo', eventVisitId: 1));
    expect(draft.choice!.options.single.target.kind, 'event');
    expect(draft.choice!.options.single.target.to, 'end_next');
  });

  group('默认包：三个有后续日常的结局结尾是选择题', () {
    late PackageContent content;

    setUpAll(() {
      final root = Directory('${Directory.current.path}/../../content/default_v2');
      expect(root.existsSync(), isTrue, reason: root.path);
      final rootPath = root.absolute.path.replaceAll(r'\', '/');
      final files = <String, String>{};
      for (final f in root.listSync(recursive: true).whereType<File>()) {
        final rel = f.path.replaceAll(r'\', '/').substring(rootPath.length + 1);
        files[rel] = rel.endsWith('.png') ? '' : f.readAsStringSync();
      }
      content = PackageLoader.fromFiles(files);
    });

    test('end_csrj / end_xtgs / end_kwdl 都是「回主页 or 继续留在这里」', () {
      const expected = {
        'end_csrj': 'endless_human_day',
        'end_xtgs': 'endless_cat_day',
        'end_kwdl': 'endless_doll_day',
      };
      expected.forEach((eventId, endlessId) {
        final e = content.eventDefs[eventId];
        expect(e, isNotNull, reason: '$eventId 应该存在');
        expect(e!.hasChoice, isTrue, reason: '$eventId 应该是选择题出口');
        expect(e.target, isEmpty, reason: '$eventId 不该同时写 target');
        final targets = e.choice!.options.map((o) => '${o.target.kind}:${o.target.to}');
        expect(targets, contains('appShell:home'));
        expect(targets, contains('story:$endlessId'));
        // 选项文字是玩家看到的按钮文案，不能是空串
        for (final o in e.choice!.options) {
          expect(o.text.trim(), isNotEmpty);
        }
      });
    });

    test('badend7 / badend14 仍是出口块（直接回主页）', () {
      for (final id in const ['end_badend7', 'end_badend14']) {
        final e = content.eventDefs[id]!;
        expect(e.hasChoice, isFalse, reason: '$id 不该是选择题');
        expect(e.target, isNotEmpty);
        expect(e.target.single.kinds.single.kind, 'appShell');
        expect(e.target.single.kinds.single.to, 'home');
      }
    });

    test('所有事件都只写一种出口（choice 与 target 不同时存在）', () {
      for (final e in content.eventDefs.values) {
        if (e.choice != null) {
          expect(e.target, isEmpty, reason: '${e.id} 两种出口都写了');
          expect(e.choice!.options.length, lessThanOrEqualTo(EventChoice.maxOptions));
        }
      }
    });
  });
}
