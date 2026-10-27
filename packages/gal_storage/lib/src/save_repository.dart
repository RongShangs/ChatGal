import 'dart:convert';
import 'dart:io';

import 'package:gal_protocol/gal_protocol.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import 'package_store.dart';
import 'save_models.dart';
import 'serial_writes.dart';

/// File-backed save repository (JSON slots under rootDir/saves).
/// Atomic write via temp file + rename. Drift adapter can replace this later.
class SaveRepository {
  SaveRepository({
    required this.rootDir,
    required this.packages,
  });

  final String rootDir;
  final PackageStore packages;

  String get _savesDir => p.join(rootDir, 'saves');

  Future<SaveSlot> create({
    required String label,
    required PackageRef packageRef,
    required String storyId,
    required WorldSnapshot world,
    String? sessionId,
    List<Map<String, Object?>>? messages,
    Map<String, Object?>? memory,
  }) async {
    final now = DateTime.now().toUtc();
    final saveId =
        'save_${now.microsecondsSinceEpoch}_${world.rngState.toRadixString(16)}';
    final slot = SaveSlot(
      saveId: saveId,
      sessionId: sessionId ?? saveId,
      label: label,
      packageRef: packageRef,
      storyId: storyId,
      world: world,
      createdAt: now,
      updatedAt: now,
      messageCheckpoint: messages ?? const [],
      memoryCheckpoint: memory ?? const {},
      // 第一份存档就写成当前 schema：否则新建后若立刻被杀进程，
      // 留下的是一份缺字段的旧版槽。
      saveSchemaVersion: SaveSlot.currentSchemaVersion,
    );
    await _writeAtomic(slot);
    return slot;
  }

  Future<SaveSlot> update(
    SaveSlot slot, {
    WorldSnapshot? world,
    List<Map<String, Object?>>? messages,
    String? label,
    int? revision,
    RuntimeCursor? runtimeCursor,
    List<String>? committedTransitions,
    List<String>? appliedSettlementIds,
    List<String>? pendingGalleryUnlocks,
    Map<String, Object?>? memoryCheckpoint,
    PendingOp? pending,
    bool clearPending = false,
  }) async {
    final next = slot.copyWith(
      world: world ?? slot.world,
      updatedAt: DateTime.now().toUtc(),
      label: label,
      messageCheckpoint: messages ?? slot.messageCheckpoint,
      memoryCheckpoint: memoryCheckpoint ?? slot.memoryCheckpoint,
      revision: revision ?? (world != null ? slot.revision + 1 : slot.revision),
      runtimeCursor: runtimeCursor,
      committedTransitions: committedTransitions,
      appliedSettlementIds: appliedSettlementIds,
      pendingGalleryUnlocks: pendingGalleryUnlocks,
      pending: pending,
      clearPending: clearPending,
      saveSchemaVersion: SaveSlot.currentSchemaVersion,
    );
    await _writeAtomic(next);
    return next;
  }

  /// Import a previously exported save JSON (new saveId; never overwrite).
  ///
  /// 与 [rename] / [copy] **同一道版本闸**：只有当前 schema 的存档才允许导入。
  /// 高版本存档导进来会被 `toJson()` 按当前形状重写（未知分区直接消失），
  /// 落盘后又因为版本对不上永远打不开 —— 那是「导入成功」的谎话。
  ///
  /// 失败仍然是返回 null（既有契约不变）；[onRejected] 只是把原因交出去，
  /// 让界面能说清是「不是存档」还是「版本不支持」。
  Future<SaveSlot?> importFromJson(
    String raw, {
    String? labelOverride,
    void Function(String reason)? onRejected,
  }) async {
    try {
      final decoded = jsonDecode(raw);
      Map<String, Object?>? slotJson;
      if (decoded is Map) {
        if (decoded['exportType'] == 'chatgalsave' && decoded['slot'] is Map) {
          slotJson = Map<String, Object?>.from(decoded['slot'] as Map);
        } else if (decoded['identity'] is Map) {
          // 分区形状的**裸存档文件**（saves/*.json 原样拷过来）
          slotJson = Map<String, Object?>.from(decoded);
        }
      }
      if (slotJson == null) {
        onRejected?.call('不是存档文件（既没有导出包装也没有 identity 分区）');
        return null;
      }
      final rawVersion = slotJson['saveSchemaVersion'];
      if (rawVersion is! num) {
        onRejected?.call('存档缺 saveSchemaVersion');
        return null;
      }
      final version = rawVersion.toInt();
      if (version != SaveSlot.currentSchemaVersion) {
        onRejected?.call(
          '存档版本 $version 与当前版本 ${SaveSlot.currentSchemaVersion} 不一致，'
          '导入会被改写成当前形状、丢掉未知分区，已拒绝',
        );
        return null;
      }
      final src = SaveSlot.fromJson(slotJson);
      final now = DateTime.now().toUtc();
      final next = SaveSlot(
        saveId: 'save_${now.microsecondsSinceEpoch}_import',
        // 同 copy：**保留历史 sessionId**，否则导入档的结算台账与新 sessionId
        // 算出来的幂等 id 对不上，同一幕会被重复结算。
        sessionId: src.sessionId,
        label: (labelOverride ?? src.label).trim().isEmpty
            ? '导入存档'
            : (labelOverride ?? src.label).trim(),
        packageRef: src.packageRef,
        storyId: src.storyId,
        world: src.world,
        createdAt: now,
        updatedAt: now,
        messageCheckpoint: src.messageCheckpoint,
        memoryCheckpoint: src.memoryCheckpoint,
        saveSchemaVersion: src.saveSchemaVersion,
        // 运行位必须一起带走：否则导入/复制出来的档会退回第 0 次修订、
        // 游标归零、已结算 id 全丢 —— 表现就是「加过的数值又加一遍」。
        revision: src.revision,
        runtimeCursor: src.runtimeCursor,
        committedTransitions: src.committedTransitions,
        appliedSettlementIds: src.appliedSettlementIds,
        pendingGalleryUnlocks: src.pendingGalleryUnlocks,
        pending: src.pending,
      );
      await _writeAtomic(next);
      return next;
    } catch (e) {
      onRejected?.call('存档解析失败：$e');
      return null;
    }
  }

  /// 列存档槽。
  ///
  /// **打不开的文件也要列出来**：旧版本 / 截断 / 损坏的存档会以
  /// [SaveSlot.isUnreadable] 的只读占位出现（界面上标「打不开」，能看能删）。
  /// 以前这里是「解析失败就跳过」，于是换过版本的旧存档在包库里**凭空消失** ——
  /// 玩家既看不到它、也不知道为什么进度没了。
  List<SaveSlot> listSaves() {
    final dir = Directory(_savesDir);
    if (!dir.existsSync()) return [];
    final out = <SaveSlot>[];
    for (final f in dir.listSync()) {
      if (f is! File || !f.path.endsWith('.json')) continue;
      final stem = p.basenameWithoutExtension(f.path);
      Map<String, Object?>? json;
      try {
        final decoded = jsonDecode(f.readAsStringSync());
        if (decoded is Map) json = decoded.cast<String, Object?>();
      } catch (_) {
        json = null;
      }
      SaveSlot? slot;
      if (json != null) {
        try {
          slot = SaveSlot.fromJson(json);
        } catch (_) {
          slot = null;
        }
      }
      out.add(slot ?? _unreadableStub(stem, json, f));
    }
    out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return out;
  }

  /// 从读得到的字段里尽力还原一个**只读占位槽**（分区形状放在 `identity` 里，
  /// 旧形状在顶层）。文件名 stem 才是它在磁盘上的身份，所以 saveId 用它。
  SaveSlot _unreadableStub(String stem, Map<String, Object?>? json, File f) {
    final identity = json?['identity'];
    String pick(String key) {
      final flat = json?[key];
      if (flat is String) return flat;
      if (identity is Map && identity[key] is String) return '${identity[key]}';
      return '';
    }

    // 旧档的包信息在顶层 packageRef（新档在 package 分区）：读得到就带上，
    // 这样它会归到对应的包下面（而不是全挤进「缺失包」）。
    PackageRef? ref;
    final rawRef = json?['packageRef'] ?? json?['package'];
    if (rawRef is Map) {
      final m = Map<String, Object?>.from(rawRef);
      if ('${m['packageId'] ?? ''}'.isNotEmpty) {
        ref = PackageRef(
          packageId: '${m['packageId']}',
          version: '${m['version'] ?? ''}',
          contentHash: '${m['contentHash'] ?? ''}',
          displayName: m['displayName'] as String?,
        );
      }
    }

    DateTime at;
    try {
      at = DateTime.parse(pick('updatedAt')).toUtc();
    } catch (_) {
      at = f.statSync().modified.toUtc();
    }

    final rawVersion = json?['saveSchemaVersion'];
    final label = pick('label');
    return SaveSlot.unreadable(
      saveId: stem,
      label: label.isEmpty ? '打不开的存档（$stem）' : label,
      updatedAt: at,
      // 版本号读得到就照抄（界面上能看出它是哪一版写的）；读不到给 -1，
      // 保证它既不等于当前版本、也不会被任何写入路径当成可改写的档。
      saveSchemaVersion: rawVersion is num ? rawVersion.toInt() : -1,
      packageRef: ref,
    );
  }

  /// Load and check package binding. Never auto-substitutes another package.
  SaveLoadResult load(String saveId) {
    final file = File(p.join(_savesDir, '$saveId.json'));
    if (!file.existsSync()) {
      return const SaveLoadResult.locked(
        reason: SaveLockReason.corruptSave,
        detail: 'save file missing',
      );
    }
    Map<String, Object?> json;
    try {
      final decoded = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      json = decoded.cast<String, Object?>();
    } catch (e) {
      return SaveLoadResult.locked(
        reason: SaveLockReason.corruptSave,
        detail: '$e',
      );
    }

    // **先看版本再解析分区**：旧版本写出来的文件根本不是分区形状，先解析会抛，
    // 于是「版本不支持」被误报成「文件损坏」（而且列表里也看不出原因）。
    final rawVersion = json['saveSchemaVersion'];
    if (rawVersion is! num) {
      return const SaveLoadResult.locked(
        reason: SaveLockReason.corruptSave,
        detail: '缺 saveSchemaVersion',
      );
    }
    final version = rawVersion.toInt();
    if (version != SaveSlot.currentSchemaVersion) {
      return SaveLoadResult.locked(
        reason: SaveLockReason.schemaUnsupported,
        detail: 'saveSchemaVersion=$version（当前版本只认 '
            '${SaveSlot.currentSchemaVersion}）',
      );
    }

    SaveSlot slot;
    try {
      slot = SaveSlot.fromJson(json);
    } catch (e) {
      return SaveLoadResult.locked(
        reason: SaveLockReason.corruptSave,
        detail: '$e',
      );
    }

    final ref = slot.packageRef;
    final exact =
        packages.findExact(ref.packageId, ref.version, ref.contentHash);
    if (exact != null) {
      return SaveLoadResult.allowed(slot: slot);
    }

    final sameId = packages
        .listInstalled()
        .where((r) => r.packageId == ref.packageId)
        .toList();

    // 同一个包换了版本/内容（默认包随 APP 升级就是这种情况）：
    // 按当前已安装的这份继续，别把玩家的存档锁死成「空的」。
    // 存档自己的 packageRef 保留着，界面上仍能看出它原来绑的是哪个版本。
    if (sameId.isNotEmpty) {
      return SaveLoadResult.allowed(
        slot: slot,
        detail: '包已更新：${ref.version} → ${sameId.first.version}',
      );
    }

    return SaveLoadResult.locked(
      reason: SaveLockReason.missingPackage,
      slot: slot,
      detail: '需安装：${ref.displayName ?? ref.packageId}/${ref.version}',
    );
  }

  Future<bool> delete(String saveId) async {
    final file = File(p.join(_savesDir, '$saveId.json'));
    await _deleteStaleTemps('$saveId.json');
    if (!file.existsSync()) return false;
    await file.delete();
    return true;
  }

  /// 清掉**这个存档自己**写盘留下的半截临时文件（写到一半被杀会留下它）。
  ///
  /// 只认两种属于自己的名字：新版 `.<文件名>.<唯一后缀>.tmp`、旧版 `<文件名>.tmp`。
  /// 别的存档（甚至别处）正在写的临时文件一个都不碰 —— 以前这里是
  /// `delete()` 里硬删 `$path.tmp`，正好会删掉别人手里那份正在写的临时文件。
  Future<void> _deleteStaleTemps(String fileName) async {
    final dir = Directory(_savesDir);
    if (!dir.existsSync()) return;
    try {
      for (final entity in dir.listSync()) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        final mine = name == '$fileName.tmp' ||
            (name.startsWith('.$fileName.') && name.endsWith('.tmp'));
        if (mine) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  Future<SaveSlot?> rename(String saveId, String newLabel) async {
    final result = load(saveId);
    final slot = result.slot;
    // 只改**能完整解析的当前版本**存档：旧版本/损坏的档按新形状重写一遍，
    // 等于把未知分区的内容毁掉（「锁档一个字节都不写」）。
    if (slot == null ||
        slot.isUnreadable ||
        slot.saveSchemaVersion != SaveSlot.currentSchemaVersion ||
        newLabel.trim().isEmpty) {
      return null;
    }
    final next = slot.copyWith(label: newLabel.trim());
    await _writeAtomic(next);
    return next;
  }

  /// Duplicate a save under a new label and new saveId.
  Future<SaveSlot?> copy(String saveId, String newLabel) async {
    final result = load(saveId);
    final src = result.slot;
    if (src == null ||
        src.isUnreadable ||
        src.saveSchemaVersion != SaveSlot.currentSchemaVersion ||
        newLabel.trim().isEmpty) {
      return null;
    }
    final now = DateTime.now().toUtc();
    final next = SaveSlot(
      saveId: 'save_${now.microsecondsSinceEpoch}_copy',
      // **保留历史 sessionId**：它不是文件身份，而是「事务历史身份」——
      // 结算/换幕幂等 id 都是 `sid_<sessionId>_<情景>_v<访问号>`，
      // 这里换个新 sessionId、却把 appliedSettlementIds 照抄过来，
      // 复制档再走一次同一访问号就会算出**对不上台账的新 id** → 重复加数值。
      sessionId: src.sessionId,
      label: newLabel.trim(),
      packageRef: src.packageRef,
      storyId: src.storyId,
      world: src.world,
      createdAt: now,
      updatedAt: now,
      messageCheckpoint: src.messageCheckpoint,
      memoryCheckpoint: src.memoryCheckpoint,
      saveSchemaVersion: src.saveSchemaVersion,
      // 复制 = 同一时点的分身：运行位（修订/游标/已结算 id/事件台账/pending）
      // 全部照抄，否则复制档会变成「幂等失效」的档。
      revision: src.revision,
      runtimeCursor: src.runtimeCursor,
      committedTransitions: src.committedTransitions,
      appliedSettlementIds: src.appliedSettlementIds,
      pendingGalleryUnlocks: src.pendingGalleryUnlocks,
      pending: src.pending,
    );
    await _writeAtomic(next);
    return next;
  }

  /// 每个存档文件一条写入队列（见 [SerialWrites]）。
  ///
  /// 两个写入方会落到同一个存档文件上：会话页自己那条 `_persistQueue`
  /// （`chat_page.dart`）和存档库的 rename / copy / import。两边都「写临时文件
  /// 再改名」，于是会互相把对方**写了一半的临时文件**改成正式文件、
  /// 或 rename 到一半文件已经不见了。这里按 saveId 串行，是同一道闸的第二层。
  final SerialWrites _writes = SerialWrites();

  /// 队列里还剩多少条待写（测试用；正常情况下任务完成即归零）。
  @visibleForTesting
  int get pendingWriteCount => _writes.pendingCount;

  static int _tmpSeq = 0;

  Future<void> _writeAtomic(SaveSlot slot) {
    final path = p.join(_savesDir, '${slot.saveId}.json');
    return _writes.run(path, () => _writeAtomicNow(slot, path));
  }

  Future<void> _writeAtomicNow(SaveSlot slot, String path) async {
    final dir = Directory(_savesDir);
    await dir.create(recursive: true);
    // 临时文件名**带唯一后缀**（微秒 + 进程内序号）：不同写入方各写各的临时文件，
    // 谁也不会把别人写了一半的那份改名成正式文件。点前缀 + `.tmp` 后缀让
    // `listSaves()`（只收 `.json`）看不见它，`delete()` 也能只清自己的那一类残留。
    final tmp = p.join(
      _savesDir,
      '.${slot.saveId}.json.${DateTime.now().microsecondsSinceEpoch}'
          '_${_tmpSeq++}.tmp',
    );
    final f = File(tmp);
    // **缩进 2 格**：存档是给人看/给人查的，紧凑成一行就白瞎了分区结构。
    // 仍然是一次原子写（temp + rename），不是分文件分步写。
    final body = const JsonEncoder.withIndent('  ').convert(slot.toJson());
    try {
      await f.writeAsString('$body\n', flush: true);
      await f.rename(path);
    } catch (e) {
      // 失败别把半截临时文件留在 saves/ 里。
      try {
        if (f.existsSync()) await f.delete();
      } catch (_) {}
      rethrow;
    }
  }
}
