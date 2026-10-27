import 'dart:developer' as dev;

import 'package:gal_protocol/gal_protocol.dart';

import 'memory_provider.dart';
import 'settlement_evidence.dart';

/// A planned L1→L2 collapse: the provider text is already produced, but the
/// window has **not** been touched yet. Commit only after the surrounding
/// transaction is safe — a failed summary must leave the original text alone.
class MemoryCollapse {
  const MemoryCollapse({
    required this.owner,
    required this.rounds,
    required this.entry,
    this.storyId = '',
    this.visitId = 0,
    this.failure,
    this.usedFallback = false,
    this.fallbackReason,
  });

  final String owner;
  final List<DialogueTurn> rounds;
  final MemoryEntry? entry;
  final String storyId;
  final int visitId;

  /// 提炼没成功时的原因（给玩家看的），成功时为 null。
  final String? failure;

  /// 模型没给出可用摘要、L2 里记的是**原文拼接**（见 [_plan] 的兜底分支）。
  final bool usedFallback;

  /// 走兜底时的原因（超时/报错/输出无法解析），没走兜底时为 null。
  /// 界面用它说明「为什么这条 L2 是原文」。
  final String? fallbackReason;

  bool get isEmpty => rounds.isEmpty || entry == null;
}

/// Memory math for one session: the auto-collapse transaction, the leave-path
/// summary, and the **decoupled** higher-layer consolidation.
///
/// Two things this class deliberately keeps apart:
/// * L1→L2 (this scene's rounds) — part of leaving a scene, and part of the
///   in-session threshold collapse.
/// * L2→L3→L4→L5 — driven purely by thresholds; it is **not** on the scene
///   change critical path, so switching scenes stays fast.
///
/// 阈值不再由本类持有：唯一来源是 `bank.thresholds`（来自游戏外设置，
/// 存档不保存），避免「一部分层按新阈值、另一部分按旧阈值」。
class MemoryRuntime {
  MemoryRuntime({required this.provider});

  final MemoryProvider provider;

  // ---------------------------------------------------------------- collapse

  /// Plan the collapse of **one scene visit's** unprocessed rounds (leave path).
  Future<MemoryCollapse?> planSceneSummary({
    required MemoryBank bank,
    required String owner,
    required String storyId,
    required int visitId,
    required Map<String, Object?> facts,
  }) async {
    final window = bank.windowIfExists(owner);
    if (window == null) return null;
    final tree = bank.treeOf(owner);
    // 换场景时把 L1 **整个**整理清空（不限本幕）：否则下一幕还会被上一幕的
    // 原始对话影响，上一幕的现场感会漏进新场景。
    final rounds = window.turns.where((t) => t.visibleTo(owner)).toList();
    if (rounds.isEmpty) return null;
    // 按**轮次**而不是按 (storyId, visitId) 判断「整理过没有」：域内自动坍缩
    // 已经记过一次本幕的 processed，如果这里只看 (storyId, visitId)，本幕
    // 剩下的 L1 就会被判成「已整理」而原样串到下一幕。
    final done = tree.processed.expand((p) => p.turnIds).toSet();
    final fresh = rounds.where((t) => !done.contains(t.turnId)).toList();
    if (fresh.isEmpty) return null;
    return _plan(
      bank: bank,
      owner: owner,
      rounds: fresh,
      storyId: storyId,
      visitId: visitId,
      facts: facts,
    );
  }

  /// Plan the collapse of the oldest batch once the window reached the
  /// threshold (in-session auto-collapse).
  Future<MemoryCollapse?> planThresholdCollapse({
    required MemoryBank bank,
    required String owner,
    required Map<String, Object?> facts,
  }) async {
    final window = bank.windowIfExists(owner);
    if (window == null) return null;
    final batch = window.pendingBatch();
    if (batch.isEmpty) return null;
    return _plan(
      bank: bank,
      owner: owner,
      rounds: batch,
      storyId: batch.first.storyId,
      visitId: batch.first.visitId,
      facts: facts,
    );
  }

  Future<MemoryCollapse?> _plan({
    required MemoryBank bank,
    required String owner,
    required List<DialogueTurn> rounds,
    required String storyId,
    required int visitId,
    required Map<String, Object?> facts,
  }) async {
    final result = await provider.summarizeFragment(
      owner: owner,
      turns: rounds,
      sceneId: storyId,
      facts: facts,
    );
    var summary = result?.summary.trim() ?? '';
    var usedFallback = false;
    String? fallbackReason;
    if (summary.isEmpty) {
      // 兜底：模型没给出可用摘要时用**确定性拼接**把原文压进来。
      // 宁可记下一段朴素的原话，也不能因为一次请求失败就卡住换场，
      // 更不能把这段对话静默丢掉。
      final fb = await const DeterministicMemoryProvider().summarizeFragment(
        owner: owner,
        turns: rounds,
        sceneId: storyId,
        facts: facts,
      );
      summary = fb?.summary.trim() ?? '';
      usedFallback = true;
      fallbackReason = provider.lastFailure ?? '模型没有返回可解析的摘要';
      dev.log('[memory] 提炼失败（$fallbackReason）→ 用确定性拼接兜底');
    }
    if (summary.isEmpty) {
      // 连拼接都拿不到内容（极端情况）：仍然拒绝换场、保留原文。
      return MemoryCollapse(
        owner: owner,
        rounds: rounds,
        entry: null,
        storyId: storyId,
        visitId: visitId,
        failure: provider.lastFailure ?? '模型没有返回可解析的摘要',
      );
    }
    final entry = MemoryEntry(
      memId: 'l2_${owner}_${storyId}_v${visitId}_${rounds.first.turnId}',
      layer: 2,
      owner: owner,
      text: summary,
      // 该幕在场的角色：与 L1 轮次同一套 audience 语义，多角色时才知道
      // 这条片段记忆「谁在场、谁知道」。
      audience: _audienceOf(rounds, owner),
      createdAt: DateTime.now(),
      source: {
        'kind': usedFallback ? 'l1_to_l2_fallback' : 'l1_to_l2',
        'storyId': storyId,
        'visitId': visitId,
        'turnIds': rounds.map((t) => t.turnId).toList(),
      },
      sourceScenes: _scenesOf(rounds, storyId, visitId),
      // 只要批里有任何一轮玩家说过话，这条摘要就算有真实交互。
      // 纯开场白批的摘要不应被当成结算证据。
      hasPlayerInteraction: rounds.any((t) => t.playerText.trim().isNotEmpty),
    );
    return MemoryCollapse(
      owner: owner,
      rounds: rounds,
      entry: entry,
      storyId: storyId,
      visitId: visitId,
      usedFallback: usedFallback,
      fallbackReason: fallbackReason,
    );
  }

  /// 这批轮次真正来源的场景集合（通常只有一个）。跨幕的轮次被一起压成一条时，
  /// 来源场景必须如实记全，否则结算证据按 sourceScenes 匹配会张冠李戴。
  static List<Map<String, Object?>> _scenesOf(
    List<DialogueTurn> rounds,
    String storyId,
    int visitId,
  ) {
    final out = <Map<String, Object?>>[];
    final seen = <String>{};
    for (final t in rounds) {
      final sid = t.storyId.isEmpty ? storyId : t.storyId;
      final key = '$sid#${t.visitId}';
      if (!seen.add(key)) continue;
      out.add({'storyId': sid, 'visitId': t.visitId});
    }
    if (out.isEmpty) out.add({'storyId': storyId, 'visitId': visitId});
    return out;
  }

  /// 这一批轮次的并集受众（至少含 [owner]）。
  static List<String> _audienceOf(List<DialogueTurn> rounds, String owner) {
    final seen = <String>{owner};
    for (final r in rounds) {
      seen.addAll(r.audience.where((e) => e.isNotEmpty));
    }
    return seen.toList();
  }

  /// Apply a planned collapse: add the L2 entry + keyword memories, then drop
  /// exactly those rounds from the L1 window, and record the processed range.
  /// Returns false when the plan carried no summary (so nothing moved).
  bool commitCollapse(MemoryBank bank, MemoryCollapse collapse) {
    final entry = collapse.entry;
    if (entry == null) return false;
    final tree = bank.treeOf(collapse.owner);
    if (tree.layerList(2).any((e) => e.memId == entry.memId)) {
      // Already committed (retry/replay): just drop the rounds, don't duplicate.
      _dropRounds(bank, collapse);
      return false;
    }
    tree.add(entry);
    // 关键词记忆**不在这里**提取：L1→L2 每轮坍缩、每次离场都会走到这里，
    // 一场戏就能攒几十条（用户反馈「玩一会量就特别大」）。改到 L2→L3 升层时
    // 统一挑，见 consolidate 里的 _extractKeywords。
    _dropRounds(bank, collapse);
    // 一次离场会清空整个窗口（见 planSceneSummary），窗里可能还留着**上一幕**
    // 没坍缩完的轮次。逐幕记 processed，别把跨幕轮次全算在当前幕头上 ——
    // 否则结算证据/来源场景匹配（sourceScenes）会失真。
    final byScene = <String, List<DialogueTurn>>{};
    for (final t in collapse.rounds) {
      final key = '${t.storyId}\u0000${t.visitId}';
      byScene.putIfAbsent(key, () => <DialogueTurn>[]).add(t);
    }
    byScene.forEach((key, rounds) {
      final parts = key.split('\u0000');
      final storyId = parts.isNotEmpty ? parts[0] : collapse.storyId;
      final visitId = parts.length > 1
          ? int.tryParse(parts[1]) ?? collapse.visitId
          : collapse.visitId;
      if (storyId.isEmpty) return;
      tree.processed.add(
        ProcessedRange(
          charId: collapse.owner,
          storyId: storyId,
          visitId: visitId,
          fromMsgId: rounds.first.turnId,
          toMsgId: rounds.last.turnId,
          turnIds: rounds.map((t) => t.turnId).toList(),
          producedMemIds: [entry.memId],
        ),
      );
    });
    return true;
  }

  /// 本幕**不留记忆**：把窗口里该 owner 的轮次直接丢掉，并按幕登记 processed
  /// （防止它们再被当成"待整理"）。原文仍在存档的 messageCheckpoint 里 ——
  /// 这不是删除聊天记录，而是「角色不记得这一幕」（梦境/非正史幕）。
  void forgetSceneWindow({
    required MemoryBank bank,
    required String owner,
    required String storyId,
    required int visitId,
  }) {
    final window = bank.windowIfExists(owner);
    if (window == null) return;
    final tree = bank.treeOf(owner);
    final done = tree.processed.expand((p) => p.turnIds).toSet();
    final rounds = window.turns
        .where((t) => t.visibleTo(owner) && !done.contains(t.turnId))
        .toList();
    if (rounds.isEmpty) return;
    final byScene = <String, List<DialogueTurn>>{};
    for (final t in rounds) {
      byScene.putIfAbsent('${t.storyId}#${t.visitId}', () => []).add(t);
    }
    byScene.forEach((key, group) {
      final at = key.lastIndexOf('#');
      final sid = at > 0 ? key.substring(0, at) : storyId;
      final vid =
          at > 0 ? int.tryParse(key.substring(at + 1)) ?? visitId : visitId;
      tree.processed.add(
        ProcessedRange(
          charId: owner,
          storyId: sid.isEmpty ? storyId : sid,
          visitId: vid,
          fromMsgId: group.first.turnId,
          toMsgId: group.last.turnId,
          turnIds: group.map((t) => t.turnId).toList(),
          producedMemIds: const [],
        ),
      );
    });
    final ids = rounds.map((t) => t.turnId).toSet();
    window.turns.removeWhere((t) => ids.contains(t.turnId));
  }

  void _dropRounds(MemoryBank bank, MemoryCollapse collapse) {
    final window = bank.windowIfExists(collapse.owner);
    if (window == null) return;
    final ids = collapse.rounds.map((t) => t.turnId).toSet();
    window.turns.removeWhere((t) => ids.contains(t.turnId));
  }

  // ------------------------------------------------------------- consolidate

  /// Threshold-driven L2→L3→L4→L5. Runs **outside** the scene-leave critical
  /// path. Idempotent: a lift whose target id already exists is skipped.
  Future<bool> consolidate(
    MemoryBank bank,
    String owner, {
    bool Function()? isCurrent,
  }) async {
    final tree = bank.treeOf(owner);
    // 换幕可以废弃后台结果而不等待模型。每次 await 后重新检查所有权，
    // 避免提交到已被事务快照替换的树，或覆盖另一任务已处理的批次。
    bool current() =>
        identical(bank.treeIfExists(owner), tree) &&
        (isCurrent?.call() ?? true);
    // 阈值的唯一来源（来自游戏外设置）。树的阈值由 applyThresholds 同步，
    // 这里显式用 bank 的，彻底消掉「两个来源」。
    final thresholds = bank.thresholds;
    var changed = false;
    // 关键词是否在本次调用里达到了「该整理」的时刻（L2→L3 成功升层）
    var liftedToL3 = false;

    for (final from in [2, 3]) {
      final count = from == 2 ? thresholds.l2LiftCount : thresholds.l3LiftCount;
      final batchSize =
          from == 2 ? thresholds.l2LiftBatch : thresholds.l3LiftBatch;
      // 阈值来自玩家可改的设置：非正值会让 `pending.sublist(0, 0)` 取到空批、
      // `batch.first` 直接崩，也会让 while 条件恒真。这里先挡住。
      if (count <= 0 || batchSize <= 0) continue;
      while (
          tree.layerList(from).where((e) => e.isPendingLift).length >= count) {
        final pending =
            tree.layerList(from).where((e) => e.isPendingLift).toList();
        final batch = pending.sublist(0, batchSize);
        if (batch.isEmpty) break;
        final targetId = 'l${from + 1}_${batch.first.memId}';
        if (tree.layerList(from + 1).any((e) => e.memId == targetId)) {
          // Already lifted on a previous attempt — stamp and move on.
          _stamp(tree, from, batch, targetId);
          changed = true;
          continue;
        }
        final text = await provider.aggregate(
          owner: owner,
          fromLayer: from,
          batch: batch,
        );
        if (!current()) return changed;
        if (batch.any((e) => !tree.layerList(from).contains(e)) ||
            tree.layerList(from + 1).any((e) => e.memId == targetId)) {
          continue;
        }
        if (text == null || text.trim().isEmpty)
          break; // keep batch, retry later
        tree.add(
          MemoryEntry(
            memId: targetId,
            layer: from + 1,
            owner: owner,
            text: text,
            audience: [owner],
            createdAt: DateTime.now(),
            source: {'kind': 'cascade', 'fromLayer': from},
            sourceMemIds: batch.map((e) => e.memId).toList(),
            sourceScenes: batch.expand((e) => e.sourceScenes).toList(),
            hasPlayerInteraction: batch.any((e) => e.hasPlayerInteraction),
          ),
        );
        _stamp(tree, from, batch, targetId);
        changed = true;
        if (from == 2) {
          liftedToL3 = true;
          // 这一批刚从「片段」升成「经历」：正是挑关键词记忆的时刻。
          if (await _extractKeywords(bank, owner, batch, current)) {
            changed = true;
          }
        }
      }
    }

    // L4 → L5 review.
    while (tree.pendingL5Review().isNotEmpty) {
      final batch = tree.pendingL5Review();
      final decision = await provider.reviewL5(
        owner: owner,
        batch: batch,
        currentL5: tree.injectable(5),
      );
      if (!current()) return changed;
      if (batch.any((e) => !tree.pendingL5Review().contains(e))) continue;
      if (decision == null) break; // keep batch, retry later
      final updateId = 'l5_${decision.action}_${batch.first.memId}';
      final already = decision.action != 'keep' &&
          tree.layerList(5).any((e) => e.memId == updateId);
      if (!already) {
        tree.applyL5Review(
          action: decision.action,
          batch: batch,
          text: decision.text,
          // Only the entries the model named — never mass-supersede core facts.
          supersedeL5Ids: decision.supersede,
          updateId: updateId,
        );
      } else {
        tree.applyL5Review(
          action: 'keep',
          batch: batch,
          updateId: updateId,
        );
      }
      changed = true;
    }

    // 关键词记忆同样是**在 L2→L3 这一刻**处理：刚刚就地提取过一批，正好
    // 合并同主题、超限丢最旧。另外留一个硬上限兜底：条数超过两倍上限说明
    // 已经堆成噪音（旧档 / 离线路径），也整理一次。
    final kwMax = thresholds.l3KeywordMax;
    if (liftedToL3 || tree.keywordEvents.length > kwMax * 2) {
      if (tree.consolidateKeywords(kwMax)) changed = true;
    }

    // L5 **自压缩**：超过设置的上下文上限就把最旧的几条合并成一条。
    // 每次 consolidate 只尝试一次（失败就等下一轮），避免对着同一个失败
    // 反复打请求。
    if (tree.l5Chars > thresholds.l5MaxChars) {
      final live = tree
          .layerList(5)
          .where((e) => e.isActive && e.aggregatedInto == null)
          .toList();
      // 单条也能压（它自己就可能超上限）：合并结果是一条**新**条目，
      // 原来的会被标成已取代，所以不会出现"压没了"的情况。
      if (live.isNotEmpty) {
        final take = thresholds.l5CompressBatch < live.length
            ? thresholds.l5CompressBatch
            : live.length;
        final batch = live.sublist(0, take);
        final before = batch.fold<int>(0, (s, e) => s + e.text.length);
        final text = await provider.compressL5(
          owner: owner,
          batch: batch,
          maxChars: thresholds.l5MaxChars,
        );
        if (!current()) return changed;
        if (batch.any((e) => !tree.layerList(5).contains(e))) return changed;
        // 只有真的变短才落地：否则“自压缩”可能越压越长、每轮重试。
        if (text != null &&
            text.trim().isNotEmpty &&
            text.trim().length < before) {
          tree.compressL5(
            batch: batch,
            text: text.trim(),
            updateId: 'l5c_${batch.first.memId}',
          );
          changed = true;
        }
      }
    }
    return changed;
  }

  /// 关键词记忆的提取：**只在 L2→L3 升层成功时**调用。
  ///
  /// 写进 [bank] 里该 owner 自己的那份（每个角色一套，互不可见）。空结果与
  /// 失败都只是「这次没挑出值得记的细节」，不影响升层本身。
  Future<bool> _extractKeywords(
    MemoryBank bank,
    String owner,
    List<MemoryEntry> batch,
    bool Function() current,
  ) async {
    final found = await provider.extractKeywords(owner: owner, batch: batch);
    if (found.isEmpty) return false;
    // await 期间可能已经换幕/换档：树被替换掉就丢弃这次结果，别写进新树。
    if (!current()) return false;
    for (final k in found) {
      bank.addKeyword(
        owner: owner,
        keywords: k.keywords,
        content: k.content,
        source: 'L2→L3 时提取',
        audience: [owner],
      );
    }
    return true;
  }

  void _stamp(
    CharacterMemoryTree tree,
    int layer,
    List<MemoryEntry> batch,
    String targetId,
  ) {
    for (final b in batch) {
      final i = tree.layerList(layer).indexOf(b);
      if (i >= 0) {
        tree.layerList(layer)[i] = b.copyWith(aggregatedInto: targetId);
      }
    }
  }

  // ---------------------------------------------------------------- evidence

  /// Short-term evidence for settlement: the **current scene's** L1 rounds and
  /// L2 fragments. Higher layers are for context injection, not for numbers.
  SettlementEvidence buildEvidence({
    required MemoryBank bank,
    required String owner,
    required SceneDef scene,
    required int visitId,
    required int day,
    required List<String> audience,
    required Map<String, Object?> state,
  }) {
    final shortTerm = <String>[];
    final window = bank.windowIfExists(owner);
    if (window != null) {
      for (final t in window.turns) {
        if (t.storyId != scene.id || t.visitId != visitId) continue;
        if (!t.visibleTo(owner)) continue;
        // 开场白（playerText 为空）不算结算证据：只听角色开口、
        // 玩家没有实际交流时，不应该触发数值变化。
        if (t.playerText.trim().isEmpty) continue;
        shortTerm.add(t.plainText);
      }
    }
    // L2 摘要：按条目的 hasPlayerInteraction 标记过滤。
    // 纯开场白提炼的摘要不算证据；包含真实交互的摘要即使 L1 已空也能用。
    final tree = bank.treeIfExists(owner);
    if (tree != null) {
      // 升层只改变聊天上下文的去重，不应抹掉本次访问的结算证据。
      for (final e in tree.evidenceActive(2)) {
        if (e.owner != owner &&
            e.audience.isNotEmpty &&
            !e.audience.contains(owner)) continue;
        final touchesScene = e.sourceScenes.any(
          (s) => s['storyId'] == scene.id && s['visitId'] == visitId,
        );
        if (!touchesScene) continue;
        if (!e.hasPlayerInteraction) continue;
        shortTerm.add(e.text);
      }
    }
    return SettlementEvidence(
      owner: owner,
      sceneId: scene.id,
      sceneName: scene.displayName,
      day: day,
      shortTerm: shortTerm,
      state: state,
      audience: audience,
    );
  }
}
