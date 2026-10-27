import 'dart:convert';

/// 立绘 agent：把一段台词切成「情绪节拍」并给每个节拍选立绘。
///
/// 为什么单独一个请求（用户第四轮裁定「常驻 agent」）：真机日志显示，把
/// 「写台词 + 严格 JSON + 逐段选立绘」三件事同时压给一个请求时，模型会直接
/// 放弃 JSON 回纯文本 —— 于是每段都没有表情信息、全部走兜底。拆开之后：
/// * 聊天请求只负责写（可以放心让它用散文）；
/// * agent 请求只负责「切节拍 + 选一张合法立绘」，任务单一、格式稳定。
///
/// 一条硬约定：agent 切出的片段**必须能拼回原文**（忽略空白差异）。拼不回就
/// 退回「整条一张立绘」—— 绝不让 agent 改动角色实际说了什么。
class LookPlan {
  const LookPlan({
    required this.replyLook,
    required this.beats,
    required this.suggestedReplies,
    required this.reconstructs,
    this.aligned = false,
  });

  /// 整条回复的一个总立绘（拼不回原文时用它兜底）。
  final ({String expression, String portrait}) replyLook;

  /// 切好的节拍（可能为空 = 没切成功）。每段带原文片段。
  final List<({String text, String expression, String portrait})> beats;

  final List<String> suggestedReplies;

  /// beats 拼起来是否等于原文（忽略空白）。
  final bool reconstructs;

  /// 是否为「按位置对齐」的结果（模型只差标点/空白时走这条路）。
  final bool aligned;

  /// 能用的节拍：只有重建成功才算数。
  List<({String text, String expression, String portrait})> get usableBeats =>
      reconstructs && beats.isNotEmpty ? beats : const [];

  /// 日志用的短语。
  String get reconstructLabel {
    if (beats.isEmpty) return '无节拍（本版 agent 不再切节拍）';
    if (!reconstructs) return '失败（退回整条一张）';
    return aligned ? '成功（按位置对齐）' : '成功';
  }
}

/// agent 回答的解析结果。
class LookPlanParse {
  const LookPlanParse(this.plan, this.raw, this.error);

  final LookPlan? plan;
  final String raw;
  final String? error;

  bool get ok => plan != null;
}

/// 解析 agent 的 JSON。宽进严出：字段名写错/缺字段都尽量救，但**重建校验不过
/// 就只保留「总立绘」**，不采用它的切分。
LookPlanParse parseLookPlan(String text, {required String original}) {
  final cleaned = text.trim();
  Object? decoded;
  final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(cleaned);
  if (fence != null) decoded = _tryDecode(fence.group(1)!.trim());
  decoded ??= _tryDecode(cleaned);
  decoded ??= _tryDecode(_extractObject(cleaned));
  if (decoded is! Map) {
    return LookPlanParse(null, cleaned, '不是 JSON');
  }
  final map = Map<String, Object?>.from(decoded);

  String pick(Map<String, Object?> m, List<String> keys) {
    for (final k in keys) {
      final v = m[k];
      if (v is String && v.trim().isNotEmpty) return v.trim();
    }
    return '';
  }

  // 总立绘：本 agent 提示词用的是 replyExpression / replyPortrait，
  // 模型也常按 segments 的字段名回（expressionId / portraitId），两种都认。
  final replyLook = (
    expression: pick(map, [
      'replyExpression',
      'replyEmotion',
      'expressionId',
      'expression',
      'emotion'
    ]),
    portrait: pick(map, ['replyPortrait', 'portraitId', 'portrait']),
  );

  final rawBeats = map['segments'] ?? map['beats'] ?? const [];
  final beats = <({String text, String expression, String portrait})>[];
  if (rawBeats is List) {
    for (final e in rawBeats) {
      if (e is! Map) continue;
      final m = Map<String, Object?>.from(e);
      // 「锚点」形态：模型只给这一拍**开头几个字**（startsWith），正文由我们按原文切。
      // agent 的输出量从此不再等于台词长度 —— 那才是它慢的原因（1000 字台词它也要
      // 重贴 1000 字）；而且它根本没有机会改动台词。整段 text 的老形态继续支持。
      final t = pick(m, [
        'text',
        'slice',
        'part',
        'quote',
        'startsWith',
        'anchor',
        'head',
      ]);
      if (t.isEmpty) continue;
      beats.add((
        text: t,
        expression: pick(m, ['expressionId', 'expression', 'emotion']),
        portrait: pick(m, ['portraitId', 'portrait']),
      ));
    }
  }

  final replies = <String>[];
  final rawReplies = map['suggestedReplies'] ?? map['replies'] ?? const [];
  if (rawReplies is List) {
    for (final r in rawReplies) {
      final s = '$r'.trim();
      if (s.isNotEmpty) replies.add(s);
      if (replies.length >= 3) break;
    }
  }

  // 先按「逐字拼回原文」判定；不行再试「按位置对齐」。
  // 真机日志里偶尔出现「节拍=2 重建失败」——模型只差一个括号或挪了标点，
  // 整条退回一张立绘太浪费；对齐之后用**原文自己的片段**切分，一个字都不改。
  var finalBeats = beats;
  var reconstructs = _reconstructs(beats, original);
  var aligned = false;
  {
    final fixed = _alignBeats(beats, original);
    if (fixed != null) {
      finalBeats = fixed;
      aligned = !reconstructs;
      reconstructs = true;
    } else {
      reconstructs = false;
    }
  }

  return LookPlanParse(
    LookPlan(
      replyLook: replyLook,
      beats: finalBeats,
      suggestedReplies: replies,
      reconstructs: reconstructs,
      aligned: aligned,
    ),
    cleaned,
    null,
  );
}

/// 节拍拼起来是否等于原文（忽略所有空白）。
///
/// 这是「agent 不许改台词」的守卫：只差几个空格可以接受，少字/多字/换词就不行。
bool _reconstructs(
  List<({String text, String expression, String portrait})> beats,
  String original,
) {
  if (beats.isEmpty) return false;
  final joined = _squash(beats.map((b) => b.text).join());
  final want = _squash(original);
  if (want.isEmpty) return false;
  return joined == want;
}

/// 按位置对齐：只要求每个节拍的文本能在原文里**按顺序找到**，然后用原文自己的
/// 片段（从上一个节拍边界到这一个节拍边界）作为切分结果。
///
/// 这样拼起来必然等于原文（首片从 0 起、末片切到结尾，中间的空档归给后一段），
/// 台词一个字都不会被改动或丢失；而每个节拍仍然带着模型给的表情/立绘。
/// 找不到（或顺序乱了）返回 null，由调用方退回「整条一张立绘」。
List<({String text, String expression, String portrait})>? _alignBeats(
  List<({String text, String expression, String portrait})> beats,
  String original,
) {
  if (beats.isEmpty || original.isEmpty) return null;
  // 找到每个节拍起点在原文里的位置（忽略空白地找：真机上模型常把换行丢了）。
  final starts = <int>[];
  var from = 0;
  for (final b in beats) {
    final match = _indexOfSquashed(original, b.text, from);
    if (match == null) return null;
    starts.add(match.start);
    from = match.end;
  }
  if (starts.first != 0) return null;
  final out = <({String text, String expression, String portrait})>[];
  for (var i = 0; i < beats.length; i++) {
    final end = i + 1 < beats.length ? starts[i + 1] : original.length;
    if (end <= starts[i]) return null;
    out.add((
      text: original.substring(starts[i], end),
      expression: beats[i].expression,
      portrait: beats[i].portrait,
    ));
  }
  return out;
}

/// 在 [from] 之后找 [needle]（两边都忽略空白），返回**原文里**的起始下标。
({int start, int end})? _indexOfSquashed(
    String haystack, String needle, int from) {
  final want = needle.replaceAll(RegExp(r'\s+'), '');
  if (want.isEmpty) return null;
  // 逐个候选起点试：把原文从 i 开始逐字符推进，遇到非空白字符才比对。
  for (var i = from; i < haystack.length; i++) {
    var h = i;
    var n = 0;
    while (n < want.length && h < haystack.length) {
      final hc = haystack[h];
      if (RegExp(r'\s').hasMatch(hc)) {
        h++;
        continue;
      }
      if (hc != want[n]) break;
      h++;
      n++;
    }
    if (n == want.length) return (start: i, end: h);
  }
  return null;
}

String _squash(String s) => s.replaceAll(RegExp(r'\s+'), '');

Object? _tryDecode(String? s) {
  if (s == null || s.isEmpty) return null;
  try {
    return jsonDecode(s);
  } catch (_) {
    return null;
  }
}

String _extractObject(String input) {
  final start = input.indexOf('{');
  if (start < 0) return '';
  var depth = 0;
  var inStr = false;
  var esc = false;
  for (var i = start; i < input.length; i++) {
    final c = input[i];
    if (inStr) {
      if (esc) {
        esc = false;
      } else if (c == r'\') {
        esc = true;
      } else if (c == '"') {
        inStr = false;
      }
      continue;
    }
    if (c == '"') {
      inStr = true;
    } else if (c == '{') {
      depth++;
    } else if (c == '}') {
      depth--;
      if (depth == 0) return input.substring(start, i + 1);
    }
  }
  return '';
}

/// 组装 agent 请求的提示词。
///
/// 词表来自内容包（本幕 state × 情绪），**只发给这个 agent**（§32）。
/// 聊天上下文不再注入同一张表。格式用 `【可用立绘】` / `【可用情绪】` +
/// 一行名字：离线 mock 靠这个表挑名字，真机上也方便模型照抄。
String buildLookPlanPrompt({
  required List<String> portraitOptions,
  required List<String> emotionOptions,
  required String replyText,
}) {
  final portrait = portraitOptions.isEmpty ? '' : portraitOptions.join('、');
  final emotion = emotionOptions.isEmpty ? '' : emotionOptions.join('、');
  return '''
你是立绘导演。任务只有两个：给下面这段角色台词挑**一张**最合适的立绘（含情绪），
再给玩家两条**这一句之后可以接的话**。不要改写台词、不要输出解释、**不要切节拍**。

【可用立绘】
$portrait
（portraitId 的唯一来源：逐字照抄，例如 "${portraitOptions.isEmpty ? '' : portraitOptions.first}"）
【可用情绪】
$emotion
（expressionId 的唯一来源：逐字照抄，例如 "${emotionOptions.isEmpty ? '' : emotionOptions.first}"）

要求：
- replyExpression / replyPortrait：这**整段**台词最合适的一个情绪与一张立绘。
- suggestedReplies：两条玩家视角的短话（每条 12 字以内，像玩家自己会说的话），
  贴着她这段话的语气走；不要写成旁白、动作说明或第三人物描写。
- **不要**把台词抄回来，也不要逐句标注 —— 每多写一个字，玩家就多等一截。

严格按下面这个字段顺序输出（客户端边收边用：先出表情立绘，再出推荐词）：
{"replyExpression":"${emotionOptions.isEmpty ? '' : emotionOptions.first}",
 "replyPortrait":"${portraitOptions.isEmpty ? '' : portraitOptions.first}",
 "suggestedReplies":["短选项1","短选项2"]}

台词原文：
$replyText''';
}

/// agent 流式输出里**新到位**的部分。
class LookPlanDelta {
  const LookPlanDelta({this.look, this.replies});

  /// 总立绘（`replyExpression` / `replyPortrait` 已闭合时给出）。
  final ({String expression, String portrait})? look;

  /// 快捷回复（`suggestedReplies` 数组已闭合时给出）。
  final List<String>? replies;

  bool get isEmpty => look == null && replies == null;
}

/// 边收边用：agent 的 JSON 一有字段闭合就立刻吐出来。
///
/// 为什么需要：agent 的字段顺序是「总立绘 → 快捷回复 → 节拍」，而占大头的节拍在最后
/// （逐拍标注）。等整段 JSON 收完再解析，等于让表情和快捷回复陪节拍一起等。
///
/// 只做**最保守**的提取：只认已经闭合的字符串与数组，认不出就什么都不吐，
/// 交给收流后的 [parseLookPlan] 兜底 —— 所以它不可能比原来更差。
///
/// 只认主字段名（`replyExpression` / `replyPortrait` / `suggestedReplies`）：
/// 段内字段（`expressionId` 等）会先于总立绘出现，别名留给收流后的完整解析去认，
/// 免得把某一拍的表情当成整条的总立绘先用上。
class LookPlanStream {
  final StringBuffer _buf = StringBuffer();
  bool _lookSent = false;
  bool _repliesSent = false;

  /// 吃一个增量，返回这次新到位的部分。
  LookPlanDelta feed(String delta) {
    if (delta.isEmpty) return const LookPlanDelta();
    _buf.write(delta);
    final text = _buf.toString();

    ({String expression, String portrait})? look;
    if (!_lookSent) {
      final expression = _closedString(text, 'replyExpression');
      final portrait = _closedString(text, 'replyPortrait');
      if (expression != null || portrait != null) {
        look = (expression: expression ?? '', portrait: portrait ?? '');
        _lookSent = true;
      }
    }

    List<String>? replies;
    if (!_repliesSent) {
      final list = _closedStringArray(text, 'suggestedReplies');
      if (list != null && list.isNotEmpty) {
        replies = list;
        _repliesSent = true;
      }
    }

    return LookPlanDelta(look: look, replies: replies);
  }
}

/// `"key":"已闭合的值"` → 值（支持转义引号）。还没闭合返回 null。
String? _closedString(String text, String key) {
  final m = RegExp(
    '"${RegExp.escape(key)}"\\s*:\\s*"((?:[^"\\\\]|\\\\.)*)"',
  ).firstMatch(text);
  if (m == null) return null;
  return _unescapeJsonString(m.group(1)!);
}

/// `"key":["a","b"]` → 元素列表。数组还没闭合返回 null。
List<String>? _closedStringArray(String text, String key) {
  final head = RegExp('"${RegExp.escape(key)}"\\s*:\\s*\\[').firstMatch(text);
  if (head == null) return null;
  final close = _matchingBracket(text, head.end - 1);
  if (close == null) return null; // 还没闭合
  final body = text.substring(head.end, close);
  return [
    for (final m in RegExp(r'"((?:[^"\\]|\\.)*)"').allMatches(body))
      _unescapeJsonString(m.group(1)!),
  ];
}

/// 从 `[` 的下标出发找配对的 `]`（跳过字符串与转义）。找不到返回 null。
int? _matchingBracket(String text, int openIndex) {
  var depth = 0;
  var inStr = false;
  var esc = false;
  for (var i = openIndex; i < text.length; i++) {
    final c = text[i];
    if (inStr) {
      if (esc) {
        esc = false;
      } else if (c == r'\') {
        esc = true;
      } else if (c == '"') {
        inStr = false;
      }
      continue;
    }
    if (c == '"') {
      inStr = true;
    } else if (c == '[') {
      depth++;
    } else if (c == ']') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return null;
}

/// JSON 字符串里的转义（`\"` `\\` `\n` `\uXXXX`…）还原成真正的字符。
String _unescapeJsonString(String raw) {
  if (!raw.contains(r'\')) return raw;
  try {
    final decoded = jsonDecode('"$raw"');
    return decoded is String ? decoded : raw;
  } catch (_) {
    return raw;
  }
}
