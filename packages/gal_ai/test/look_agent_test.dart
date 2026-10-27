import 'package:gal_ai/gal_ai.dart';
import 'package:test/test.dart';

/// 立绘 agent 的解析与「不许改台词」守卫（纯函数）。
void main() {
  const original = '（小声）你回来啦。\n（顿了顿）今天很冷。';

  group('parseLookPlan', () {
    test('正常回包：节拍、总立绘、快捷回复都解析出来', () {
      final r = parseLookPlan('''
{"replyExpression":"平常","replyPortrait":"校服_平常",
 "segments":[
   {"text":"（小声）你回来啦。","expressionId":"平常","portraitId":"校服_平常"},
   {"text":"（顿了顿）今天很冷。","expressionId":"伤心","portraitId":"校服_伤心"}
 ],
 "suggestedReplies":["进去吧","我不冷"]}
''', original: original);
      expect(r.ok, isTrue);
      final plan = r.plan!;
      expect(plan.replyLook.portrait, '校服_平常');
      expect(plan.beats, hasLength(2));
      expect(plan.beats[1].portrait, '校服_伤心');
      expect(plan.suggestedReplies, ['进去吧', '我不冷']);
      // 拼得回原文 → 节拍可用（换行差异不算）
      expect(plan.reconstructs, isTrue);
      expect(plan.usableBeats, hasLength(2));
    });

    test('字段名写错/被包在代码块里也能救回来', () {
      final r = parseLookPlan(
        '```json\n{"replyEmotion":"开心","replyPortrait":"校服_开心",'
        '"beats":[{"slice":"（小声）你回来啦。","emotion":"开心","portrait":"校服_开心"},'
        '{"slice":"（顿了顿）今天很冷。","portraitId":"校服_伤心"}],'
        '"replies":["嗯"]}\n```',
        original: original,
      );
      expect(r.ok, isTrue);
      expect(r.plan!.beats, hasLength(2));
      expect(r.plan!.beats[1].portrait, '校服_伤心');
      expect(r.plan!.suggestedReplies, ['嗯']);
    });

    test('节拍改写了台词 → 重建失败，usableBeats 为空（退回整条一张）', () {
      final r = parseLookPlan(
        '{"segments":[{"text":"你回来啦。","expressionId":"平常","portraitId":"校服_平常"}]}',
        original: original,
      );
      expect(r.ok, isTrue);
      expect(r.plan!.reconstructs, isFalse);
      expect(r.plan!.usableBeats, isEmpty, reason: 'agent 不许改台词');
    });

    test('只差标点/丢了一个括号 → 按位置对齐，用原文片段切分（不丢字）', () {
      // 真机日志里出现过「节拍=2 重建失败」：模型把括号或标点挪了位置。
      final r = parseLookPlan(
        '{"segments":['
        '{"text":"（小声）你回来啦。","expressionId":"平常","portraitId":"校服_平常"},'
        '{"text":"今天很冷。","expressionId":"伤心","portraitId":"校服_伤心"}]}',
        original: original,
      );
      expect(r.plan!.reconstructs, isTrue);
      expect(r.plan!.aligned, isTrue);
      expect(r.plan!.reconstructLabel, contains('按位置对齐'));
      // 对齐后的片段拼起来**等于原文**，一个字都不少
      final joined = r.plan!.beats.map((b) => b.text).join();
      expect(joined, original);
      // 表情/立绘仍然按节拍保留
      expect(r.plan!.beats.first.portrait, '校服_平常');
      expect(r.plan!.beats.last.portrait, '校服_伤心');
    });

    test('节拍顺序乱了也算失败（不能把表情配到别的台词上）', () {
      final r = parseLookPlan(
        '{"segments":['
        '{"text":"（顿了顿）今天很冷。","portraitId":"校服_伤心"},'
        '{"text":"（小声）你回来啦。","portraitId":"校服_平常"}]}',
        original: original,
      );
      expect(r.plan!.reconstructs, isFalse);
    });

    test('只切了前半段 → 对齐成「一段覆盖全文」，一个字都不丢', () {
      // 模型只给了一段（后半段没切），按位置对齐后这一段覆盖到结尾：
      // 表情只有一个（等于整条一张），但**台词不会被截断**。
      final r = parseLookPlan(
        '{"segments":[{"text":"（小声）你回来啦。","portraitId":"校服_平常"}]}',
        original: original,
      );
      expect(r.plan!.reconstructs, isTrue);
      expect(r.plan!.beats, hasLength(1));
      expect(r.plan!.beats.single.text, original);
    });

    test('节拍里有关键词被改掉（原文里找不到）→ 重建失败', () {
      final r = parseLookPlan(
        '{"segments":[{"text":"（大声）你回来啦。","portraitId":"校服_平常"}]}',
        original: '（小声）你回来啦。',
      );
      expect(r.plan!.reconstructs, isFalse);
    });

    test('标点与空白差异可以接受（只有空白不同才算一致）', () {
      final r = parseLookPlan(
        '{"segments":[{"text":"（小声）你回来啦。（顿了顿）今天很冷。","portraitId":"校服_平常"}]}',
        original: original,
      );
      expect(r.plan!.reconstructs, isTrue);
    });

    test('不是 JSON → 明确失败，不编造节拍', () {
      final r = parseLookPlan('（小声）你回来啦。', original: original);
      expect(r.ok, isFalse);
      expect(r.error, isNotNull);
    });

    test('只给总立绘、没有 segments（聊天解析器会拒，agent 应能接）', () {
      // 复审 P2：这类回包以前被 parseAiResponse 判 empty segments，
      // provider 直接 formatError，agent 的解析器根本没机会跑。
      final r = parseLookPlan(
        '{"replyExpression":"平常","replyPortrait":"校服_平常",'
        '"suggestedReplies":["嗯"]}',
        original: original,
      );
      expect(r.ok, isTrue);
      expect(r.plan!.replyLook.portrait, '校服_平常');
      expect(r.plan!.beats, isEmpty);
      expect(r.plan!.usableBeats, isEmpty);
      expect(r.plan!.suggestedReplies, ['嗯']);
    });

    test('beats 字段（非 segments）也能解析', () {
      final r = parseLookPlan(
        '{"replyPortrait":"校服_平常",'
        '"beats":['
        '{"slice":"（小声）你回来啦。","emotion":"平常","portrait":"校服_平常"},'
        '{"slice":"（顿了顿）今天很冷。","emotion":"伤心","portrait":"校服_伤心"}]}',
        original: original,
      );
      expect(r.ok, isTrue);
      expect(r.plan!.beats, hasLength(2));
    });
  });

  group('节拍锚点（模型只给开头几个字）', () {
    test('锚点按原文切片：节拍拼起来仍是完整原文，一个字都没被模型改过', () {
      final r = parseLookPlan(
        '{"replyExpression":"平常","replyPortrait":"校服_平常",'
        '"suggestedReplies":["进去吧"],'
        '"segments":[{"startsWith":"（小声）","expressionId":"平常","portraitId":"校服_平常"},'
        '{"startsWith":"（顿了顿）","expressionId":"伤心","portraitId":"校服_伤心"}]}',
        original: original,
      );
      expect(r.ok, isTrue);
      final plan = r.plan!;
      expect(plan.beats.map((b) => b.text).join(), original);
      expect(plan.beats[1].portrait, '校服_伤心');
      expect(plan.reconstructs, isTrue);
      expect(plan.usableBeats, hasLength(2));
    });

    test('第一个锚点不在开头 → 不猜，退回整条一张立绘', () {
      final r = parseLookPlan(
        '{"segments":[{"startsWith":"今天很冷","expressionId":"伤心",'
        '"portraitId":"校服_伤心"}]}',
        original: original,
      );
      expect(r.ok, isTrue);
      expect(r.plan!.reconstructs, isFalse);
      expect(r.plan!.usableBeats, isEmpty);
    });

    test('锚点在原文里找不到 → 退回整条一张立绘', () {
      final r = parseLookPlan(
        '{"segments":[{"startsWith":"（大声）你回来啦","expressionId":"开心",'
        '"portraitId":"校服_开心"}]}',
        original: original,
      );
      expect(r.plan!.reconstructs, isFalse);
      expect(r.plan!.usableBeats, isEmpty);
    });
  });

  group('LookPlanStream：边收边用', () {
    test('总立绘闭合就先给表情，快捷回复闭合再给，节拍再长也不影响它们', () {
      final s = LookPlanStream();
      var d = s.feed('{"replyExpres');
      expect(d.isEmpty, isTrue, reason: '字段还没闭合，什么都不该给（不许猜）');

      d = s.feed('sion":"开心","replyPortrait":"校服_开心",');
      expect(d.look?.expression, '开心');
      expect(d.look?.portrait, '校服_开心');
      expect(d.replies, isNull, reason: '快捷回复还没到');

      d = s.feed('"suggestedReplies":["进去吧","我不冷"],');
      expect(d.replies, ['进去吧', '我不冷']);

      d = s.feed('"segments":[{"startsWith":"（小声）"}]}');
      expect(d.isEmpty, isTrue, reason: '后面的大段节拍不该再重复吐东西');
    });

    test('数组没闭合时不给快捷回复', () {
      final s = LookPlanStream();
      expect(s.feed('{"suggestedReplies":["进去吧",').replies, isNull);
      expect(s.feed('"我不冷"').replies, isNull);
      expect(s.feed(']}').replies, ['进去吧', '我不冷']);
    });

    test('只认主字段名：段内的 expressionId 不会被当成整条的总立绘', () {
      final s = LookPlanStream();
      final d = s.feed(
        '{"segments":[{"startsWith":"（小声）","expressionId":"开心"}]}',
      );
      expect(d.look, isNull, reason: '某一拍的表情不等于整条的总立绘');
    });

    test('转义引号还原成正字', () {
      final s = LookPlanStream();
      final d = s.feed(r'{"suggestedReplies":["他说\"好\"","走"]}');
      expect(d.replies, ['他说"好"', '走']);
    });
  });

  group('buildLookPlanPrompt', () {
    test('带上两张词表，且用与上下文块相同的表头（离线 mock 也认）', () {
      final p = buildLookPlanPrompt(
        portraitOptions: const ['校服_平常', '校服_开心'],
        emotionOptions: const ['平常', '开心'],
        replyText: '你回来啦。',
      );
      expect(p, contains('【可用立绘】'));
      expect(p, contains('校服_平常、校服_开心'));
      expect(p, contains('【可用情绪】'));
      expect(p, contains('平常、开心'));
      // 台词原文要给它（靠它判断该用哪张立绘、该给什么推荐词）
      expect(p, contains('你回来啦。'));
    });

    test('不再要求切节拍、也不要求引用台词（那是 agent 最贵的一块输出）', () {
      final p = buildLookPlanPrompt(
        portraitOptions: const ['校服_平常'],
        emotionOptions: const ['平常'],
        replyText: '你回来啦。',
      );
      expect(
        p,
        contains('不要切节拍'),
        reason: '节拍从未被接线（打字机不按它换立绘），留着只让模型多写几十上百 token',
      );
      expect(
        p.contains('"segments"'),
        isFalse,
        reason: '模板里不该再有节拍字段',
      );
      expect(p, contains('不要改写台词'), reason: '要明确禁止抄台词/长篇解释');
    });

    test('字段顺序写成「总立绘 → 快捷回复」（流式边收边用靠这个顺序）', () {
      final p = buildLookPlanPrompt(
        portraitOptions: const ['校服_平常'],
        emotionOptions: const ['平常'],
        replyText: '你回来啦。',
      );
      final portraitAt = p.indexOf('"replyPortrait"');
      final repliesAt = p.indexOf('"suggestedReplies"');
      expect(portraitAt, greaterThan(0), reason: '模板里要有总立绘字段');
      expect(
        repliesAt,
        greaterThan(portraitAt),
        reason: '表情在前：它一闭合就能切立绘',
      );
    });
  });
}
