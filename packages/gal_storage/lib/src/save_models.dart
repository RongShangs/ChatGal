import 'package:gal_protocol/gal_protocol.dart';

/// 存档文件里的**一条消息**（内存形状 → 文件形状）。
///
/// 内存里的消息是紧凑 map（`role` / `content` / `is_system` / `segments` / …），
/// 直接落盘就是「一堆 role/content」，读起来要靠猜。这里转成一套更直白的键：
///
/// * `kind`：`scene`（场景卡）/ `player`（玩家）/ `character`（角色）/ `system`；
/// * `speaker`：说话的是谁（取在场角色；一幕一人时就是她）；
/// * `text`：说的话；
/// * `turnId` / `segments` / `audience`：原样带着（回合 id、逐段立绘、在场角色）；
/// * 认不出来的键**原样带走**，不丢信息。
///
/// 读回时 [saveMessageFromJson] 再还原成内存形状，所以运行逻辑一行都不用改。
Map<String, Object?> saveMessageToJson(Map<String, Object?> m) {
  final isSystem = m['is_system'] == true;
  final role = '${m['role'] ?? ''}';
  final audience = m['audience'];
  final kind = isSystem
      ? 'scene'
      : role == 'user'
          ? 'player'
          : role == 'assistant'
              ? 'character'
              : 'system';
  final out = <String, Object?>{
    'kind': kind,
    if (audience is List && audience.isNotEmpty) 'speaker': '${audience.first}',
    'text': '${m['content'] ?? ''}',
  };
  for (final key in const ['turnId', 'segments', 'audience']) {
    final v = m[key];
    if (v != null) out[key] = v;
  }
  for (final e in m.entries) {
    if (_kMessageMemoryKeys.contains(e.key)) continue;
    out[e.key] = e.value;
  }
  return out;
}

const Set<String> _kMessageMemoryKeys = {
  'role',
  'content',
  'is_system',
  'turnId',
  'segments',
  'audience',
};

const Set<String> _kMessageSaveKeys = {
  'kind',
  'speaker',
  'text',
  'turnId',
  'segments',
  'audience',
};

/// 存档里的一条消息 → 内存形状（见 [saveMessageToJson]）。
Map<String, Object?> saveMessageFromJson(Map<String, Object?> m) {
  final kind = '${m['kind'] ?? ''}';
  final out = <String, Object?>{};
  switch (kind) {
    case 'scene':
      out['role'] = 'system';
      out['is_system'] = true;
    case 'player':
      out['role'] = 'user';
    case 'character':
      out['role'] = 'assistant';
    default:
      out['role'] = kind.isEmpty ? 'system' : kind;
  }
  out['content'] = '${m['text'] ?? ''}';
  for (final key in const ['turnId', 'segments', 'audience']) {
    final v = m[key];
    if (v != null) out[key] = v;
  }
  for (final e in m.entries) {
    if (_kMessageSaveKeys.contains(e.key)) continue;
    out[e.key] = e.value;
  }
  // 只写了 speaker、没写 audience 时按「说话人就是在场角色」补回来，
  // 保证「角色不自动知道自己不在场的对话」这条规则照样成立。
  final speaker = '${m['speaker'] ?? ''}'.trim();
  if (out['audience'] == null && speaker.isNotEmpty) {
    out['audience'] = <String>[speaker];
  }
  return out;
}

/// Immutable save slot record.
///
/// **只认当前 schema**（开发阶段不做任何旧档兼容）：版本不等于
/// [currentSchemaVersion] 时直接锁档，不改写原文件。
///
/// 落盘形状是**分区 + 缩进美化**的（见 [toJson]）：身份 / 包 / 运行位 / 世界 /
/// 对白 / 记忆 / 事件台账各占一块，键序固定，对白按「谁说的、说了什么」写。
class SaveSlot {
  SaveSlot({
    required this.saveId,
    required this.sessionId,
    required this.label,
    required this.packageRef,
    required this.storyId,
    required this.world,
    required this.createdAt,
    required this.updatedAt,
    this.messageCheckpoint = const [],
    this.memoryCheckpoint = const {},
    this.saveSchemaVersion = currentSchemaVersion,
    this.revision = 0,
    RuntimeCursor? runtimeCursor,
    this.committedTransitions = const [],
    this.appliedSettlementIds = const [],
    this.pendingGalleryUnlocks = const [],
    this.pending,
    this.isUnreadable = false,
  }) : runtimeCursor = runtimeCursor ??
            RuntimeCursor(
              mode: RuntimeCursor.modeStoryChat,
              storyId: storyId,
              visitId: 0,
            );

  /// 解析不出来的存档（旧版本 / 截断 / 损坏）在列表里的**只读占位槽**。
  ///
  /// 「打不开的存档」必须在界面上仍然看得见（能看、能删），不能凭空消失 ——
  /// 但这块数据不可信：改名 / 复制 / 导出都要按 [isUnreadable] 拦住，
  /// 免得把未知分区的内容按新形状重写回去（那等于毁档）。
  SaveSlot.unreadable({
    required this.saveId,
    required this.label,
    required DateTime updatedAt,
    this.saveSchemaVersion = -1,
    PackageRef? packageRef,
    this.storyId = '',
  })  : sessionId = '',
        packageRef = packageRef ??
            const PackageRef(packageId: '', version: '', contentHash: ''),
        world = const WorldSnapshot(
          variables: {},
          characters: {},
          eventHistory: {},
          story: {},
          presentation: {},
          rngState: 1,
        ),
        createdAt = updatedAt,
        updatedAt = updatedAt,
        messageCheckpoint = const [],
        memoryCheckpoint = const {},
        revision = 0,
        runtimeCursor = const RuntimeCursor(mode: RuntimeCursor.modeStoryChat),
        committedTransitions = const [],
        appliedSettlementIds = const [],
        pendingGalleryUnlocks = const [],
        pending = null,
        isUnreadable = true;

  static const currentSchemaVersion = 3;

  final String saveId;
  final String sessionId;
  final String label;
  final PackageRef packageRef;
  final String storyId;
  final WorldSnapshot world;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<Map<String, Object?>> messageCheckpoint;
  final Map<String, Object?> memoryCheckpoint;
  final int saveSchemaVersion;
  final int revision;
  final RuntimeCursor runtimeCursor;
  final List<String> committedTransitions;

  /// Per-rule settlement ids already applied. Retrying or replaying a leave
  /// consults this so the same numbers are never added twice.
  final List<String> appliedSettlementIds;
  final List<String> pendingGalleryUnlocks;
  final PendingOp? pending;

  /// 由 [SaveSlot.unreadable] 造出来的占位槽（数据不可信，只用于列表展示与删除）。
  final bool isUnreadable;

  SaveSlot copyWith({
    String? label,
    WorldSnapshot? world,
    DateTime? updatedAt,
    List<Map<String, Object?>>? messageCheckpoint,
    Map<String, Object?>? memoryCheckpoint,
    int? revision,
    RuntimeCursor? runtimeCursor,
    List<String>? committedTransitions,
    List<String>? appliedSettlementIds,
    List<String>? pendingGalleryUnlocks,
    PendingOp? pending,
    bool clearPending = false,
    int? saveSchemaVersion,
  }) {
    return SaveSlot(
      saveId: saveId,
      sessionId: sessionId,
      label: label ?? this.label,
      packageRef: packageRef,
      storyId: storyId,
      world: world ?? this.world,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      messageCheckpoint: messageCheckpoint ?? this.messageCheckpoint,
      memoryCheckpoint: memoryCheckpoint ?? this.memoryCheckpoint,
      saveSchemaVersion: saveSchemaVersion ?? this.saveSchemaVersion,
      revision: revision ?? this.revision,
      runtimeCursor: runtimeCursor ?? this.runtimeCursor,
      committedTransitions: committedTransitions ?? this.committedTransitions,
      appliedSettlementIds: appliedSettlementIds ?? this.appliedSettlementIds,
      pendingGalleryUnlocks:
          pendingGalleryUnlocks ?? this.pendingGalleryUnlocks,
      pending: clearPending ? null : (pending ?? this.pending),
    );
  }

  /// 存档文件的形状（**分区**，不是一坨扁平键值）。
  ///
  /// ```jsonc
  /// {
  ///   "saveSchemaVersion": 3,
  ///   "identity":  { saveId / sessionId / label / createdAt / updatedAt / revision },
  ///   "package":   { packageId / version / contentHash / displayName },
  ///   "progress":  { storyId / cursor / committedTransitions / appliedSettlementIds / pending },
  ///   "world":     { variables / characters / story / presentation / eventHistory / rngState },
  ///   "messages":  [ { kind / speaker / text / … } ],
  ///   "memory":    { …五层记忆… },
  ///   "eventLedger": [ 已触发的事件 id ]
  /// }
  /// ```
  ///
  /// 写盘时会缩进 2 格（`SaveRepository._writeAtomic`），所以存档是可读的。
  Map<String, Object?> toJson() => {
        'saveSchemaVersion': saveSchemaVersion,
        'identity': {
          'saveId': saveId,
          'sessionId': sessionId,
          'label': label,
          'createdAt': createdAt.toUtc().toIso8601String(),
          'updatedAt': updatedAt.toUtc().toIso8601String(),
          'revision': revision,
        },
        'package': packageRef.toJson(),
        'progress': {
          'storyId': storyId,
          'cursor': runtimeCursor.toJson(),
          'committedTransitions': committedTransitions,
          'appliedSettlementIds': appliedSettlementIds,
          'pending': pending?.toJson(),
        },
        'world': world.toJson(),
        'messages': [for (final m in messageCheckpoint) saveMessageToJson(m)],
        'memory': memoryCheckpoint,
        'eventLedger': pendingGalleryUnlocks,
      };

  factory SaveSlot.fromJson(Map<String, Object?> json) {
    // 必填：不做旧档兼容。缺这个字段的文件不是本版本写出来的，按损坏处理
    // （调用方 load() 会捕获并返回 corruptSave），不要用默认值把它蒙混过去。
    final schemaVersion = (json['saveSchemaVersion']! as num).toInt();

    Map<String, Object?> part(String key) {
      final v = json[key];
      if (v is! Map) {
        throw FormatException('存档缺 $key 分区（saveSchemaVersion=$schemaVersion）');
      }
      return Map<String, Object?>.from(v);
    }

    List<Object?> partList(String key) {
      final v = json[key];
      if (v is! List) {
        throw FormatException('存档缺 $key 分区（saveSchemaVersion=$schemaVersion）');
      }
      return v;
    }

    final identity = part('identity');
    final package = part('package');
    final progress = part('progress');
    final worldJson = part('world');

    PendingOp? pending;
    final pendingRaw = progress['pending'];
    if (pendingRaw is Map) {
      pending = PendingOp.fromJson(Map<String, Object?>.from(pendingRaw));
    }
    // 运行位（游标）必须真的在：以前缺了会被默认成 `visitId: 0`，而结算幂等键
    // 里带访问号 —— 那一幕会被当成「没结算过」再算一遍（数值重复加）。
    final cursorRaw = progress['cursor'];
    if (cursorRaw is! Map) {
      throw FormatException('存档缺 progress.cursor（saveSchemaVersion=$schemaVersion）');
    }
    final storyId = progress['storyId'];
    if (storyId is! String) {
      throw FormatException('存档缺 progress.storyId（saveSchemaVersion=$schemaVersion）');
    }

    // 数据分区同样是**必填**：缺了就按损坏处理，不要静默当成「空历史 / 空记忆」
    // （读回来会是一份空档，玩家看不到任何提示）。
    final rawMessages = partList('messages');
    final rawMemory = part('memory');
    final rawLedger = partList('eventLedger');

    return SaveSlot(
      saveId: identity['saveId']! as String,
      sessionId: identity['sessionId']! as String,
      label: identity['label']! as String,
      packageRef: PackageRef.fromJson(package),
      storyId: storyId,
      world: WorldSnapshot.fromJson(worldJson),
      createdAt: DateTime.parse(identity['createdAt']! as String),
      updatedAt: DateTime.parse(identity['updatedAt']! as String),
      messageCheckpoint: rawMessages
          .map((e) => saveMessageFromJson(Map<String, Object?>.from(e as Map)))
          .toList(),
      memoryCheckpoint: Map<String, Object?>.from(rawMemory),
      saveSchemaVersion: schemaVersion,
      revision: (identity['revision'] as num?)?.toInt() ?? 0,
      runtimeCursor: RuntimeCursor.fromJson(
        Map<String, Object?>.from(cursorRaw),
      ),
      committedTransitions:
          (progress['committedTransitions'] as List? ?? const [])
              .map((e) => '$e')
              .toList(),
      appliedSettlementIds:
          (progress['appliedSettlementIds'] as List? ?? const [])
              .map((e) => '$e')
              .toList(),
      pendingGalleryUnlocks: rawLedger.map((e) => '$e').toList(),
      pending: pending,
    );
  }
}

/// 存档进不去的原因。
///
/// 只剩三种真实会发生的：包不在、schema 比本版本新、文件本身坏了。
/// （原来还有 versionMismatch / hashMismatch —— 精确命中旧契约的产物，
/// 现在「同 packageId 的包还在就放行」，这两个值永远不会被产生，已删。）
enum SaveLockReason {
  ok,
  missingPackage,
  schemaUnsupported,
  corruptSave,
}

class SaveLoadResult {
  const SaveLoadResult.allowed({required this.slot, this.detail})
      : reason = SaveLockReason.ok;

  const SaveLoadResult.locked({
    required this.reason,
    this.slot,
    this.detail,
  });

  final SaveLockReason reason;
  final SaveSlot? slot;
  final String? detail;

  bool get canEnter => reason == SaveLockReason.ok && slot != null;
}
