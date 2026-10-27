/// 记忆阈值：**全部来自游戏外设置**（app_settings.json），存档里不再保存它们。
///
/// 五层各自可精细调整：
/// * L1 活跃窗口：保留多少轮 / 多少轮触发坍缩 / 每次把最早多少轮压成 1 条 L2
/// * L2→L3、L3→L4、L4→L5：各自的条数阈值与批大小
/// * L5 长期核心记忆：进入上下文的上限（字符），超限自压缩
///
/// 所有值都会被 [normalized] 夹到合法区间 —— 它们是玩家可改的，一个 0 或倒挂的
/// 组合会让整理循环空转甚至失控。
class MemoryThresholds {
  const MemoryThresholds({
    this.l1KeepRounds = 30,
    this.l1CollapseAt = 50,
    this.l2LiftCount = 6,
    this.l2LiftBatch = 3,
    this.l3LiftCount = 6,
    this.l3LiftBatch = 3,
    this.l4LiftCount = 4,
    this.l4LiftBatch = 2,
    this.l5MaxChars = 1200,
    this.l5CompressBatch = 2,
    this.l3KeywordMax = 12,
  });

  /// L1 坍缩后保留的最近轮数。
  final int l1KeepRounds;

  /// L1 达到这么多轮就触发坍缩。
  final int l1CollapseAt;

  /// 每次坍缩把最早的多少轮压成 1 条 L2。
  ///
  /// **不是独立设置项**：它就是「触发轮数 − 保留轮数」。硬凑一个独立滑条会让
  /// 三个值互相打架（保留 30 / 触发 50 / 每次 60 是无意义的），
  /// 所以由 [normalized] 保证 `触发 > 保留`，这里直接算出来。
  int get l1CollapseBatch => l1CollapseAt - l1KeepRounds;

  final int l2LiftCount;
  final int l2LiftBatch;
  final int l3LiftCount;
  final int l3LiftBatch;
  final int l4LiftCount;
  final int l4LiftBatch;

  /// L5 注入上下文的上限（字符数）；超过就自压缩。
  final int l5MaxChars;

  /// L5 自压缩时一次合并最旧的这么多条。
  final int l5CompressBatch;

  /// 关键词记忆的条数上限。到 L3 整理时按关键词合并、超限丢最旧 ——
  /// 关键词只在「被提到」时唤起细节，堆太多反而全是噪音。
  final int l3KeywordMax;

  static const defaults = MemoryThresholds();

  MemoryThresholds copyWith({
    int? l1KeepRounds,
    int? l1CollapseAt,
    int? l2LiftCount,
    int? l2LiftBatch,
    int? l3LiftCount,
    int? l3LiftBatch,
    int? l4LiftCount,
    int? l4LiftBatch,
    int? l5MaxChars,
    int? l5CompressBatch,
    int? l3KeywordMax,
  }) {
    return MemoryThresholds(
      l1KeepRounds: l1KeepRounds ?? this.l1KeepRounds,
      l1CollapseAt: l1CollapseAt ?? this.l1CollapseAt,
      l2LiftCount: l2LiftCount ?? this.l2LiftCount,
      l2LiftBatch: l2LiftBatch ?? this.l2LiftBatch,
      l3LiftCount: l3LiftCount ?? this.l3LiftCount,
      l3LiftBatch: l3LiftBatch ?? this.l3LiftBatch,
      l4LiftCount: l4LiftCount ?? this.l4LiftCount,
      l4LiftBatch: l4LiftBatch ?? this.l4LiftBatch,
      l5MaxChars: l5MaxChars ?? this.l5MaxChars,
      l5CompressBatch: l5CompressBatch ?? this.l5CompressBatch,
      l3KeywordMax: l3KeywordMax ?? this.l3KeywordMax,
    );
  }

  /// 夹到合法区间并保证不变量成立：**触发轮数 > 保留轮数**（于是批大小 ≥ 1）、
  /// 各层「阈值 ≥ 批大小」。
  MemoryThresholds normalized() {
    int atLeast(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);
    final keep = atLeast(l1KeepRounds, 1, 400);
    // 触发必须严格大于保留：由它推出每次压缩的批大小
    final collapseAt = atLeast(l1CollapseAt, keep + 1, 500);
    final l2Count = atLeast(l2LiftCount, 2, 50);
    final l3Count = atLeast(l3LiftCount, 2, 50);
    final l4Count = atLeast(l4LiftCount, 2, 50);
    return MemoryThresholds(
      l1KeepRounds: keep,
      l1CollapseAt: collapseAt,
      l2LiftCount: l2Count,
      l2LiftBatch: atLeast(l2LiftBatch, 1, l2Count),
      l3LiftCount: l3Count,
      l3LiftBatch: atLeast(l3LiftBatch, 1, l3Count),
      l4LiftCount: l4Count,
      l4LiftBatch: atLeast(l4LiftBatch, 1, l4Count),
      l5MaxChars: atLeast(l5MaxChars, 100, 20000),
      l5CompressBatch: atLeast(l5CompressBatch, 2, 20),
      l3KeywordMax: atLeast(l3KeywordMax, 4, 100),
    );
  }

  Map<String, Object?> toJson() => {
        'l1KeepRounds': l1KeepRounds,
        'l1CollapseAt': l1CollapseAt,
        'l2LiftCount': l2LiftCount,
        'l2LiftBatch': l2LiftBatch,
        'l3LiftCount': l3LiftCount,
        'l3LiftBatch': l3LiftBatch,
        'l4LiftCount': l4LiftCount,
        'l4LiftBatch': l4LiftBatch,
        'l5MaxChars': l5MaxChars,
        'l5CompressBatch': l5CompressBatch,
        'l3KeywordMax': l3KeywordMax,
      };

  factory MemoryThresholds.fromJson(Map<String, Object?> json) {
    int at(String k, int fallback) => (json[k] as num?)?.toInt() ?? fallback;
    return MemoryThresholds(
      l1KeepRounds: at('l1KeepRounds', 30),
      l1CollapseAt: at('l1CollapseAt', 50),
      l2LiftCount: at('l2LiftCount', 6),
      l2LiftBatch: at('l2LiftBatch', 3),
      l3LiftCount: at('l3LiftCount', 6),
      l3LiftBatch: at('l3LiftBatch', 3),
      l4LiftCount: at('l4LiftCount', 4),
      l4LiftBatch: at('l4LiftBatch', 2),
      l5MaxChars: at('l5MaxChars', 1200),
      l5CompressBatch: at('l5CompressBatch', 2),
      l3KeywordMax: at('l3KeywordMax', 12),
    ).normalized();
  }
}

/// Structured memory entry (S2).
class MemoryEntry {
  MemoryEntry({
    required this.memId,
    required this.layer,
    required this.owner,
    required this.text,
    required this.audience,
    required this.createdAt,
    this.status = 'active',
    this.aggregatedInto,
    this.sourceMemIds,
    this.source,
    this.sourceScenes = const [],
    this.l5ReviewedBy,
    this.hasPlayerInteraction = false,
  });

  final String memId;
  final int layer; // 2..5
  final String owner;
  final String text;
  final String status; // active | superseded
  final String? aggregatedInto;
  final List<String>? sourceMemIds;
  final Map<String, Object?>? source;
  final List<Map<String, Object?>> sourceScenes;
  final String? l5ReviewedBy;
  final List<String> audience;
  final DateTime createdAt;

  /// 这条摘要是否源自真实的玩家交互（playerText 非空的轮次）。
  /// 仅由开场白提炼出的摘要为 false —— 结算证据应排除它们。
  /// 缺少来源标记时保留摘要，但不能据此推断发生过玩家交互。
  final bool hasPlayerInteraction;

  bool get isActive => status == 'active';
  bool get isPendingLift =>
      isActive && aggregatedInto == null && l5ReviewedBy == null;

  MemoryEntry copyWith({
    String? status,
    String? aggregatedInto,
    String? l5ReviewedBy,
    List<String>? sourceMemIds,
  }) {
    return MemoryEntry(
      memId: memId,
      layer: layer,
      owner: owner,
      text: text,
      audience: audience,
      createdAt: createdAt,
      status: status ?? this.status,
      aggregatedInto: aggregatedInto ?? this.aggregatedInto,
      sourceMemIds: sourceMemIds ?? this.sourceMemIds,
      source: source,
      sourceScenes: sourceScenes,
      l5ReviewedBy: l5ReviewedBy ?? this.l5ReviewedBy,
      hasPlayerInteraction: hasPlayerInteraction,
    );
  }

  Map<String, Object?> toJson() => {
        'memId': memId,
        'layer': layer,
        'status': status,
        'aggregatedInto': aggregatedInto,
        'owner': owner,
        'text': text,
        'sourceMemIds': sourceMemIds,
        'source': source,
        'sourceScenes': sourceScenes,
        'l5ReviewedBy': l5ReviewedBy,
        'audience': audience,
        'hasPlayerInteraction': hasPlayerInteraction,
        'createdAt': createdAt.toUtc().toIso8601String(),
      };

  factory MemoryEntry.fromJson(Map<String, Object?> json) {
    return MemoryEntry(
      memId: json['memId']! as String,
      layer: (json['layer']! as num).toInt(),
      owner: json['owner']! as String,
      text: (json['text'] as String?) ?? '',
      audience:
          (json['audience'] as List? ?? const []).map((e) => '$e').toList(),
      createdAt:
          DateTime.tryParse('${json['createdAt'] ?? ''}') ?? DateTime.now(),
      status: (json['status'] as String?) ?? 'active',
      aggregatedInto: json['aggregatedInto'] as String?,
      sourceMemIds: (json['sourceMemIds'] as List?)?.map((e) => '$e').toList(),
      source: json['source'] is Map
          ? Map<String, Object?>.from(json['source'] as Map)
          : null,
      sourceScenes: (json['sourceScenes'] as List? ?? const [])
          .map((e) => Map<String, Object?>.from(e as Map))
          .toList(),
      l5ReviewedBy: json['l5ReviewedBy'] as String?,
      hasPlayerInteraction: json['hasPlayerInteraction'] as bool? ?? false,
    );
  }
}

/// Processed message/turn range (blocks re-summarization only).
class ProcessedRange {
  const ProcessedRange({
    required this.charId,
    required this.storyId,
    required this.visitId,
    required this.fromMsgId,
    required this.toMsgId,
    required this.turnIds,
    this.producedMemIds = const [],
  });

  final String charId;
  final String storyId;
  final int visitId;
  final String fromMsgId;
  final String toMsgId;
  final List<String> turnIds;
  final List<String> producedMemIds;

  bool coversTurn(String turnId) => turnIds.contains(turnId);

  Map<String, Object?> toJson() => {
        'charId': charId,
        'storyId': storyId,
        'visitId': visitId,
        'fromMsgId': fromMsgId,
        'toMsgId': toMsgId,
        'turnIds': turnIds,
        'producedMemIds': producedMemIds,
      };

  factory ProcessedRange.fromJson(Map<String, Object?> json) {
    return ProcessedRange(
      charId: json['charId']! as String,
      storyId: json['storyId']! as String,
      visitId: (json['visitId']! as num).toInt(),
      fromMsgId: json['fromMsgId']! as String,
      toMsgId: json['toMsgId']! as String,
      turnIds: (json['turnIds'] as List? ?? const []).map((e) => '$e').toList(),
      producedMemIds: (json['producedMemIds'] as List? ?? const [])
          .map((e) => '$e')
          .toList(),
    );
  }
}

/// Per-character memory tree + processed cursor.
class CharacterMemoryTree {
  CharacterMemoryTree({
    required this.owner,
    this.thresholds = MemoryThresholds.defaults,
  });

  final String owner;

  /// 阈值来自游戏外设置；[MemoryBank.applyThresholds] 会把它同步到每棵树，
  /// 否则「改了阈值只有一部分层生效」。
  MemoryThresholds thresholds;

  void applyThresholds(MemoryThresholds next) {
    thresholds = next;
  }

  final Map<int, List<MemoryEntry>> layers = {
    1: <MemoryEntry>[],
    2: <MemoryEntry>[],
    3: <MemoryEntry>[],
    4: <MemoryEntry>[],
    5: <MemoryEntry>[],
  };
  final List<Map<String, Object?>> keywordEvents = [];
  final List<ProcessedRange> processed = [];

  List<MemoryEntry> layerList(int layer) => layers[layer] ?? const [];

  /// 可注入 [owner] 上下文的条目：活着、未被上层覆盖，且**该条目确实属于
  /// [owner] 的知情范围**（不再只看「它在这棵树里」）。
  List<MemoryEntry> injectable(int layer) => layerList(layer)
      .where((e) =>
          e.isActive &&
          e.aggregatedInto == null &&
          (e.audience.isEmpty ||
              e.audience.contains(owner) ||
              e.owner == owner))
      .toList();

  /// L5 当前占用的字符数（用于自压缩判断）。
  int get l5Chars => injectable(5).fold(0, (sum, e) => sum + e.text.length);

  /// **关键词整理**：按关键词集合合并同主题的条目，再按上限丢掉最旧的。
  ///
  /// 只在 L3 阶段调用（见 `MemoryRuntime.consolidate`）：关键词是「被提到就想起
  /// 某个细节」的并行通道，不是第六层记忆，所以不需要逐条留着 ——
  /// 同主题合并、超限丢最旧，越用越干净。
  bool consolidateKeywords(int max) {
    if (keywordEvents.isEmpty) return false;
    final before = keywordEvents.length;

    // 1) 同关键词集合 → 合并成一条（保留最新那条的措辞，关键词取并集）
    final byKeys = <String, Map<String, Object?>>{};
    for (final ev in keywordEvents) {
      final keys = (ev['keywords'] as List? ?? const [])
          .map((e) => '$e'.trim())
          .where((e) => e.isNotEmpty)
          .toSet()
          .toList()
        ..sort();
      final key = keys.join('|');
      final prev = byKeys[key];
      if (prev == null) {
        byKeys[key] = Map<String, Object?>.from(ev);
      } else {
        // 合并内容：短的那条拼到长的后面（保留细节），总长限 240 字
        final a = '${prev['content'] ?? ''}';
        final b = '${ev['content'] ?? ''}';
        final joined = a.contains(b) ? a : (b.contains(a) ? b : '$a；$b');
        prev['content'] =
            joined.length <= 240 ? joined : joined.substring(0, 240);
        prev['createdAt'] = ev['createdAt'] ?? prev['createdAt'];
      }
    }
    var merged = byKeys.values.toList();

    // 2) 超上限 → 丢最旧（保留最新的 max 条）
    if (merged.length > max) {
      merged = merged.sublist(merged.length - max);
    }

    if (merged.length == before) {
      final same = merged.length == keywordEvents.length;
      if (same) {
        // 条数没变：仅当内容确实被合并过才认为有变化，避免每轮都标脏
        var changed = false;
        for (var i = 0; i < merged.length; i++) {
          if ('${merged[i]['content']}' != '${keywordEvents[i]['content']}') {
            changed = true;
            break;
          }
        }
        if (!changed) return false;
      }
    }
    keywordEvents
      ..clear()
      ..addAll(merged);
    return true;
  }

  List<MemoryEntry> evidenceActive(int layer) =>
      layerList(layer).where((e) => e.isActive).toList();

  void add(MemoryEntry e) {
    layers.putIfAbsent(e.layer, () => []).add(e);
  }

  /// Deterministic cascade for L2→L3 and L3→L4, plus an L4 review that falls
  /// back to `keep` (no new L5 text) when no model is available. The AI path
  /// calls [applyL5Review] instead, which may add/merge/correct.
  String? cascadeDeterministic({String updateIdPrefix = 'upd'}) {
    var changed = false;
    while (layerList(2).where((e) => e.isPendingLift).length >=
        thresholds.l2LiftCount) {
      final pending = layerList(2).where((e) => e.isPendingLift).toList();
      final batch = pending.sublist(0, thresholds.l2LiftBatch);
      final entry = MemoryEntry(
        memId: 'l3_${batch.first.memId}',
        layer: 3,
        owner: owner,
        text: batch.map((e) => e.text).join(' | '),
        audience: [owner],
        createdAt: DateTime.now(),
        source: const {'kind': 'cascade', 'sourceKnown': true},
        sourceMemIds: batch.map((e) => e.memId).toList(),
        sourceScenes: batch.expand((e) => e.sourceScenes).toList(),
        // 只要批里有任何一条源自真实交互，L3 就算有交互。
        hasPlayerInteraction: batch.any((e) => e.hasPlayerInteraction),
      );
      add(entry);
      for (final b in batch) {
        final i = layers[2]!.indexOf(b);
        if (i >= 0) {
          layers[2]![i] = b.copyWith(aggregatedInto: entry.memId);
        }
      }
      changed = true;
    }
    while (layerList(3).where((e) => e.isPendingLift).length >=
        thresholds.l3LiftCount) {
      final pending = layerList(3).where((e) => e.isPendingLift).toList();
      final batch = pending.sublist(0, thresholds.l3LiftBatch);
      final entry = MemoryEntry(
        memId: 'l4_${batch.first.memId}',
        layer: 4,
        owner: owner,
        text: batch.map((e) => e.text).join(' | '),
        audience: [owner],
        createdAt: DateTime.now(),
        source: const {'kind': 'cascade', 'sourceKnown': true},
        sourceMemIds: batch.map((e) => e.memId).toList(),
        sourceScenes: batch.expand((e) => e.sourceScenes).toList(),
        hasPlayerInteraction: batch.any((e) => e.hasPlayerInteraction),
      );
      add(entry);
      for (final b in batch) {
        final i = layers[3]!.indexOf(b);
        if (i >= 0) {
          layers[3]![i] = b.copyWith(aggregatedInto: entry.memId);
        }
      }
      changed = true;
    }
    while (layerList(4).where((e) => e.isPendingLift).length >=
        thresholds.l4LiftCount) {
      final pending = layerList(4).where((e) => e.isPendingLift).toList();
      final batch = pending.sublist(0, thresholds.l4LiftBatch);
      final updateId = '${updateIdPrefix}_keep_${batch.first.memId}';
      for (final b in batch) {
        final i = layers[4]!.indexOf(b);
        if (i >= 0) {
          layers[4]![i] = b.copyWith(l5ReviewedBy: updateId);
        }
      }
      changed = true;
    }
    return changed ? 'changed' : null;
  }

  /// The oldest L4 batch waiting to enter the L5 review, or empty when layer 4
  /// has not reached the threshold.
  List<MemoryEntry> pendingL5Review() {
    final pending = layerList(4).where((e) => e.isPendingLift).toList();
    if (pending.length < thresholds.l4LiftCount) return const [];
    return pending.sublist(0, thresholds.l4LiftBatch);
  }

  /// L5 maintenance: `add` | `merge` | `correct` | `keep`.
  ///
  /// * `add` / `correct` — append [text] as a new core memory.
  /// * `merge` — append the merged [text] and supersede [supersedeL5Ids].
  /// * `keep` — no new text; only stamp the batch (never delete core facts).
  ///
  /// Returns the new L5 entry, or null for `keep`.
  MemoryEntry? applyL5Review({
    required String action,
    required List<MemoryEntry> batch,
    String? text,
    List<String> supersedeL5Ids = const [],
    String? updateId,
  }) {
    if (batch.isEmpty) return null;
    final id = updateId ?? 'l5_${action}_${batch.first.memId}';
    MemoryEntry? created;
    if (action != 'keep' && text != null && text.trim().isNotEmpty) {
      created = MemoryEntry(
        memId: id,
        layer: 5,
        owner: owner,
        text: text,
        audience: [owner],
        createdAt: DateTime.now(),
        l5ReviewedBy: action,
        source: {
          'kind': 'l5_review',
          'action': action,
          'fromLayer': 4,
        },
        sourceMemIds: batch.map((e) => e.memId).toList(),
        sourceScenes: batch.expand((e) => e.sourceScenes).toList(),
      );
      add(created);
      if (action == 'merge' || action == 'correct') {
        for (final sid in supersedeL5Ids) {
          final list = layers[5]!;
          final idx = list.indexWhere((e) => e.memId == sid);
          if (idx >= 0) {
            list[idx] =
                list[idx].copyWith(status: 'superseded', aggregatedInto: id);
          }
        }
      }
    }
    for (final b in batch) {
      final i = layers[4]!.indexOf(b);
      if (i >= 0) {
        layers[4]![i] = b.copyWith(l5ReviewedBy: id);
      }
    }
    return created;
  }

  /// L5 **自压缩**：把最旧的 [batch] 合并成一条新的 L5，被合并的标记为已取代。
  ///
  /// 与 [applyL5Review] 的区别：那一个是 L4→L5 的送审（批是 L4 条目），
  /// 这里批本身就是 L5 条目，只做「压短」不动层。
  MemoryEntry compressL5({
    required List<MemoryEntry> batch,
    required String text,
    required String updateId,
  }) {
    final entry = MemoryEntry(
      memId: updateId,
      layer: 5,
      owner: owner,
      text: text,
      audience: [owner],
      createdAt: DateTime.now(),
      source: const {'kind': 'l5_compress'},
      sourceMemIds: batch.map((e) => e.memId).toList(),
      sourceScenes: batch.expand((e) => e.sourceScenes).toList(),
    );
    add(entry);
    for (final b in batch) {
      final i = layers[5]!.indexOf(b);
      if (i >= 0) {
        layers[5]![i] =
            b.copyWith(status: 'superseded', aggregatedInto: entry.memId);
      }
    }
    return entry;
  }

  /// Prefer higher layers; block covered lower memIds.
  List<MemoryEntry> collectEvidence({
    required Set<String> sceneMemIds,
    required List<ProcessedRange> sceneProcessed,
  }) {
    bool related(MemoryEntry e) {
      if (e.owner != owner && !e.audience.contains(owner)) return false;
      if (sceneMemIds.contains(e.memId)) return true;
      final ids = e.sourceMemIds ?? const <String>[];
      if (ids.any(sceneMemIds.contains)) return true;
      for (final sc in e.sourceScenes) {
        for (final pr in sceneProcessed) {
          if (pr.storyId == sc['storyId'] && pr.visitId == sc['visitId']) {
            return true;
          }
        }
      }
      for (final pr in sceneProcessed) {
        if (pr.producedMemIds.contains(e.memId)) return true;
        final src = e.sourceMemIds ?? const <String>[];
        if (src.any(pr.producedMemIds.contains)) return true;
      }
      return false;
    }

    final selected = <MemoryEntry>[];
    final blocked = <String>{};
    for (final layer in [5, 4, 3, 2]) {
      for (final entry in evidenceActive(layer).reversed) {
        if (blocked.contains(entry.memId)) continue;
        if (!related(entry)) continue;
        selected.add(entry);
        final stack = <String>[...?entry.sourceMemIds];
        while (stack.isNotEmpty) {
          final id = stack.removeLast();
          if (!blocked.add(id)) continue;
          MemoryEntry? child;
          for (final l in [2, 3, 4]) {
            for (final cand in layerList(l)) {
              if (cand.memId == id) child = cand;
            }
          }
          if (child != null) {
            stack.addAll(child.sourceMemIds ?? const <String>[]);
          }
        }
      }
    }
    return {for (final e in selected) e.memId: e}.values.toList();
  }

  Map<String, Object?> toJson() => {
        'layers': {
          for (final e in layers.entries)
            '${e.key}': e.value.map((x) => x.toJson()).toList(),
        },
        'events': keywordEvents,
        'processed': processed.map((p) => p.toJson()).toList(),
      };

  factory CharacterMemoryTree.fromJson(
    String owner,
    Map<String, Object?> json, {
    MemoryThresholds thresholds = MemoryThresholds.defaults,
  }) {
    final t = CharacterMemoryTree(owner: owner, thresholds: thresholds);
    final layersRaw = json['layers'];
    if (layersRaw is Map) {
      layersRaw.forEach((k, v) {
        final layer = int.tryParse('$k');
        if (layer == null || v is! List) return;
        for (final item in v) {
          if (item is Map) {
            // 存档里出现 1..5 之外的层级键时不能崩（`layers[layer]!` 会 NPE
            // 把整份存档拖死）；认不出的层级就照它的号建一个列表。
            (t.layers[layer] ??= <MemoryEntry>[]).add(
              MemoryEntry.fromJson(Map<String, Object?>.from(item)),
            );
          }
        }
      });
    }
    for (final e in (json['events'] as List? ?? const [])) {
      if (e is Map) t.keywordEvents.add(Map<String, Object?>.from(e));
    }
    for (final p in (json['processed'] as List? ?? const [])) {
      if (p is Map) {
        t.processed.add(ProcessedRange.fromJson(Map<String, Object?>.from(p)));
      }
    }
    return t;
  }
}
