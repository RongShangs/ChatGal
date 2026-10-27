import 'character_memory.dart';

/// One **complete dialogue round**: the player's input plus the character's
/// reply. System scene cards are not rounds and are not counted anywhere.
class DialogueTurn {
  const DialogueTurn({
    required this.turnId,
    required this.playerText,
    required this.replyText,
    required this.audience,
    required this.storyId,
    required this.visitId,
    required this.at,
  });

  final String turnId;
  final String playerText;
  final String replyText;

  /// Characters present for this round — the audience that may remember it.
  final List<String> audience;
  final String storyId;
  final int visitId;
  final DateTime at;

  bool visibleTo(String owner) => audience.contains(owner);

  String get plainText => '玩家：$playerText\n$replyText';

  Map<String, Object?> toJson() => {
        'turnId': turnId,
        'playerText': playerText,
        'replyText': replyText,
        'audience': audience,
        'storyId': storyId,
        'visitId': visitId,
        'at': at.toUtc().toIso8601String(),
      };

  factory DialogueTurn.fromJson(Map<String, Object?> json) {
    return DialogueTurn(
      turnId: '${json['turnId']}',
      playerText: (json['playerText'] as String?) ?? '',
      replyText: (json['replyText'] as String?) ?? '',
      audience:
          (json['audience'] as List? ?? const []).map((e) => '$e').toList(),
      storyId: '${json['storyId'] ?? ''}',
      visitId: (json['visitId'] as num?)?.toInt() ?? 0,
      at: DateTime.tryParse('${json['at'] ?? ''}') ?? DateTime.now(),
    );
  }
}

/// L1 for one character: the *active window* of complete rounds.
///
/// This is the window, not the chat log. Collapsing a batch out of it does not
/// delete anything — the full transcript stays in the save's message
/// checkpoint and remains viewable; it simply stops being sent to the model.
class ActiveWindow {
  ActiveWindow({
    required this.owner,
    this.thresholds = MemoryThresholds.defaults,
    List<DialogueTurn>? turns,
  }) : turns = turns ?? <DialogueTurn>[];

  final String owner;

  /// 阈值来自游戏外设置，改动会立刻作用到这个窗口。
  MemoryThresholds thresholds;
  final List<DialogueTurn> turns;

  void applyThresholds(MemoryThresholds next) => thresholds = next;

  int get length => turns.length;

  /// 现在该压的批：达到触发轮数后，把**最早的**若干轮（最多
  /// [MemoryThresholds.l1CollapseBatch] 轮，且不会吃掉要保留的最近若干轮）
  /// 压成 1 条 L2。没到触发点就返回空。
  List<DialogueTurn> pendingBatch() {
    if (turns.length < thresholds.l1CollapseAt) return const [];
    final excess = turns.length - thresholds.l1KeepRounds;
    if (excess <= 0) return const [];
    final take = excess < thresholds.l1CollapseBatch
        ? excess
        : thresholds.l1CollapseBatch;
    return turns.sublist(0, take);
  }

  /// Drop a successfully summarized batch. **Only call after the summary was
  /// produced and would be persisted** — a failed summary must keep the text.
  void commitBatch(int count) {
    if (count <= 0) return;
    if (count > turns.length) count = turns.length;
    turns.removeRange(0, count);
  }

  List<Map<String, Object?>> toJson() =>
      turns.map((t) => t.toJson()).toList();
}

/// All characters' memory: one [CharacterMemoryTree] + one [ActiveWindow] each.
///
/// Shared events land in every present character's own tree/window, each with
/// the audience recorded, so a character never learns a conversation it was
/// not part of.
class MemoryBank {
  MemoryBank({this.thresholds = MemoryThresholds.defaults});

  /// 阈值来自**游戏外设置**；改完立刻作用到每个角色的窗口与记忆树。
  MemoryThresholds thresholds;

  void applyThresholds(MemoryThresholds next) {
    thresholds = next;
    for (final w in _windows.values) {
      w.applyThresholds(next);
    }
    // 树上的阈值也要同步：L4→L5 的送审阈值是从树读的，只改窗口会出现
    // 「一部分层按新阈值、另一部分按旧阈值」。
    for (final t in _trees.values) {
      t.applyThresholds(next);
    }
  }

  /// 用另一份 bank 的内容覆盖自己，**保持对象身份不变**。
  ///
  /// 界面（例如记忆回廊页面）可能正持有这个实例；如果直接换引用，它会继续
  /// 显示旧数据 —— 看起来就像「换了场景 L1 还在」。
  void replaceWith(MemoryBank other) {
    thresholds = other.thresholds;
    _trees
      ..clear()
      ..addAll(other._trees);
    _windows
      ..clear()
      ..addAll(other._windows);
  }

  final Map<String, CharacterMemoryTree> _trees = {};
  final Map<String, ActiveWindow> _windows = {};

  Iterable<String> get owners sync* {
    final seen = <String>{};
    for (final k in [..._trees.keys, ..._windows.keys]) {
      if (seen.add(k)) yield k;
    }
  }

  bool get isEmpty => _trees.isEmpty && _windows.isEmpty;

  /// 新建的树也带当前阈值：否则刚建出来的角色会按默认阈值整理，
  /// 和设置里那套对不上（L4→L5 的送审阈值就是从树读的）。
  CharacterMemoryTree treeOf(String owner) => _trees.putIfAbsent(
        owner,
        () => CharacterMemoryTree(owner: owner, thresholds: thresholds),
      );

  ActiveWindow windowOf(String owner) => _windows.putIfAbsent(
        owner,
        () => ActiveWindow(owner: owner, thresholds: thresholds),
      );

  CharacterMemoryTree? treeIfExists(String owner) => _trees[owner];
  ActiveWindow? windowIfExists(String owner) => _windows[owner];

  /// Record one finished round for every character that was present.
  void recordTurn(DialogueTurn turn) {
    for (final charId in turn.audience) {
      if (charId.isEmpty) continue;
      windowOf(charId).turns.add(turn);
      treeOf(charId); // owner exists even before its first summary
    }
  }

  /// Add a keyword memory for [owner]. Keywords are a parallel channel, not a
  /// sixth layer, and never change numbers.
  void addKeyword({
    required String owner,
    required List<String> keywords,
    required String content,
    required String source,
    required List<String> audience,
  }) {
    // 合并同类：同一个内容（或关键词集合完全相同）不重复入库，只并关键词。
    // 关键词以前是纯 append，一场戏几十条下来全是噪音（用户反馈「太多了」）。
    final list = treeOf(owner).keywordEvents;
    for (var i = 0; i < list.length; i++) {
      final ev = list[i];
      final oldKeys =
          (ev['keywords'] as List? ?? const []).map((e) => '$e').toSet();
      final newKeys = keywords.toSet();
      final sameContent = '${ev['content'] ?? ''}' == content;
      final sameKeys = oldKeys.length == newKeys.length &&
          oldKeys.containsAll(newKeys);
      if (!sameContent && !sameKeys) continue;
      final merged = <String>[...oldKeys, ...newKeys];
      final old = '${ev['content'] ?? ''}';
      // 同一主题的两条细节都留着（拼起来），拼太长就保留较长的那条 ——
      // 条数由 L3 的上限兜底，这里只管别让单条无限膨胀。
      final joined = old.contains(content)
          ? old
          : (content.contains(old) ? content : '$old；$content');
      list[i] = {
        ...ev,
        'keywords': merged.toSet().toList(),
        'content': joined.length <= 160
            ? joined
            : (content.length >= old.length ? content : old),
      };
      return;
    }
    list.add({
      'owner': owner,
      'keywords': keywords,
      'content': content,
      'source': source,
      'audience': audience,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    });
  }

  /// Keyword memories that [owner] may recall, newest first, deduplicated.
  /// [probe] is the current input plus recently visible dialogue; matching is
  /// substring/contains based — a hit only surfaces the memory.
  List<Map<String, Object?>> recallKeywords(
    String owner, {
    required String probe,
    int limit = 12,
  }) {
    final tree = _trees[owner];
    if (tree == null) return const [];
    final out = <Map<String, Object?>>[];
    final seen = <String>{};
    for (final ev in tree.keywordEvents.reversed) {
      final audience = (ev['audience'] as List? ?? const [])
          .map((e) => '$e')
          .toList();
      if (audience.isNotEmpty && !audience.contains(owner)) continue;
      final keys = (ev['keywords'] as List? ?? const [])
          .map((e) => '$e')
          .toList();
      final hit = keys.any((k) => k.isNotEmpty && probe.contains(k));
      if (!hit) continue;
      final content = '${ev['content'] ?? ''}';
      if (!seen.add(content)) continue;
      out.add(ev);
      if (out.length >= limit) break;
    }
    return out;
  }

  /// 存档里**不存阈值**：阈值属于游戏外设置，进游戏时由调用方
  /// [applyThresholds] 灌进来（存档只保存记忆内容本身）。
  Map<String, Object?> toJson() => {
        'trees': {
          for (final e in _trees.entries) e.key: e.value.toJson(),
        },
        'windows': {
          for (final e in _windows.entries) e.key: e.value.toJson(),
        },
      };

  factory MemoryBank.fromJson(
    Map<String, Object?> json, {
    MemoryThresholds thresholds = MemoryThresholds.defaults,
  }) {
    final bank = MemoryBank(thresholds: thresholds);
    final trees = json['trees'];
    if (trees is Map) {
      trees.forEach((owner, raw) {
        if (raw is! Map) return;
        bank._trees['$owner'] = CharacterMemoryTree.fromJson(
          '$owner',
          Map<String, Object?>.from(raw),
          thresholds: thresholds,
        );
      });
    }
    final windows = json['windows'];
    if (windows is Map) {
      windows.forEach((owner, raw) {
        if (raw is! List) return;
        bank._windows['$owner'] = ActiveWindow(
          owner: '$owner',
          thresholds: thresholds,
          turns: [
            for (final t in raw)
              if (t is Map) DialogueTurn.fromJson(Map<String, Object?>.from(t)),
          ],
        );
      });
    }
    return bank;
  }
}
