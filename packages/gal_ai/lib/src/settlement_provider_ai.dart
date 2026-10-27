import 'package:gal_protocol/gal_protocol.dart';

import 'dialogue_provider.dart';
import 'memory_provider.dart';
import 'provider_result.dart';
import 'settlement_evidence.dart';
import 'transition_coordinator.dart';

/// Real settlement: asks the configured model for integer deltas, using the
/// rule's judgePrompt plus the character's **short-term** memory of the scene.
///
/// Failure policy (never random):
/// * no JSON / unparseable → null → the caller treats it as "no evidence" (0)
/// * keys the rule does not declare → dropped, not fatal
class DialogueSettlementProvider implements SettlementProvider {
  const DialogueSettlementProvider(this.provider);

  final DialogueProvider provider;

  static const _system =
      '你是数值结算器。只输出 JSON，不要解释，不要加代码围栏。'
      '你没有权限修改任何数值，只提出整数增量建议，由引擎校验后落地。';

  @override
  Future<SettlementProposal?> propose({
    required String sessionId,
    required SceneDef scene,
    required WorldSnapshot world,
    required SettlementEvidence evidence,
  }) async {
    final blocks = scene.settlement;
    if (blocks.isEmpty) return null;
    // 无证据（只有开场白、玩家没说话）→ 不请求模型，直接零增量。
    // 否则模型可能在空证据下自行脑补非零值，破坏「只听不说话不涨值」。
    if (!evidence.hasContent) return null;
    final vars = [for (final b in blocks) b.varId];
    final keyList = vars.join('、');
    // 一次请求结算全部受控变量：每条块自己的说明单独列出来，
    // 这样「好感」和「服从」可以有不同的判定标准，而不是共用一句泛泛的说明。
    // 同时把每项的单次上限写进请求，让模型理解这一幕的评分尺度。
    final items = <String>[
      for (var i = 0; i < blocks.length; i++)
        '${i + 1}) ${blocks[i].varId}：${blocks[i].prompt.trim()}'
            '（单次绝对值上限 ${blocks[i].maxAbsDelta}）',
    ].join('\n');
    // 输出契约必须显式写出「外层是 deltas 对象」：解析器强制要求
    // `{"deltas": {...}}`。只写键名列表时，模型自然返回扁平
    // `{"戒戒好感":1}` 会被判解析失败，并在默认策略下按零增量继续推进。
    final exampleKeys = vars.isEmpty ? '变量名' : vars.first;
    final prompt = '【结算项】逐项判断，各项互不影响：\n$items\n\n'
        '${evidence.render()}\n'
        '没有明确证据的项一律给 0，不要猜、不要凑数。\n'
        '只允许使用这些键名，必须逐字照抄，不得翻译、不得增删：$keyList\n'
        '【输出格式】必须恰好是如下形状的 JSON 对象（外层键名必须是 deltas）：\n'
        '{"deltas": {"$exampleKeys": 0}}\n'
        '每个受控变量在 deltas 里出现一次；增量为整数，正值增加、负值减少、无证据为 0。\n'
        '只输出 JSON。';

    final res = await provider.generate(
      GenerateRequest(
        messages: [
          {'role': 'system', 'content': _system},
          {'role': 'user', 'content': prompt},
        ],
      ),
    );
    final raw = _textOf(res);
    final json = parseModelJsonObject(raw);
    if (json == null) return null;
    try {
      final parsed = SettlementProposal.fromJson(json);
      // D6: a hallucinated key must not abort the scene change — drop it.
      final filtered = <String, int>{};
      for (final e in parsed.deltas.entries) {
        if (vars.contains(e.key)) filtered[e.key] = e.value;
      }
      if (filtered.isEmpty) return null;
      return SettlementProposal(deltas: filtered);
    } catch (_) {
      // Parse/type failure → no evidence → keep original values.
      return null;
    }
  }

  String? _textOf(ProviderResult res) {
    final raw = res.rawText;
    if (raw != null && raw.trim().isNotEmpty) return raw;
    final segs = res.response?.segments ?? const [];
    if (segs.isEmpty) return null;
    return segs.map((s) => s.text).join('\n');
  }
}
