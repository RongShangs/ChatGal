import 'dart:convert';
import 'dart:developer' as dev;

import 'package:gal_protocol/gal_protocol.dart';

import 'dialogue_provider.dart';
import 'parse_ai_response.dart';
import 'provider_result.dart';

/// One keyword memory: a detail the character recalls **only when the current
/// input mentions one of its [keywords]**.
///
/// Keywords are a parallel channel, not a sixth layer: they never change
/// numbers, and the detail itself is not shown in the memory corridor —
/// only the trigger words are. 提取时机见 [MemoryProvider.extractKeywords]。
class KeywordMemory {
  const KeywordMemory({required this.keywords, required this.content});

  final List<String> keywords;

  /// 细节正文。**不进记忆回廊 UI**（那里只显示 [keywords]），只在关键词被
  /// 命中时用来唤起角色对这件事的认知。
  final String content;

  Map<String, Object?> toJson() => {'keywords': keywords, 'content': content};
}

/// Result of summarizing one L1 batch into an L2 fragment.
class FragmentResult {
  const FragmentResult({required this.summary});

  final String summary;
}

/// Produces memory text. Every method returns null on failure so the caller
/// **keeps the original text** (a failed summary must never destroy L1).
abstract class MemoryProvider {
  /// 最近一次失败的**具体原因**（HTTP 状态 / 错误信息 / 模型原文片段）。
  /// 界面会把它显示出来 —— 只说「整理失败」没法排查。
  String? get lastFailure;
  /// L1 (this scene's unprocessed rounds) → one L2 fragment.
  Future<FragmentResult?> summarizeFragment({
    required String owner,
    required List<DialogueTurn> turns,
    required String sceneId,
    required Map<String, Object?> facts,
  });

  /// 关键词记忆的提取点：**L2→L3 升层时**才调用（见 `MemoryRuntime.consolidate`）。
  ///
  /// 不在 L1→L2 提取：那里每一轮坍缩、每一次离场都会提一次，一场戏下来能攒
  /// 几十条（用户反馈「玩一会量就特别大」）。升到「经历」一层时再挑，候选是
  /// 已经沉淀过的摘要，条数更少、也更值得留。
  ///
  /// 没有值得记的细节时返回空列表（这不是失败，也不重试）。
  Future<List<KeywordMemory>> extractKeywords({
    required String owner,
    required List<MemoryEntry> batch,
  });

  /// Lift a batch of [fromLayer] entries into one entry of the next layer.
  Future<String?> aggregate({
    required String owner,
    required int fromLayer,
    required List<MemoryEntry> batch,
  });

  /// L5 maintenance: `add` | `merge` | `correct` | `keep`.
  ///
  /// [supersede] names the existing L5 entries this decision replaces (only
  /// meaningful for `merge` / `correct`) — the model points at them explicitly
  /// so the runtime never mass-supersedes core facts.
  Future<({String action, String text, List<String> supersede})?> reviewL5({
    required String owner,
    required List<MemoryEntry> batch,
    required List<MemoryEntry> currentL5,
  });

  /// L5 **自压缩**：把这几条长期核心记忆合并压短成一条，长度不超过
  /// [maxChars]（调用方传设置里的 L5 上限；不指定目标长度就没法保证压到线下）。
  /// 失败返回 null，原条目保持不动。
  Future<String?> compressL5({
    required String owner,
    required List<MemoryEntry> batch,
    required int maxChars,
  });
}

/// Offline / test provider: concatenates, never invents, never fails.
///
/// Used when no model is configured, and as the deterministic baseline in
/// tests. Keyword extraction is intentionally skipped — inventing keywords
/// without a model would be worse than having none.
class DeterministicMemoryProvider implements MemoryProvider {
  const DeterministicMemoryProvider({this.maxChars = 400});

  final int maxChars;

  /// 拼接式兜底永不失败，没有失败原因。
  @override
  String? get lastFailure => null;

  @override
  Future<FragmentResult?> summarizeFragment({
    required String owner,
    required List<DialogueTurn> turns,
    required String sceneId,
    required Map<String, Object?> facts,
  }) async {
    if (turns.isEmpty) return null;
    final body = turns.map((t) => t.plainText).join('\n');
    // 保留**尾部**：最新发生的才是最相关的，而且要和 AI 路径（`_capped` 取尾）
    // 一致 —— 取头部会让长场景只留下开场、丢掉高潮。
    final text =
        body.length <= maxChars ? body : body.substring(body.length - maxChars);
    return FragmentResult(summary: text);
  }

  /// 离线不编造关键词：没有模型时挑不出「被提到才想起来」的词，
  /// 硬凑只会让角色凭空想起没发生过的事。
  @override
  Future<List<KeywordMemory>> extractKeywords({
    required String owner,
    required List<MemoryEntry> batch,
  }) async =>
      const [];

  @override
  Future<String?> aggregate({
    required String owner,
    required int fromLayer,
    required List<MemoryEntry> batch,
  }) async {
    if (batch.isEmpty) return null;
    return batch.map((e) => e.text).join(' | ');
  }

  @override
  Future<({String action, String text, List<String> supersede})?> reviewL5({
    required String owner,
    required List<MemoryEntry> batch,
    required List<MemoryEntry> currentL5,
  }) async {
    // No model → no new core memory; "keep" is the honest answer
    // ("没有足够的新证据 → 保持").
    return (action: 'keep', text: '', supersede: const <String>[]);
  }

  @override
  Future<String?> compressL5({
    required String owner,
    required List<MemoryEntry> batch,
    required int maxChars,
  }) async {
    // 离线：只做确定性的「去重拼接 + 截断」，绝不编造。
    // 单条也要能压（这一条可能自己就超了上限），并且必须压到目标长度以内 ——
    // 否则「自压缩」跑完仍然超限，会每轮空转。
    if (batch.isEmpty) return null;
    final seen = <String>{};
    final parts = <String>[];
    for (final e in batch) {
      final t = e.text.trim();
      if (t.isEmpty || !seen.add(t)) continue;
      parts.add(t);
    }
    if (parts.isEmpty) return null;
    final joined = parts.join('；');
    final cap = maxChars < 1 ? 1 : maxChars;
    return joined.length <= cap ? joined : joined.substring(0, cap);
  }
}

/// Real provider over the configured dialogue model.
class DialogueMemoryProvider implements MemoryProvider {
  DialogueMemoryProvider(this.provider);

  final DialogueProvider provider;

  /// 最近一次失败的具体原因（给界面显示用）。
  String? _lastFailure;

  @override
  String? get lastFailure => _lastFailure;

  static const _system = '你是记忆整理器。只输出 JSON，不要解释，不要加代码围栏。';

  /// 第一次输出没法解析时，用这句再要一遍（最多一次格式修复请求）。
  static const _strictRetry =
      '上一次的输出无法解析。这一次严格只输出一个 JSON 对象：'
      '不要解释文字、不要代码围栏、不要在 JSON 前后写任何东西。';

  static const _maxPromptChars = 4000;

  String _capped(String s, [int max = _maxPromptChars]) =>
      s.length <= max ? s : s.substring(s.length - max);

  @override
  Future<FragmentResult?> summarizeFragment({
    required String owner,
    required List<DialogueTurn> turns,
    required String sceneId,
    required Map<String, Object?> facts,
  }) async {
    if (turns.isEmpty) return null;
    // 交互原文可能很长，截到一段够用的尾巴即可（提炼只需要近期细节）。
    final dialogue = _capped(turns.map((t) => t.plainText).join('\n'));
    final prompt = '把下面这段连续互动整理成一条**片段记忆**（L2）。\n'
        '要求：\n'
        '1. 保留具体细节——时间、场景、关键行为、对话结果、明确表达的感受或关系变化、'
        '约定与未完成事项；**不要**提前抽象成人格或性格判断。\n'
        '2. 这是给「$owner」自己记的，只写她知情的内容。\n'
        '3. summary 控制在 200 字以内。\n\n'
        '场景：$sceneId\n当前状态：$facts\n\n'
        '<互动>\n$dialogue\n</互动>\n\n'
        '只输出 JSON：{"summary":"…"}';
    final raw = await _ask(prompt, stricter: '$_strictRetry\n\n$prompt');
    final json = parseModelJsonObject(raw);
    if (json == null) return null;
    final summary = '${json['summary'] ?? ''}'.trim();
    if (summary.isEmpty) {
      _lastFailure = '输出里没有 summary 字段：${_snippet(raw, 120)}';
      return null;
    }
    return FragmentResult(summary: summary);
  }

  /// 关键词记忆：**L2→L3 升层时**才提取（见 `MemoryRuntime.consolidate`）。
  ///
  /// 输入是刚被「经历」吸收的那批片段摘要 —— 挑的是已经沉淀过的具体细节，
  /// 比在 L1→L2 时逐轮提取干净得多。
  @override
  Future<List<KeywordMemory>> extractKeywords({
    required String owner,
    required List<MemoryEntry> batch,
  }) async {
    if (batch.isEmpty) return const [];
    final body = batch.map((e) => '- ${e.text}').join('\n');
    final prompt = '从下面这几条片段记忆里，挑出「平时不必反复提起、'
        '但一旦被提到就必须想起来」的具体细节，作为「$owner」的关键词记忆。\n'
        '要求：\n'
        '1. 只要具体细节：物品的来历、具体地点、某次约定或承诺、'
        '只出现过一次但重要的名字。不要写性格判断，也不要写日常寒暄。\n'
        '2. 每条给 1~2 个**关键词**（那是将来触发它的词，'
        '尽量用正文里真会出现的说法），再给一句 content 说明这个细节。\n'
        '3. 最多 $_maxExtract 条；没有值得记的就返回空数组，不要硬凑。\n\n'
        '<片段记忆>\n$body\n</片段记忆>\n\n'
        '只输出 JSON：{"keywords":[{"keywords":["关键词"],"content":"细节"}]}';
    final raw = await _ask(prompt, stricter: '$_strictRetry\n\n$prompt');
    final json = parseModelJsonObject(raw);
    if (json == null) return const [];
    final rawKeywords = json['keywords'];
    if (rawKeywords is! List) return const [];
    final kws = <KeywordMemory>[];
    for (final k in rawKeywords) {
      if (kws.length >= _maxExtract) break;
      if (k is! Map) continue;
      final keys = (k['keywords'] as List? ?? const [])
          .map((e) => '$e'.trim())
          .where((e) => e.isNotEmpty)
          .take(2)
          .toList();
      final content = '${k['content'] ?? ''}'.trim();
      if (keys.isEmpty || content.isEmpty) continue;
      kws.add(KeywordMemory(keywords: keys, content: content));
    }
    return kws;
  }

  /// 一次提取最多留几条：关键词是稀有索引，堆多了全是噪音。
  static const _maxExtract = 2;

  @override
  Future<String?> aggregate({
    required String owner,
    required int fromLayer,
    required List<MemoryEntry> batch,
  }) async {
    if (batch.isEmpty) return null;
    final target = fromLayer + 1;
    final instruction = switch (fromLayer) {
      2 => '把这几条片段记忆整理成**一段经历**（L3）：发生了什么、起因经过结果、'
          '以及值得保留的影响。保留来源场景与日期范围，**不要**写成「每日总结」——'
          '跨天不是升层的理由。',
      3 => '从这几段经历里提炼**关系与行为趋势**（L4）：哪些相处方式、情绪模式、'
          '关系变化**反复出现**。必须能追溯到来源；只有一次的事不算趋势。'
          '证据不足就写「尚无稳定趋势」，**不要**为了填满层级而推断人格。',
      _ => '把这几条整理成一条长期核心记忆（L${target}）。',
    };
    final body = batch.map((e) => '- ${e.text}').join('\n');
    final prompt = '$instruction\n\n这是给「$owner」的。200 字以内。\n\n'
        '<待整理>\n$body\n</待整理>\n\n'
        '只输出 JSON：{"summary":"…"}';
    final raw = await _ask(prompt, stricter: '$_strictRetry\n\n$prompt');
    final json = parseModelJsonObject(raw);
    if (json == null) return null;
    final summary = '${json['summary'] ?? ''}'.trim();
    return summary.isEmpty ? null : summary;
  }

  @override
  Future<({String action, String text, List<String> supersede})?> reviewL5({
    required String owner,
    required List<MemoryEntry> batch,
    required List<MemoryEntry> currentL5,
  }) async {
    if (batch.isEmpty) return null;
    final l5 = currentL5.isEmpty
        ? '（还没有长期核心记忆）'
        : currentL5.map((e) => '- [${e.memId}] ${e.text}').join('\n');
    final l4 = batch.map((e) => '- ${e.text}').join('\n');
    final prompt =
        '维护「$owner」的**长期核心记忆（L5）**。现有核心记忆：\n$l5\n\n'
        '新提炼出的趋势（L4）：\n$l4\n\n'
        '选择动作：\n'
        '- add：出现了新的重要事实或稳定认知\n'
        '- merge：多条描述同一件事 → text 写合并后的内容，'
        '并在 supersede 里列出被合并掉的现有条目 id（形如 l5_xxx）\n'
        '- correct：新证据明确改变了旧认知 → text 写修正后的内容，'
        '并在 supersede 里列出被修正的条目 id\n'
        '- keep：没有足够的新证据（此时 text 留空、supersede 留空）\n\n'
        '不要删除核心事实；不确定就保持。\n'
        '只输出 JSON：{"action":"add|merge|correct|keep","text":"…","supersede":["l5_xxx"]}';
    final raw = await _ask(prompt, stricter: '$_strictRetry\n\n$prompt');
    final json = parseModelJsonObject(raw);
    if (json == null) return null;
    final action = '${json['action'] ?? 'keep'}'.trim();
    const allowed = {'add', 'merge', 'correct', 'keep'};
    if (!allowed.contains(action)) return null;
    final supersede = (json['supersede'] as List? ?? const [])
        .map((e) => '$e'.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    return (
      action: action,
      text: '${json['text'] ?? ''}'.trim(),
      supersede: supersede,
    );
  }

  @override
  Future<String?> compressL5({
    required String owner,
    required List<MemoryEntry> batch,
    required int maxChars,
  }) async {
    if (batch.isEmpty) return null;
    final body = batch.map((e) => '- ${e.text}').join('\n');
    final before = batch.fold<int>(0, (s, e) => s + e.text.length);
    final prompt = '把「$owner」下面这几条**长期核心记忆（L5）**压缩合并成一条。\n'
        '要求：\n'
        '1. 只保留仍然成立的核心事实（身份、稳定偏好、重大经历、承诺）。\n'
        '2. 去掉重复与细枝末节；**不要**新增任何没写过的内容，不要推测。\n'
        '3. 必须更短：原文共 $before 字，压缩后**控制在 $maxChars 字以内**。\n\n'
        '<待压缩>\n$body\n</待压缩>\n\n'
        '只输出 JSON：{"summary":"…"}';
    final raw = await _ask(prompt, stricter: '$_strictRetry\n\n$prompt');
    final json = parseModelJsonObject(raw);
    if (json == null) return null;
    final summary = '${json['summary'] ?? ''}'.trim();
    return summary.isEmpty ? null : summary;
  }

  Future<String?> _ask(String prompt, {String? stricter}) async {
    _lastFailure = null;
    var res = await _send(prompt);
    if (!res.ok) {
      // 请求层就失败了：把状态、错误与原始响应片段都留下
      // （空回复的原始响应体里有 finish_reason / usage，是唯一能定位的线索）
      final rawSnip = _snippet(res.rawText, 160);
      _lastFailure = '${_describe(res)}'
          '${res.rawText == null || res.rawText!.trim().isEmpty ? '' : '　原始响应：$rawSnip'}';
      dev.log('[memory] $_lastFailure');
    }
    var text = _textOf(res);
    if (extractJsonObject(text ?? '').isEmpty && stricter != null) {
      // 一次格式修复请求：上一轮输出没法解析时，用更硬的约束再要一遍。
      dev.log('[memory] 首次输出无法解析，重试一次：${_snippet(text)}');
      res = await _send(stricter);
      if (!res.ok) _lastFailure = _describe(res);
      text = _textOf(res);
    }
    if (extractJsonObject(text ?? '').isEmpty) {
      _lastFailure ??= '输出里找不到 JSON：${_snippet(text, 120)}';
      dev.log('[memory] 提炼失败，模型输出：${_snippet(text)}');
    }
    return text;
  }

  String _describe(ProviderResult res) =>
      '请求失败：${res.status.name}'
      '${res.error == null ? '' : '（${res.error}）'}';

  Future<ProviderResult> _send(String prompt) => provider.generate(
        GenerateRequest(
          messages: [
            {'role': 'system', 'content': _system},
            {'role': 'user', 'content': prompt},
          ],
          // 摘要本身很短，但如果模型是推理型的，额度会被思考吃掉、正文变空。
          // 给一个更大的输出额度，明显减少「空回复」。
          maxTokens: 4096,
        ),
      );

  String? _textOf(ProviderResult res) {
    final raw = res.rawText;
    if (raw != null && raw.trim().isNotEmpty) return raw;
    final segs = res.response?.segments ?? const [];
    if (segs.isEmpty) return null;
    return segs.map((s) => s.text).join('\n');
  }

  String _snippet(String? s, [int max = 200]) {
    if (s == null) return '(无返回内容)';
    final t = s.replaceAll('\n', ' ').trim();
    return t.length <= max ? t : '${t.substring(0, max)}…';
  }
}

/// Parse the first JSON object out of a model reply.
///
/// 容错三档，避免「模型其实给了摘要、却因为格式细节判失败」：
/// 1. 正常花括号配对提取（复用 `parse_ai_response.dart` 的提取器）
/// 2. 对象被截断（max_tokens 用尽 / 思维链太长）→ 补一个 `}` 再试
/// 3. 仍然不行 → 直接正则捞出 `"summary"` 的字符串值
///
/// 全部失败才返回 null —— 这时才该认为「模型没给出可用摘要」。
Map<String, Object?>? parseModelJsonObject(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  final slice = extractJsonObject(raw);
  if (slice.isNotEmpty) {
    final direct = _decodeObject(slice);
    if (direct != null) return direct;
    // 截断：补右括号再试一次
    final closed = _decodeObject('$slice}');
    if (closed != null) return closed;
  }
  final salvaged = _salvageString(raw, 'summary') ??
      _salvageString(raw, '摘要') ??
      _salvageString(raw, 'text');
  if (salvaged != null && salvaged.trim().isNotEmpty) {
    return {'summary': salvaged.trim()};
  }
  return null;
}

Map<String, Object?>? _decodeObject(String s) {
  try {
    final decoded = jsonDecode(s);
    if (decoded is Map) return Map<String, Object?>.from(decoded);
  } catch (_) {}
  return null;
}

/// 从（可能被截断/夹在散文里的）文本里直接取出某个字符串值。
String? _salvageString(String raw, String key) {
  final m = RegExp('"$key"\\s*:\\s*"((?:[^"\\\\]|\\\\.)*)"').firstMatch(raw);
  final v = m?.group(1);
  if (v != null) return _unescape(v);
  // 截断正好落在字符串中间（连收尾引号都没有）：把剩下的文本当摘要。
  final open = RegExp('"$key"\\s*:\\s*"').firstMatch(raw);
  if (open == null) return null;
  var rest = raw.substring(open.end);
  final cut = rest.indexOf('",');
  if (cut >= 0) rest = rest.substring(0, cut);
  final tail = _unescape(rest.trim());
  // 太短就当成失败，别把半个字段名当记忆存进去
  return tail.length >= 8 ? tail : null;
}

String _unescape(String v) => v
    .replaceAll(r'\n', '\n')
    .replaceAll(r'\"', '"')
    .replaceAll(r'\\', r'\');
