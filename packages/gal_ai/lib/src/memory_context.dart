import 'package:gal_protocol/gal_protocol.dart';

/// Token-budgeted context assembly with audience filter and per-layer budgets.
///
/// Order (fixed):
///   1 protocolShell → 2 角色提示词 → 3 【场景】 → 4 【世界事实】
///   → 5 【记忆 L5/L4/L3/L2】 → 6 【L1 活跃窗口】 → 7 【潜意识触动】
///
/// Two rules that matter:
/// * **L1 is the active window, not the chat log.** Rounds that already
///   collapsed out of it are simply not sent any more; the full transcript
///   still lives in the save's message checkpoint.
/// * **Never throw.** The fixed prefix (protocol + prompts + scene + facts)
///   is emitted even when it alone exceeds the budget; optional layers are then
///   dropped from the lowest priority up (keywords → L1 → L2 …).
class MemoryContextAssembler {
  const MemoryContextAssembler({
    this.approxCharsPerToken = 2,
    this.maxTokens = 3000,
    this.replyReserve = 200,
    this.layerBudgets = const {5: 320, 4: 280, 3: 240, 2: 240},
    this.l1Budget = 900,
    this.keywordBudget = 200,
    this.keywordLimit = 12,
  });

  final int approxCharsPerToken;
  final int maxTokens;
  final int replyReserve;

  /// Per-layer caps (each layer has its own budget, R28).
  final Map<int, int> layerBudgets;

  /// Cap for the L1 active window.
  final int l1Budget;

  /// Cap for the keyword (潜意识触动) block.
  final int keywordBudget;
  final int keywordLimit;

  int estimateTokens(String s) =>
      (s.length / approxCharsPerToken).ceil().clamp(1, 1 << 20);

  /// Build messages for one character speaker.
  ///
  /// [authorityFacts] must already be audience-filtered for this character.
  /// [tree] is that character's memory tree; [activeTurns] its L1 window.
  /// [messages] is only a fallback when no window is available.
  List<Map<String, String>> assemble({
    required String protocolShell,
    required String basePrompt,
    String phasePrompt = '',
    String scenePrompt = '',
    String? characterScenePrompt,
    required String authorityFacts,
    required CharacterMemoryTree tree,
    List<Map<String, Object?>> messages = const [],
    List<DialogueTurn> activeTurns = const [],
    String? currentUserInput,
    // Set false to omit the L1 window entirely (settlement-style prompts).
    bool includeWindow = true,
  }) {
    final out = <Map<String, String>>[];

    // --- fixed prefix: always emitted, never silently dropped -------------
    out.add({'role': 'system', 'content': protocolShell});
    out.add({
      'role': 'system',
      'content': [basePrompt, phasePrompt]
          .where((s) => s.trim().isNotEmpty)
          .join('\n'),
    });
    final sceneParts = [scenePrompt, characterScenePrompt ?? '']
        .where((s) => s.trim().isNotEmpty)
        .join('\n');
    if (sceneParts.isNotEmpty) {
      out.add({'role': 'system', 'content': '【场景】\n$sceneParts'});
    }
    if (authorityFacts.trim().isNotEmpty) {
      out.add({'role': 'system', 'content': '【世界事实】\n$authorityFacts'});
    }
    // §32：聊天只写台词，不再注入【可用立绘】/【可用情绪】。
    // 词表仍来自内容包，但**只**发给立绘 agent（buildLookPlanPrompt）。
    // 旧路径要求聊天模型逐字回 portraitId，会把它推回「努力吐 JSON」并浪费 token。

    var reserve = estimateTokens(protocolShell) +
        estimateTokens(basePrompt) +
        estimateTokens(phasePrompt) +
        estimateTokens(scenePrompt) +
        estimateTokens(characterScenePrompt ?? '') +
        estimateTokens(authorityFacts) +
        estimateTokens(currentUserInput ?? '') +
        replyReserve;

    // Degrade instead of throwing: the fixed prefix wins, memory is optional.
    var budget = maxTokens - reserve;
    if (budget < 0) budget = 0;

    /// 逐**条**裁剪的层注入：装不下就丢最旧的那几条，而不是整层不发。
    ///
    /// 以前是「整块算 token，超预算就整层丢掉」—— L5 一旦超过该层预算，
    /// 核心记忆会**一条都进不了上下文**，这比不注入更糟。
    /// 现在按条降级：最新一条装不下时**跳过它**继续看较短的旧条，
    /// 而不是直接 break 导致较短旧记忆也不再注入。
    void addLayer(String header, List<String> lines, int cap) {
      if (budget <= 0 || lines.isEmpty) return;
      final kept = <String>[];
      var used = 0;
      // 从最新往旧走；装不下的单条跳过（不是 break），
      // 这样较短的旧记忆仍有机会进入上下文。
      for (var i = lines.length - 1; i >= 0; i--) {
        final cost = estimateTokens('${lines[i]}\n');
        if (used + cost > cap || used + cost > budget) continue;
        used += cost;
        kept.insert(0, lines[i]);
      }
      if (kept.isEmpty) return;
      budget -= used;
      out.add({'role': 'system', 'content': '$header\n${kept.join('\n')}'});
    }

    // --- 5. higher layers, high priority first --------------------------
    for (final layer in [5, 4, 3, 2]) {
      final list = tree.injectable(layer);
      if (list.isEmpty) continue;
      var lines = [for (final e in list) '- ${e.text}'];
      if (layer == 5) {
        // L5 额外受设置里的**字数上限**约束（自压缩的兜底：压缩没跑成功时，
        // 注入侧也不能把整棵树灌进上下文）。保留最新的若干条。
        // 单条超限的直接跳过（不是 break）：否则最新一条特别长时，
        // 较短的旧条目还没进入选择就被排除了。
        final cap = tree.thresholds.l5MaxChars;
        final trimmed = <String>[];
        var chars = 0;
        for (var i = lines.length - 1; i >= 0; i--) {
          if (lines[i].length > cap) continue; // 单条就超限，跳过
          if (chars + lines[i].length > cap) continue;
          chars += lines[i].length;
          trimmed.insert(0, lines[i]);
        }
        lines = trimmed;
      }
      addLayer('【记忆 L$layer】', lines, layerBudgets[layer] ?? 240);
    }

    // --- 6. L1 active window -------------------------------------------
    if (includeWindow) {
      final turns = activeTurns.isNotEmpty
          ? activeTurns.where((t) => t.visibleTo(tree.owner)).toList()
          : _turnsFromMessages(messages, tree);
      // 按**完整回合**裁剪：一轮 = 玩家一句 + 角色一句（开场白可能只有角色）。
      // 以前按单条消息裁，会把一轮拆散（只剩玩家半句或只剩角色半句）。
      final kept = <List<({String role, String content})>>[];
      var spent = 0;
      for (var i = turns.length - 1; i >= 0; i--) {
        final msgs = _msgsOfTurn(turns[i]);
        if (msgs.isEmpty) continue;
        var cost = 0;
        for (final m in msgs) {
          cost += estimateTokens(m.content);
        }
        if (spent + cost > l1Budget || spent + cost > budget) continue;
        spent += cost;
        kept.insert(0, msgs);
      }
      if (spent > 0) {
        budget -= spent;
        for (final turnMsgs in kept) {
          for (final t in turnMsgs) {
            out.add({'role': t.role, 'content': t.content});
          }
        }
      }
    }

    // --- 7. keyword hits (per-entry, not whole-block) --------------------
    final probe = _probe(activeTurns, out, currentUserInput);
    final hits = <String>[];
    for (final ev in tree.keywordEvents.reversed) {
      if (!_keywordVisible(ev, tree.owner)) continue;
      final keys = (ev['keywords'] as List? ?? const []).map((e) => '$e');
      if (!keys.any((k) => k.isNotEmpty && probe.contains(k))) continue;
      final content = '${ev['content'] ?? ''}';
      if (content.isEmpty || hits.contains(content)) continue;
      hits.add(content);
      if (hits.length >= keywordLimit) break;
    }
    // 按条注入而不是整块：以前 join 成一块再 addBlock，超预算会整块丢弃
    // —— 几条命中里只要有一条特别长，其余短的也进不了上下文。
    // 同时累计 keywordBudget：多条命中不能突破关键词专属预算。
    if (hits.isNotEmpty && budget > 0) {
      out.add({'role': 'system', 'content': '【潜意识触动】'});
      var keywordSpent = 0;
      for (final hit in hits) {
        final cost = estimateTokens('- $hit\n');
        if (cost > keywordBudget || keywordSpent + cost > keywordBudget) continue;
        if (cost > budget) continue;
        budget -= cost;
        keywordSpent += cost;
        out.add({'role': 'system', 'content': '- $hit'});
      }
    }

    // 这里**不再**追加「输出格式」块：聊天请求已经改成只写台词（不要求 JSON），
    // 立绘与情绪节拍交给常驻的立绘 agent（`look_agent.dart`）。提示越短越不容易漂。
    return out;
  }

  /// 一轮的 0~2 条消息（开场白可能只有 assistant）。
  List<({String role, String content})> _msgsOfTurn(DialogueTurn t) {
    final out = <({String role, String content})>[];
    // 开场白那一轮没有玩家输入：不要发一条空的 user 消息，模型会以为
    // 玩家说了「什么都没有」，还会把空消息算进上下文预算。
    if (t.playerText.trim().isNotEmpty) {
      out.add((role: 'user', content: t.playerText));
    }
    if (t.replyText.trim().isNotEmpty) {
      out.add((role: 'assistant', content: t.replyText));
    }
    return out;
  }

  /// 无 L1 窗口时的兜底：从消息表重建「近似回合」（按 turnId 分组）。
  List<DialogueTurn> _turnsFromMessages(
    List<Map<String, Object?>> messages,
    CharacterMemoryTree tree,
  ) {
    final processed = tree.processed.expand((p) => p.turnIds).toSet();
    final byTurn = <String, List<Map<String, Object?>>>{};
    for (final m in messages) {
      if (m['is_system'] == true) continue;
      final turnId = '${m['turnId'] ?? ''}';
      if (turnId.isNotEmpty && processed.contains(turnId)) continue;
      final aud = m['audience'];
      if (aud is List && aud.isNotEmpty && !aud.contains(tree.owner)) continue;
      byTurn.putIfAbsent(turnId.isEmpty ? 'anon' : turnId, () => []).add(m);
    }
    final out = <DialogueTurn>[];
    byTurn.forEach((turnId, msgs) {
      final player = <String>[];
      final reply = <String>[];
      for (final m in msgs) {
        final text = '${m['content'] ?? ''}'.trim();
        if (text.isEmpty) continue;
        if (m['role'] == 'user') {
          player.add(text);
        } else if (m['role'] == 'assistant') {
          reply.add(text);
        }
      }
      if (player.isEmpty && reply.isEmpty) return;
      out.add(
        DialogueTurn(
          turnId: turnId,
          playerText: player.join('\n'),
          replyText: reply.join('\n'),
          audience: [tree.owner],
          storyId: '${msgs.first['storyId'] ?? ''}',
          visitId: (msgs.first['visitId'] as num?)?.toInt() ?? 0,
          at: DateTime.now(),
        ),
      );
    });
    return out;
  }

  String _probe(
    List<DialogueTurn> turns,
    List<Map<String, String>> blocks,
    String? currentUserInput,
  ) {
    final buf = StringBuffer()..write(currentUserInput ?? '');
    // recently visible dialogue: the tail of the window
    for (final t in turns.length <= keywordLimit
        ? turns
        : turns.sublist(turns.length - keywordLimit)) {
      buf..write(t.playerText)..write(t.replyText);
    }
    if (turns.isEmpty) {
      for (final b in blocks.reversed.take(4)) {
        buf.write(b['content'] ?? '');
      }
    }
    return buf.toString();
  }

  bool _keywordVisible(Map<String, Object?> ev, String owner) {
    final aud = (ev['audience'] as List? ?? const []).map((e) => '$e').toList();
    if (aud.isEmpty) return true;
    return aud.contains(owner);
  }
}
