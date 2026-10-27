import 'dart:convert';
import 'dart:io';

import 'package:gal_protocol/gal_protocol.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import 'install_result.dart';
import 'package_files.dart';
import 'package_installer.dart';
import 'package_store.dart';
import 'serial_writes.dart';

/// 一个「创作台工程」的摘要信息（列表页用）。
///
/// **工程身份是目录名 [slug]**，不是 packageId —— 所以同一个 packageId 可以有多份
/// 工程并存（复制出来的那份共用包名，方便做分支尝试）。
class StudioProject {
  const StudioProject({
    required this.slug,
    required this.packageId,
    required this.version,
    required this.name,
    required this.description,
    required this.scenes,
    required this.events,
    required this.characters,
    required this.updatedAt,
    required this.readable,
  });

  final String slug;
  final String packageId;
  final String version;
  final String name;
  final String description;
  final int scenes;
  final int events;
  final int characters;
  final DateTime updatedAt;

  /// manifest 读不出来时为 false（工程被外部改坏时列表仍要能显示它、好让用户删掉）。
  final bool readable;
}

/// 「导入到本地包」的版本比对结论。
enum StudioInstallVerdict {
  /// 本地还没有这个 packageId。
  freshPackage,

  /// 已有同 packageId 的**其它版本**（可以并存安装）。
  otherVersion,

  /// 同版本、内容一致：装了也是同一份。
  identical,

  /// 同版本、内容不同：安装器会拒（防止存档绑定的内容哈希被偷换），要改版本号。
  contentConflict,
}

class StudioInstallPlan {
  const StudioInstallPlan({
    required this.verdict,
    required this.installed,
    required this.message,
  });

  final StudioInstallVerdict verdict;

  /// 本地已有的、同一 packageId 的版本（可能多个）。
  final List<PackageRef> installed;

  /// 给界面直接显示的一句结论。
  final String message;

  bool get canInstall => verdict != StudioInstallVerdict.contentConflict;
}

/// 工程体检结果。
class StudioCheckResult {
  const StudioCheckResult({
    required this.loaded,
    this.report,
    this.loadError,
  });

  /// 能不能被加载器读成内容包（结构/JSON 层面）。
  final bool loaded;
  final ValidationReport? report;

  /// [loaded] 为 false 时的原因。
  final String? loadError;

  bool get ok => loaded && (report?.isValid ?? false);
  List<ValidationError> get errors => report?.errors ?? const [];
  List<ValidationError> get warnings => report?.warnings ?? const [];
}

/// 内容包创作台的工程存储。
///
/// 布局：`<rootDir>/studio/<工程目录名>/{manifest.json,characters/,stories/,events/}`
/// —— 工程目录本身就是一棵**合法的包目录树**，所以：
/// * 导出 = 把这个目录打成 .chatgal（复用 [PackageInstaller.exportInstalled]）；
/// * 装到本地包 = 把这个目录交给 [PackageInstaller.installFromPath]（同一套校验）。
///
/// 工程内一律写**纯 JSON**（不带注释）：编辑器保存时会整体重新序列化，
/// 保留注释需要按字段做原文改写，脆弱且容易写坏文件。
class StudioStore {
  StudioStore({
    required this.rootDir,
    required this.installer,
    required this.packages,
  });

  final String rootDir;
  final PackageInstaller installer;
  final PackageStore packages;

  /// 工程**完成标记**文件名：只有带它的目录才算工程。
  ///
  /// 点前缀 = 不算包内容（[isPackageContentPath]），所以导出成 `.chatgal`
  /// 或「装到本地」时都不会跟着走。旧版本没有这个标记，见 [_adoptLegacyProject]。
  static const markerFileName = '.chatgal_project';

  static const _markerBody = '{"format":"chatgal-studio-project","version":1}\n';

  String get studioDir => p.join(rootDir, 'studio');

  String dirOf(String slug) => p.join(studioDir, slug);

  bool exists(String slug) => Directory(dirOf(slug)).existsSync();

  // ------------------------------------------------------------------ 列表

  List<StudioProject> listProjects() {
    final dir = Directory(studioDir);
    if (!dir.existsSync()) return const [];
    final out = <StudioProject>[];
    for (final entry in dir.listSync()) {
      if (entry is! Directory) continue;
      final slug = p.basename(entry.path);
      if (slug.startsWith('.')) continue;
      // 只列**有完成标记**的目录：半成品（复制/导入到一半被杀）不再冒充工程。
      final marked = File(p.join(entry.path, markerFileName)).existsSync();
      if (!marked && !_adoptLegacyProject(entry)) continue;
      out.add(_describe(slug, entry));
    }
    out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return out;
  }

  /// 存量工程的迁移：旧版本落盘的工程**没有完成标记**，这里认「目录里有能解析的
  /// manifest.json」为工程，并顺手补写标记。
  ///
  /// 这一步是硬要求：不补标记就直接按标记过滤，用户现有的工程会在升级后
  /// **从列表里消失**（比半成品混进列表严重得多）。
  bool _adoptLegacyProject(Directory dir) {
    try {
      final manifest = File(p.join(dir.path, 'manifest.json'));
      if (!manifest.existsSync()) return false;
      if (decodeJsonc(manifest.readAsStringSync()) is! Map) return false;
      try {
        File(p.join(dir.path, markerFileName))
            .writeAsStringSync(_markerBody, flush: true);
      } catch (_) {
        // 补标记失败（只读介质等）：照常列出来 —— 它确实是工程，只是还没标记。
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 工程落盘的统一出口：先把整棵内容写进 `<studio>/.new_<微秒>_<序号>/`
  /// （点前缀 → 不进 [listProjects]），写完**完成标记**再整目录改名就位。
  ///
  /// 以前是「先建正式目录、再逐文件写/复制」：中途被杀就留下一个缺文件、
  /// 甚至还没有 manifest 的目录，而列表把任何目录都当工程 ——
  /// 用户于是看到一个打不开也删不掉的「空工程」。
  Future<StudioProject> _createProject(
    String slug,
    Future<void> Function(String dirAbs) fill,
  ) async {
    await Directory(studioDir).create(recursive: true);
    final staging = Directory(
      p.join(studioDir,
          '.new_${DateTime.now().microsecondsSinceEpoch}_${_stagingSeq++}'),
    );
    await staging.create(recursive: true);
    try {
      await fill(staging.path);
      await _writeMarker(staging.path);
      await staging.rename(dirOf(slug));
    } catch (e) {
      // 半成品自己收掉（点前缀虽然不会进列表，但也不该留在盘上）。
      try {
        if (staging.existsSync()) await staging.delete(recursive: true);
      } catch (_) {}
      rethrow;
    }
    return _describe(slug, Directory(dirOf(slug)));
  }

  static int _stagingSeq = 0;

  /// 写完成标记（只在落盘的最后一步调用；标记本身就是一行 JSON）。
  Future<void> _writeMarker(String dirAbs) async {
    await File(p.join(dirAbs, markerFileName))
        .writeAsString(_markerBody, flush: true);
  }

  StudioProject _describe(String slug, Directory dir) {
    Map<String, Object?>? manifest;
    try {
      final f = File(p.join(dir.path, 'manifest.json'));
      if (f.existsSync()) {
        final decoded = decodeJsonc(f.readAsStringSync());
        if (decoded is Map) manifest = Map<String, Object?>.from(decoded);
      }
    } catch (_) {
      manifest = null;
    }

    int countFiles(String sub, {String suffix = '.json'}) {
      final d = Directory(p.join(dir.path, sub));
      if (!d.existsSync()) return 0;
      return d.listSync().whereType<File>().where((f) {
        final name = p.basename(f.path);
        return name.endsWith(suffix) && !name.startsWith('.');
      }).length;
    }

    /// 数 `<sub>/<目录>/<marker>` 形式的条目（marker 是**文件**）。
    /// 注意别写成 `Directory(marker)`：`character.json` 是文件，用目录判断会永远是 false
    /// （曾经因此让工程列表把角色数显示成 0）。
    int countSubDirs(String sub, String marker) {
      final d = Directory(p.join(dir.path, sub));
      if (!d.existsSync()) return 0;
      return d.listSync().whereType<Directory>().where((x) {
        return File(p.join(x.path, marker)).existsSync();
      }).length;
    }

    return StudioProject(
      slug: slug,
      packageId: '${manifest?['packageId'] ?? ''}',
      version: '${manifest?['version'] ?? ''}',
      name: '${manifest?['name'] ?? slug}',
      description: '${manifest?['description'] ?? ''}',
      scenes: countFiles('stories'),
      events: countSubDirs('events', 'event.json'),
      characters: countSubDirs('characters', 'character.json'),
      updatedAt: dir.statSync().modified,
      readable: manifest != null,
    );
  }

  // ------------------------------------------------------------ 新建 / 导入

  /// 从零新建：manifest + 一个空的 `stories/start.json`（没有出口是合法状态）。
  Future<StudioProject> createBlank({
    required String name,
    required String packageId,
    required String version,
    String author = '',
    String description = '',
  }) async {
    final slug = _reserveSlug(name.isEmpty ? packageId : name);
    return _createProject(slug, (rootAbs) async {
      await Directory(p.join(rootAbs, 'characters')).create(recursive: true);
      await Directory(p.join(rootAbs, 'events')).create(recursive: true);

      await _writeJsonAt(rootAbs, 'manifest.json', {
        'packageId': packageId,
        'version': version,
        'name': name.isEmpty ? packageId : name,
        'author': author,
        'description': description,
        'variables': [
          // day **默认 0**：新游戏靠「入场那一幕」的 day +1 变成第 1 天。
          // 上下限留空 = 不设限（想写多长就多长）。
          {'id': 'day', 'type': 'int', 'default': 0},
        ],
      });
      await _writeJsonAt(rootAbs, 'stories/start.json', {
        // 展示名留空 = 还没填（占位提示写的是「例：白天·学校」这种一眼能看出是示例的文案）；
        // 体检会一直提示「展示名不能为空」，直到作者写下自己的那一幕。
        'displayName': '',
        'background': '',
        'narration': '',
        'characters': <Object?>[],
        // start 就是新游戏的入口：day 默认 0，这里 +1 = 第 1 天（和之后每一天一样的写法）
        'fixedEffects': <Object?>[
          {'id': 'day', 'value': 1},
        ],
        'target': <Object?>[],
      });
    });
  }

  /// 把一个 `.chatgal` 导入成工程（解压 → 目录树直接就是工程）。
  Future<StudioProject> importFromZip(String zipPath) async {
    final tmp = Directory(
      p.join(rootDir, 'staging',
          'studio_${DateTime.now().microsecondsSinceEpoch}'),
    );
    await tmp.create(recursive: true);
    try {
      await installer.extractTo(zipPath, tmp.path);
      final hint = _nameOf(tmp) ?? p.basenameWithoutExtension(zipPath);
      final slug = _reserveSlug(hint);
      return await _createProject(
        slug,
        (rootAbs) => _copyTree(tmp, Directory(rootAbs)),
      );
    } finally {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    }
  }

  /// 把**已安装的包**导入成工程（复制安装目录）。
  Future<StudioProject> importFromInstalled(PackageRef ref) async {
    final src = Directory(packages.installDirOf(ref));
    final slug = _reserveSlug(ref.displayName ?? ref.packageId);
    return _createProject(
      slug,
      (rootAbs) => _copyTree(src, Directory(rootAbs)),
    );
  }

  /// 复制工程（**允许同名 packageId 多份**，用于做分支尝试）。
  Future<StudioProject> duplicate(String slug) async {
    await flushWrites(slug);
    final target = _reserveSlug('$slug 副本');
    return _createProject(
      target,
      (rootAbs) => _copyTree(Directory(dirOf(slug)), Directory(rootAbs)),
    );
  }

  Future<bool> delete(String slug) async {
    await flushWrites(slug);
    final dir = Directory(dirOf(slug));
    if (!dir.existsSync()) return false;
    await dir.delete(recursive: true);
    return true;
  }

  /// 改工程目录名（= 工程身份）。包名（manifest.name）不动。
  Future<StudioProject> renameProject(String slug, String newSlug) async {
    await flushWrites(slug);
    final clean = _sanitize(newSlug);
    if (clean.isEmpty || clean == slug) {
      return _describe(slug, Directory(dirOf(slug)));
    }
    final target = _reserveSlug(clean);
    await Directory(dirOf(slug)).rename(dirOf(target));
    return _describe(target, Directory(dirOf(target)));
  }

  String? _nameOf(Directory dir) {
    try {
      final f = File(p.join(dir.path, 'manifest.json'));
      if (!f.existsSync()) return null;
      final decoded = decodeJsonc(f.readAsStringSync());
      if (decoded is Map) {
        final n = '${decoded['name'] ?? ''}'.trim();
        if (n.isNotEmpty) return n;
        final id = '${decoded['packageId'] ?? ''}'.trim();
        if (id.isNotEmpty) return id.split('.').last;
      }
    } catch (_) {}
    return null;
  }

  // ------------------------------------------------------------ 文件读写

  String _absIn(String rootAbs, String rel) {
    final clean = rel.replaceAll('\\', '/');
    if (clean.isEmpty ||
        clean.startsWith('/') ||
        clean.split('/').any((s) => s.isEmpty || s == '..' || s == '.')) {
      throw ArgumentError('非法相对路径：$rel');
    }
    return p.join(rootAbs, clean);
  }

  String _abs(String slug, String rel) => _absIn(dirOf(slug), rel);

  /// 工程内某个相对路径的绝对路径（只用于「在界面上预览这张图」这类只读用途；
  /// 读写仍然走 readJson / writeBytes 那一套）。
  String absPathOf(String slug, String rel) => _abs(slug, rel);

  /// 写 JSON（**纯 JSON**，缩进 2、末尾换行）。
  Future<void> writeJson(
    String slug,
    String rel,
    Map<String, Object?> json,
  ) async {
    await writeText(
      slug,
      rel,
      '${const JsonEncoder.withIndent('  ').convert(json)}\n',
    );
  }

  Future<void> writeText(String slug, String rel, String text) =>
      _writeAtomic(slug, rel, (f) => f.writeAsString(text, flush: true));

  Future<void> writeBytes(String slug, String rel, List<int> bytes) =>
      _writeAtomic(slug, rel, (f) => f.writeAsBytes(bytes, flush: true));

  /// 写 JSON 到**任意工程根目录**（新建工程时先写进临时目录用）。
  Future<void> _writeJsonAt(
    String rootAbs,
    String rel,
    Map<String, Object?> json,
  ) =>
      _writeTextAt(
        rootAbs,
        rel,
        '${const JsonEncoder.withIndent('  ').convert(json)}\n',
      );

  Future<void> _writeTextAt(String rootAbs, String rel, String text) =>
      _writeAtomicAt(
        _absIn(rootAbs, rel),
        (f) => f.writeAsString(text, flush: true),
      );

  /// 每个目标文件一条写入队列：同一个文件并发写会互相截断。
  /// 队列在写完后自己移除条目（见 [SerialWrites]），不是只增不减的表。
  final SerialWrites _writes = SerialWrites();

  /// 队列里还剩多少条待写（测试用；正常情况下任务完成即归零）。
  @visibleForTesting
  int get pendingWriteCount => _writes.pendingCount;

  /// **原子写**：先写同目录的 `.<文件名>.tmp`，再改名替换。
  ///
  /// 以前是直接 `writeAsString` 覆盖原文件，`flush: true` 并不让它变成原子操作：
  /// 写到一半失败或进程被杀，manifest / 角色 / 情景 / 事件 JSON 就会变成空文件或
  /// 半截文件；而 `readJson()` 解析失败返回 null，编辑器又按空数据加载 ——
  /// 一份坏文件于是静默变成「这个工程是空的」。改名替换保证磁盘上任何时刻要么是
  /// 完整旧版、要么是完整新版。
  ///
  /// 临时文件名**带点前缀**：拷贝/导出只收「包内容谓词」认的文件，
  /// 所以它不会被复制进别的工程，也不会被打进 `.chatgal` 导出包
  /// （以前是 `manifest.json.tmp`，两者都会）。同一个目标文件由队列串行，
  /// 所以这个名字按目标固定即可。
  Future<void> _writeAtomic(
    String slug,
    String rel,
    Future<void> Function(File tmp) writer,
  ) =>
      _writeAtomicAt(_abs(slug, rel), writer);

  Future<void> _writeAtomicAt(
    String target,
    Future<void> Function(File tmp) writer,
  ) {
    return _writes.run(target, () async {
      final tmp = File(p.join(p.dirname(target), '.${p.basename(target)}.tmp'));
      await tmp.parent.create(recursive: true);
      try {
        await writer(tmp);
        await tmp.rename(target);
      } catch (e) {
        try {
          if (tmp.existsSync()) tmp.deleteSync();
        } catch (_) {}
        rethrow;
      }
    });
  }

  /// 等某工程（或全部）的写盘队列排空（测试 / 导出前用）。
  ///
  /// **快照语义**：只等「调用这一刻已经入队」的写。调用之后才入队的写不在等待
  /// 范围内 —— 导出 / 安装 / 改名 / 删除都在动手之前调它，等的正是那一刻之前
  /// 已经排队的写，不会拿到更旧的内容。
  Future<void> flushWrites([String? slug]) {
    final root = slug == null ? null : dirOf(slug);
    return _writes.flush((key) => root == null || p.isWithin(root, key));
  }

  /// 读 JSON（容忍注释：导入进来的包可能带 `//`）。
  Map<String, Object?>? readJson(String slug, String rel) {
    final f = File(_abs(slug, rel));
    if (!f.existsSync()) return null;
    try {
      final decoded = decodeJsonc(f.readAsStringSync());
      if (decoded is! Map) return null;
      return Map<String, Object?>.from(decoded);
    } catch (_) {
      return null;
    }
  }

  Future<void> deletePath(String slug, String rel) async {
    await flushWrites(slug);
    final f = File(_abs(slug, rel));
    if (f.existsSync()) {
      await f.delete();
      return;
    }
    final d = Directory(_abs(slug, rel));
    if (d.existsSync()) await d.delete(recursive: true);
  }

  /// 改名/移动（立绘改名就是靠它：`<旧状态>_<情绪>.png` → `<新状态>_<情绪>.png`）。
  Future<bool> renamePath(String slug, String from, String to) async {
    await flushWrites(slug);
    // 源、目标相同时直接无操作：底层先删目标再 rename 的顺序在
    // 「改成原名」场景下会把原图删掉、随后 rename 失败 → 立绘丢失。
    if (from == to) {
      return File(_abs(slug, from)).existsSync();
    }
    final src = File(_abs(slug, from));
    if (!src.existsSync()) return false;
    final dest = File(_abs(slug, to));
    await dest.parent.create(recursive: true);
    if (dest.existsSync()) await dest.delete();
    await src.rename(dest.path);
    return true;
  }

  /// 列某个子目录下的文件名（不含子目录）。
  List<String> listFiles(String slug, String rel) {
    final d = Directory(_abs(slug, rel));
    if (!d.existsSync()) return const [];
    return d
        .listSync()
        .whereType<File>()
        .map((f) => p.basename(f.path))
        .toList()
      ..sort();
  }

  List<String> listDirs(String slug, String rel) {
    final d = Directory(_abs(slug, rel));
    if (!d.existsSync()) return const [];
    return d
        .listSync()
        .whereType<Directory>()
        .map((f) => p.basename(f.path))
        .toList()
      ..sort();
  }

  // ------------------------------------------------------- 校验 / 导出 / 安装

  /// 整棵工程目录按包文件读出来（与安装器同一套读法：文本读文本、二进制读空串）。
  Map<String, String> readPackFiles(String slug) {
    final root = Directory(dirOf(slug));
    if (!root.existsSync()) return const {};
    final rootPath = root.absolute.path.replaceAll('\\', '/');
    final files = <String, String>{};
    for (final f in root.listSync(recursive: true, followLinks: false)) {
      if (f is! File) continue;
      final abs = f.path.replaceAll('\\', '/');
      final rel = abs.substring(rootPath.length + 1);
      if (!isPackageContentPath(rel)) continue;
      final lower = rel.toLowerCase();
      files[rel] = lower.endsWith('.json')
          ? f.readAsStringSync()
          : (lower.endsWith('.md') || lower.endsWith('.txt')
              ? f.readAsStringSync()
              : '');
    }
    return files;
  }

  /// 体检：走**同一份** `PackageLoader` + `PackageValidator`。
  StudioCheckResult check(String slug) {
    final files = readPackFiles(slug);
    if (files.isEmpty) {
      return const StudioCheckResult(loaded: false, loadError: '工程目录是空的');
    }
    try {
      final content = PackageLoader.fromFiles(files);
      return StudioCheckResult(
        loaded: true,
        report: const PackageValidator().validate(content),
      );
    } catch (e) {
      return StudioCheckResult(loaded: false, loadError: '$e');
    }
  }

  /// 导出成 `.chatgal`（写到 `<rootDir>/exports/`，返回路径）。
  Future<ExportResult> exportZip(String slug) async {
    await flushWrites(slug);
    return installer.exportInstalled(dirOf(slug));
  }

  /// 版本比对：这个工程装到本地会是什么结果。
  Future<StudioInstallPlan> installPlan(String slug) async {
    await flushWrites(slug);
    final manifest = readJson(slug, 'manifest.json');
    final packageId = '${manifest?['packageId'] ?? ''}';
    final version = '${manifest?['version'] ?? ''}';
    final installed = packages
        .listInstalled()
        .where((r) => r.packageId == packageId)
        .toList();

    if (installed.isEmpty) {
      return StudioInstallPlan(
        verdict: StudioInstallVerdict.freshPackage,
        installed: const [],
        message: '本地还没有这个内容包，将新装 v$version。',
      );
    }
    final sameVersion = installed.where((r) => r.version == version).toList();
    if (sameVersion.isEmpty) {
      final versions = installed.map((r) => r.version).join('、');
      return StudioInstallPlan(
        verdict: StudioInstallVerdict.otherVersion,
        installed: installed,
        message: '本地已有同包名的其它版本（$versions），v$version 会作为新版本并存。',
      );
    }
    final incoming = await installer.hashOfDirectory(dirOf(slug));
    final identical = sameVersion.any((r) => r.contentHash == incoming);
    if (identical) {
      return StudioInstallPlan(
        verdict: StudioInstallVerdict.identical,
        installed: installed,
        message: '本地已有 v$version 且内容完全一致，装上去也是同一份。',
      );
    }
    return StudioInstallPlan(
      verdict: StudioInstallVerdict.contentConflict,
      installed: installed,
      message: '本地已装 v$version，但这份工程的内容不一样：同一个版本号不允许换内容'
          '（存档会绑到内容上）。把工程版本号改成 ${nextVersion(version)} 就能装。',
    );
  }

  /// 装到本地包（目录直接交给安装器：校验、哈希、原子落盘都走同一条路）。
  Future<InstallResult> installToPackages(String slug) async {
    await flushWrites(slug);
    return installer.installFromPath(dirOf(slug));
  }

  /// 版本号 +1（纯数字版本，`nextVersion('250') == '251'`）。
  static String nextVersion(String version) {
    final n = int.tryParse(version);
    return n == null ? '1' : '${n + 1}';
  }

  // ---------------------------------------------------------------- 内部

  String _reserveSlug(String hint) {
    final base = _sanitize(hint);
    var candidate = base.isEmpty ? 'project' : base;
    var i = 2;
    while (Directory(dirOf(candidate)).existsSync()) {
      candidate = '$base $i';
      i++;
    }
    return candidate;
  }

  /// 目录名清洗：去掉 Windows/Android 上非法或危险的字符，压空白、限长度。
  static String _sanitize(String raw) {
    final cleaned = raw
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleaned.isEmpty) return '';
    return cleaned.length <= 60 ? cleaned : cleaned.substring(0, 60).trim();
  }

  Future<void> _copyTree(Directory src, Directory dest) async {
    await dest.create(recursive: true);
    for (final entity in src.listSync(recursive: true, followLinks: false)) {
      final rel =
          p.relative(entity.path, from: src.path).replaceAll('\\', '/');
      // 与安装器共用同一份「包内容」判据：`*.tmp`（原子写的临时文件）与点前缀
      // 残留不进工程量 —— 否则它们会被「装到本地」和导出原样带进包里。
      if (!isPackageContentPath(rel)) continue;
      final target = p.joinAll([dest.path, ...rel.split('/')]);
      if (entity is Directory) {
        await Directory(target).create(recursive: true);
      } else if (entity is File) {
        await File(target).parent.create(recursive: true);
        await entity.copy(target);
      }
    }
  }
}
