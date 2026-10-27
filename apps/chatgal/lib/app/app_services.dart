import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:gal_protocol/gal_protocol.dart';
import 'package:gal_storage/gal_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../features/settings/api_settings.dart';
import 'app_logger.dart';

/// App-level protocol wrapper; personality text lives in the package prompt.
///
/// 聊天请求**只要台词**，不要 JSON。
///
/// 真机日志（2026-09-15）显示：把「写台词 + 严格 JSON + 逐段选立绘」三件事一起
/// 压给一个请求时，模型会直接放弃 JSON 回纯文本。现在职责拆开 —— 这个请求只管
/// 写，立绘与情绪节拍交给常驻的「立绘 agent」（`look_agent.dart`）。壳也因此变短，
/// 漂移更少。
String genericSystemPrompt(String characterName) {
  return '''
你是真实存在的人类角色「$characterName」，绝不承认自己是AI。
直接写你要说的话：可以带全角括号（）里的动作与心理描写；一两段到几段都行。

硬性要求：
- **不要输出 JSON、不要输出解释、不要重复玩家的台词**，就写角色说的话。
- **不要输出任何数值改动**：数值由场景结束时的结算统一处理。
''';
}

/// 一段回复最终用哪个情绪标签、哪张立绘。
class ResolvedLook {
  const ResolvedLook({
    required this.expression,
    required this.portrait,
    required this.fromModel,
    this.quality = LookQuality.exact,
  });

  final String expression;
  final String portrait;

  /// 是否为「模型真的给了可用选择」。false = 这一段被兜底了（用于诊断/修复判据）。
  final bool fromModel;
  final LookQuality quality;

  /// 这一段是不是靠兜底拿到的表情。
  bool get degraded =>
      quality == LookQuality.sceneDefault || quality == LookQuality.keptCurrent;
}

/// 立绘解析的质量分级（日志与「要不要发一次修复请求」都看它）。
enum LookQuality {
  /// 模型给的 portraitId 逐字命中本幕立绘表。
  exact,

  /// 没有合法立绘名，但情绪词能映射到本幕的一张。
  emotionMapped,

  /// 都没有 → 用**场景默认表情**兜底（稳定，不再换）。
  sceneDefault,

  /// 连场景默认都没有 → 保持当前这张脸（不乱动）。
  keptCurrent,
}

/// 把模型每段返回的 (expressionId, portraitId) 归一成本幕真正用得上的立绘键。
///
/// 纯函数（便于单测）。判据是「每一段都要有合法立绘」：
/// 1. portraitId 逐字命中本幕立绘表 → [LookQuality.exact]；
/// 2. 只给了情绪词 → 在本幕立绘表里找同情绪的那一张 → [LookQuality.emotionMapped]；
/// 3. 都没用 → 退回**场景默认表情**（[LookQuality.sceneDefault]），
///    连场景默认都没有就保持当前这张脸（[LookQuality.keptCurrent]）。
///
/// 第 3 步以前是「按声明顺序往前轮换一格」——那等于**用换脸掩盖失败**：
/// 模型持续不合规时角色照样一张张换表情，而表情和台词完全无关。
/// 现在改成稳定兜底，调用方据此记录诊断，并最多发一次修复请求。
List<ResolvedLook> resolveSegmentLooks({
  required List<({String expression, String portrait})> segments,
  List<String> portraitOptions = const [],
  List<String> emotions = const [],
  String defaultEmotion = '',
  String current = '',
}) {
  final out = <ResolvedLook>[];
  final pool = <String>[
    ...emotions,
    if (emotions.isEmpty && defaultEmotion.isNotEmpty) defaultEmotion,
  ];
  // 兜底用「场景默认表情」，拿不到就保持当前这张脸。
  final fallbackEmotion = defaultEmotion.trim().isNotEmpty
      ? defaultEmotion.trim()
      : (pool.isNotEmpty ? pool.first : '');

  for (final seg in segments) {
    final want = seg.portrait.trim();
    final expr = seg.expression.trim();

    // 1. 立绘逐字命中
    if (want.isNotEmpty && portraitOptions.contains(want)) {
      out.add(ResolvedLook(
        expression: _emotionOf(want, pool) ?? expr,
        portrait: want,
        fromModel: true,
        quality: LookQuality.exact,
      ));
      continue;
    }
    // 2. 给了情绪词 → 找本幕立绘表里同情绪的一张
    final matched = _matchEmotion(expr.isNotEmpty ? expr : want, pool);
    if (matched != null) {
      final key = _portraitOfEmotion(portraitOptions, matched);
      out.add(ResolvedLook(
        expression: matched,
        portrait: key ?? '',
        fromModel: true,
        quality: LookQuality.emotionMapped,
      ));
      continue;
    }
    // 3. 稳定兜底：场景默认表情；没有就保持当前
    if (fallbackEmotion.isEmpty) {
      out.add(ResolvedLook(
        expression: current,
        portrait: _portraitOfEmotion(portraitOptions, current) ?? '',
        fromModel: false,
        quality: LookQuality.keptCurrent,
      ));
      continue;
    }
    out.add(ResolvedLook(
      expression: fallbackEmotion,
      portrait: _portraitOfEmotion(portraitOptions, fallbackEmotion) ?? '',
      fromModel: false,
      quality: LookQuality.sceneDefault,
    ));
  }
  return out;
}

/// 一条回复的立绘诊断摘要（写进运行日志，便于区分是「模型没给」还是「给了但不合法」）。
String describeLookDiagnostics({
  required List<({String expression, String portrait})> segments,
  required List<ResolvedLook> looks,
  required List<String> portraitOptions,
  required List<String> emotions,
  required String state,
  required String current,
  String? rawText,
}) {
  final raw = (rawText ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
  final snippet = raw.length > 160 ? '${raw.substring(0, 160)}…' : raw;
  final shape = raw.isEmpty
      ? '空'
      : (raw.startsWith('{') || raw.contains('```') ? 'JSON' : '非 JSON（纯文本）');
  final segDesc = <String>[];
  for (var i = 0; i < segments.length; i++) {
    final q = i < looks.length ? looks[i].quality.name : '?';
    segDesc.add('#${i + 1} portraitId=「${segments[i].portrait}」'
        ' expressionId=「${segments[i].expression}」→ $q');
  }
  final degraded = looks.where((l) => l.degraded).length;
  return '立绘诊断：回答形态=$shape 段数=${segments.length} 兜底段数=$degraded'
      ' 当前形态=「$state」当前表情=「$current」'
      ' 候选立绘(${portraitOptions.length})=${portraitOptions.take(4).join('、')}'
      ' 情绪表(${emotions.length})=${emotions.take(6).join('、')}'
      ' 逐段=${segDesc.join(' | ')} 原始=${snippet.isEmpty ? '(空)' : snippet}';
}

/// 「便服_害羞」→「害羞」（取最后一个下划线之后的段）。
String? _emotionOf(String portraitName, List<String> pool) {
  final i = portraitName.lastIndexOf('_');
  final tail = i >= 0 ? portraitName.substring(i + 1) : portraitName;
  if (pool.isEmpty) return tail.isEmpty ? null : tail;
  return _matchEmotion(tail, pool) ?? (tail.isEmpty ? null : tail);
}

/// 在包内声明里找与 [word] 对应的情绪词：先精确，再包含匹配
/// （模型答「有点害羞」时对到「害羞」）。
String? _matchEmotion(String word, List<String> pool) {
  final w = word.trim();
  if (w.isEmpty) return null;
  if (pool.contains(w)) return w;
  for (final e in pool) {
    if (e.isEmpty) continue;
    if (w.contains(e) || e.contains(w)) return e;
  }
  return null;
}

/// 本幕立绘表里情绪为 [emotion] 的那一张（键形如「状态_情绪」）。
String? _portraitOfEmotion(List<String> options, String emotion) {
  for (final k in options) {
    final i = k.lastIndexOf('_');
    if (i < 0) continue;
    if (k.substring(i + 1) == emotion) return k;
  }
  for (final k in options) {
    if (k.endsWith(emotion)) return k;
  }
  return null;
}

/// 立绘键的候选顺序（纯函数，便于测试）：
/// 1 请求值精确命中（模型给的完整立绘名）
/// 2 本幕状态_请求值（模型只给了情绪词）
/// 3 本幕状态_角色默认表情
/// 4 默认状态_请求值
/// 5 默认状态_默认表情
/// 一个都不认识时列表仍会返回，由调用方按「包内映射 → 直读文件」逐个试，
/// 全失败就降级为占位图 —— 不猜、不写死任何角色 id。
List<String> portraitCandidates({
  required String state,
  required String requested,
  required String defaultEmotion,
  required String defaultState,
  List<String> emotions = const [],
}) {
  final req = requested.trim();
  return <String>[
    if (req.isNotEmpty) req,
    if (req.isNotEmpty && state.isNotEmpty) '${state}_$req',
    // 模型答的是「有点害羞」这类带修饰的词时，拿包自己声明的情绪词做包含匹配。
    // 不做这一步，所有没被识别的答案都会落到同一张默认立绘 —— 表现就是
    // 「立绘能动但几乎不动」。
    for (final e in emotions)
      if (req.isNotEmpty &&
          state.isNotEmpty &&
          e != req &&
          (req.contains(e) || e.contains(req)))
        '${state}_$e',
    if (state.isNotEmpty && defaultEmotion.isNotEmpty)
      '${state}_$defaultEmotion',
    if (req.isNotEmpty && !req.contains('_') && defaultState.isNotEmpty)
      '${defaultState}_$req',
    if (defaultState.isNotEmpty && defaultEmotion.isNotEmpty)
      '${defaultState}_$defaultEmotion',
  ];
}

/// Full play context from an installed package.
class PlaySessionData {
  const PlaySessionData({
    required this.characterName,
    required this.packageTitle,
    required this.packageIntro,
    required this.characterPrompt,
    required this.content,
    required this.installDir,
    this.portraitExpressionIds = const [],
    this.sceneGraph,
    this.eventDefs = const {},
  });

  final String characterName;
  final String packageTitle;
  final String packageIntro;

  /// 角色**原始人格**（character.json 的 prompt，不混协议壳）。
  /// 协议壳固定由应用在组消息时拼上，这样换角色时壳不用跟着重算，
  /// 人格里含 "JSON"/"protocolVersion" 也不会误跳过壳。
  final String characterPrompt;
  final PackageContent content;
  final String installDir;
  final List<String> portraitExpressionIds;
  final SceneGraph? sceneGraph;
  final Map<String, EventDef> eventDefs;

  /// 当前组装用的系统提示词：协议壳 + 角色人格。
  /// [charId] 为空时退回第一个角色（单角色包兼容）。
  String systemPromptFor([String? charId]) {
    final char = characterOf(charId);
    final name = char?.id ?? characterName;
    final prompt = (char?.prompt ?? characterPrompt).trim();
    final shell = genericSystemPrompt(name);
    if (prompt.isEmpty) return shell;
    return '$prompt\n\n$shell';
  }

  /// 兼容旧调用点：默认第一个角色的完整系统提示词。
  String get systemPrompt => systemPromptFor();

  /// 本幕的角色提示词：**只来自角色块**（`characters[].scenePrompt`）。
  /// 角色基础人格在 `characters/<id>/character.json` 的 `prompt` 里。
  String scenePromptFor(String sceneId, String charId) {
    final scene = content.scenes[sceneId];
    if (scene == null) return '';
    for (final c in scene.characters) {
      if (c.charId == charId) return c.scenePrompt;
    }
    return '';
  }

  CharacterDef? get primaryCharacter =>
      content.characters.isEmpty ? null : content.characters.first;

  /// 按 id 取角色；没有传 id 时退回包内第一个角色（兼容单角色包）。
  CharacterDef? characterOf(String? id) {
    if (id != null && id.isNotEmpty) {
      final found = content.character(id);
      if (found != null) return found;
    }
    return primaryCharacter;
  }

  /// 包内声明的情绪词（expressionId 的唯一来源）。没有角色时为空表。
  /// [charId] 传当前幕出场角色时按那个角色取；不传退回第一个角色。
  List<String> primaryEmotions([String? charId]) =>
      characterOf(charId)?.emotions ?? const [];

  /// 默认形态（场景没写 state 时的兜底形态）。
  String primaryDefaultState([String? charId]) =>
      characterOf(charId)?.defaultState ?? '';

  /// 本幕实际生效的形态：场景没声明 state 时退回包声明的默认形态，
  /// 否则立绘表会是空的，模型没得选 → 表情永远不动。
  String effectiveState(String state, [String? charId]) =>
      state.isNotEmpty ? state : primaryDefaultState(charId);

  /// 把「模型给的立绘名 / 表情词」解析成文件。
  ///
  /// 立绘只靠**命名约定**：`characters/<id>/<状态>_<情绪>.png`（不再有
  /// portraits 映射表）。全部基于包内声明，不认识任何写死的角色 id：
  /// 1. 请求值精确命中（模型给的完整立绘名）
  /// 2. 「本幕状态_请求值」（模型只回了表情词时）
  /// 3. 「本幕状态_角色默认表情」/「默认状态_请求值」/「默认状态_默认表情」
  /// 都失败 → null，界面走占位图。答案不在表里时优雅降级，不猜。
  String? portraitPath({String state = '', String requested = '', String charId = ''}) {
    final char = characterOf(charId.isEmpty ? null : charId);
    if (char == null) return null;
    final candidates = portraitCandidates(
      state: effectiveState(state, char.id),
      requested: requested,
      defaultEmotion: char.defaultEmotion,
      defaultState: char.defaultState,
      emotions: char.emotions,
    );
    for (final key in candidates) {
      final direct = File(p.join(installDir, 'characters', char.id, '$key.png'));
      if (direct.existsSync() && direct.lengthSync() > 0) return direct.path;
    }
    return null;
  }

  /// 本幕可用的立绘名（该状态下的全部表情），提交给模型让它挑一张。
  /// `states × emotions` 必须齐全（校验器保证），所以这里按情绪词直接拼键。
  List<String> availablePortraits({required String state, String charId = ''}) {
    final char = characterOf(charId.isEmpty ? null : charId);
    if (char == null) return const [];
    final st = effectiveState(state, char.id);
    if (st.isEmpty) return const [];
    return [for (final e in char.emotions) '${st}_$e'];
  }

  /// 按场景声明的文件名解析背景（v2：`stories/<文件名>`，也可以是包内相对路径）。
  /// 找不到就返回 null —— 调用方留空，不要退到某个"默认背景"。
  String? sceneBackgroundPath(String? backgroundFile) {
    if (backgroundFile == null || backgroundFile.isEmpty) return null;
    final rel =
        backgroundFile.contains('/') ? backgroundFile : 'stories/$backgroundFile';
    final f = File(p.join(installDir, rel));
    if (f.existsSync() && f.lengthSync() > 0) return f.path;
    final f2 = File(p.join(installDir, backgroundFile));
    if (f2.existsSync() && f2.lengthSync() > 0) return f2.path;
    return null;
  }

  /// 事件某张 slide 的图片：先按 `events/<事件 id>/<文件名>` 找，再按包内相对路径找。
  /// 找不到就返回 null（调用方不带图，只显示文字）。
  String? eventAssetPath(String eventId, String image) {
    if (image.isEmpty) return null;
    final candidates = <String>[
      if (!image.contains('/')) 'events/$eventId/$image',
      image,
    ];
    for (final rel in candidates) {
      final f = File(p.join(installDir, rel));
      if (f.existsSync() && f.lengthSync() > 0) return f.path;
    }
    return null;
  }

  /// 主页底图：约定就是包根的 `home.png`（打包脚本与 AUTHOR_GUIDE 都这么写）。
  String? homeAsset() {
    final f = File(p.join(installDir, 'home.png'));
    if (f.existsSync() && f.lengthSync() > 0) return f.path;
    return null;
  }
}

/// 启动阶段内容包不可用（首次启动、且默认包也没装成功）。
class PackageBootException implements Exception {
  PackageBootException(this.error);

  final ValidationError? error;

  @override
  String toString() {
    final message = error?.message ?? '未知错误';
    final code = error?.code == null ? '' : '（${error!.code}）';
    return '内容包不可用：$message$code';
  }
}

/// App services: installer, packages, saves, api settings.
class AppServices {
  AppServices._(this.root);

  final Directory root;
  late final PackageInstaller installer = PackageInstaller(rootDir: root.path);
  late final PackageStore packages = PackageStore(root.path);
  late final SaveRepository saves =
      SaveRepository(rootDir: root.path, packages: packages);
  late final ApiSettingsStore api = ApiSettingsStore(root.path);

  /// 启动时留下的内容包警告（null = 一切正常）。
  /// 已有可用包、只是这次升级失败时写这里：允许进游戏，但要如实提示。
  String? bootWarning;

  /// 内容包创作台的工程存储（工程目录本身就是一棵合法的包目录树）。
  late final StudioStore studio = StudioStore(
    rootDir: root.path,
    installer: installer,
    packages: packages,
  );

  static Future<AppServices> open() async {
    final docs = await getApplicationDocumentsDirectory();
    final root = Directory(p.join(docs.path, 'chatgal_data'));
    await root.create(recursive: true);
    final services = AppServices._(root);
    await services.ensureBootablePackage();
    return services;
  }

  /// 启动前确保有一个**可用**的内容包。
  ///
  /// * 已有可用包、只是这次更新失败 → 允许进入，但留下 [bootWarning] 提示；
  /// * 装完仍没有任何可用包 → 抛 [PackageBootException]，走启动错误页。
  ///
  /// 教学包（daily）**不挡开屏**：默认包就绪后立刻放行，装包在后台继续。
  /// 曾把它串在默认包安装末尾 —— 首启要再解压/拷贝十几 MB 立绘，用户会以为
  /// 卡死在「正在准备默认包」；强杀后默认包已是最新，下次启动又提前 return，
  /// 教学包永远装不上。
  Future<void> ensureBootablePackage({List<int>? zipBytes}) async {
    final result = await ensureDefaultPackage(zipBytes: zipBytes);
    // 教学包后台装：失败只记日志，绝不影响进入游戏。
    unawaited(ensureDailyPackageQuietly());
    if (result == null || result.ok) {
      bootWarning = null;
      return;
    }
    final installed = packages.listInstalled();
    if (installed.isNotEmpty) {
      final keep = installed.first;
      bootWarning = '默认内容包更新失败：${result.error?.message ?? '未知错误'}；'
          '继续使用已安装的「${keep.displayName ?? keep.packageId}」v${keep.version}';
      appLog.w('install', bootWarning!);
      return;
    }
    appLog.e('install', '启动失败：没有任何可用内容包');
    throw PackageBootException(result.error);
  }

  factory AppServices.forTestRoot(Directory root) {
    root.createSync(recursive: true);
    return AppServices._(root);
  }

  static const defaultPackageId = 'top.rongshangs.hellojj.default';

  /// 默认包版本号（**纯数字**，与 `content/default_v2/manifest.json` 的
  /// `version` 必须同改；打包脚本会拦不一致与「版本没往高升」）。
  static const defaultPackageVersion = '264';

  /// 内置教学包「与戒戒的每一天」：三幕循环，用于理解 stories 出口。
  static const dailyPackageId = 'top.rongshangs.hellojj.daily';
  static const dailyPackageVersion = '9';

  /// 内置包 id 集合：主页/包库禁止删除。
  static const builtInPackageIds = <String>{
    defaultPackageId,
    dailyPackageId,
  };

  /// 「已是最新」不能只看版本号与哈希前缀：manifest 与 `.content_hash` 都在、
  /// 但包内 `stories/` 被删或被截断时，启动会一直判定最新，而游戏里又读不出来，
  /// 内置包还禁止删除 —— 玩家只能清应用数据。这里只做一次极轻的探针（列目录），
  /// 不解析内容；探针不过就当作没装、直接重装一遍。
  bool _packageLooksReadable(PackageRef ref) {
    final dir = Directory(packages.installDirOf(ref));
    if (!dir.existsSync()) return false;
    final stories = Directory(p.join(dir.path, 'stories'));
    if (!stories.existsSync()) return false;
    return stories
        .listSync()
        .any((e) => e is File && e.path.toLowerCase().endsWith('.json'));
  }

  /// `staging_in` 只是「把内置包字节落成文件再交给安装器」的中转。
  /// 装完马上删（[_installFromStaging]），这里再扫一次陈旧残留，
  /// 回收历史版本留下的一整份包副本（默认包 + 教学包合计约 83MB）。
  /// 只删 1 小时前的文件：正在写的那份绝不会被误删。
  Future<void> _cleanStaleStaging() async {
    try {
      final dir = Directory(p.join(root.path, 'staging_in'));
      if (!dir.existsSync()) return;
      final cutoff = DateTime.now().subtract(const Duration(hours: 1));
      await for (final e in dir.list()) {
        if (e is! File) continue;
        try {
          if (e.statSync().modified.isAfter(cutoff)) continue;
          await e.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// 有没有存档正绑在这一份内容包上（同 id + 同版本 + 同哈希）。
  /// 读存档失败时按「有」处理：多留一份空间，好过把玩家的档指到别的内容上。
  bool _isReferencedBySave(PackageRef ref) {
    try {
      return saves.listSaves().any((s) {
        final r = s.packageRef;
        return r.packageId == ref.packageId &&
            r.version == ref.version &&
            r.contentHash == ref.contentHash;
      });
    } catch (_) {
      return true;
    }
  }

  /// 装完就把中转文件删掉：那是 60MB 级的整包副本，留着会永久占用户空间。
  /// 放进 finally 是为了失败/异常路径也不留残骸。
  Future<InstallResult> _installFromStaging(File tmp) async {
    try {
      return await installer.installFromPath(tmp.path);
    } finally {
      try {
        if (tmp.existsSync()) await tmp.delete();
      } catch (_) {}
      await _cleanStaleStaging();
    }
  }

  Future<InstallResult?> ensureDefaultPackage({
    List<int>? zipBytes,
  }) async {
    final existing = packages
        .listInstalled()
        .where((r) => r.packageId == defaultPackageId)
        .toList();
    // 版本匹配、哈希算法是当前版本（v2 前缀），**而且包真的读得出来**才算「已是最新」。
    // 旧 v1 哈希（无前缀，只哈希文本）需要重装升级到 v2（含图片字节）。
    final upToDate = existing.any((r) =>
        r.version == defaultPackageVersion &&
        r.contentHash.startsWith('v2:') &&
        _packageLooksReadable(r));
    if (upToDate) return null;

    Uint8List bytes;
    if (zipBytes != null) {
      bytes = Uint8List.fromList(zipBytes);
    } else {
      bytes = await rootBundle
          .load('assets/hellojj_default.chatgal')
          .then((d) => d.buffer.asUint8List());
    }
    final tmp =
        File(p.join(root.path, 'staging_in', 'hellojj_default.chatgal'));
    await tmp.parent.create(recursive: true);
    await tmp.writeAsBytes(bytes, flush: true);
    final result = await _installFromStaging(tmp);
    if (result.ok) {
      appLog.i('install',
          '默认内容包已就绪：v$defaultPackageVersion，${bytes.length} 字节');
      for (final old in packages
          .listInstalled()
          .where((r) =>
              r.packageId == defaultPackageId &&
              r.version != defaultPackageVersion)
          .toList()) {
        if (_isReferencedBySave(old)) {
          appLog.w('install', '保留旧版默认包 v${old.version}：仍有存档引用它');
          continue;
        }
        appLog.i('install', '清理旧版本默认包 v${old.version}');
        await packages.uninstall(old);
      }
    } else {
      appLog.e('install',
          '默认内容包安装失败：${result.error ?? '未知错误'}');
    }
    return result;
  }

  /// 后台装教学包：任何异常只记日志，不抛给启动路径。
  Future<void> ensureDailyPackageQuietly({List<int>? zipBytes}) async {
    try {
      await ensureDailyPackage(zipBytes: zipBytes);
    } catch (e) {
      appLog.e('install', '教学包安装异常（不影响进入游戏）', e);
    }
  }

  Future<InstallResult?> ensureDailyPackage({
    List<int>? zipBytes,
  }) async {
    final existing = packages
        .listInstalled()
        .where((r) => r.packageId == dailyPackageId)
        .toList();
    final upToDate = existing.any((r) =>
        r.version == dailyPackageVersion &&
        r.contentHash.startsWith('v2:') &&
        _packageLooksReadable(r));
    if (upToDate) return null;

    Uint8List bytes;
    if (zipBytes != null) {
      bytes = Uint8List.fromList(zipBytes);
    } else {
      bytes = await rootBundle
          .load('assets/hellojj_daily.chatgal')
          .then((d) => d.buffer.asUint8List());
    }
    final tmp =
        File(p.join(root.path, 'staging_in', 'hellojj_daily.chatgal'));
    await tmp.parent.create(recursive: true);
    await tmp.writeAsBytes(bytes, flush: true);
    final result = await _installFromStaging(tmp);
    if (result.ok) {
      appLog.i('install',
          '教学包「与戒戒的每一天」已就绪：v$dailyPackageVersion，${bytes.length} 字节');
      for (final old in packages
          .listInstalled()
          .where((r) =>
              r.packageId == dailyPackageId &&
              r.version != dailyPackageVersion)
          .toList()) {
        // 有存档绑着就留着，别让那份档悄悄接到新包内容上。
        if (_isReferencedBySave(old)) continue;
        await packages.uninstall(old);
      }
    } else {
      appLog.e('install',
          '教学包安装失败（不影响进入游戏）：${result.error ?? '未知错误'}');
    }
    return result;
  }

  PackageRef? defaultPackageRef() {
    for (final r in packages.listInstalled()) {
      if (r.packageId == defaultPackageId) return r;
    }
    return null;
  }

  Map<String, String> _readPackageFiles(PackageRef ref) {
    final dir = Directory(packages.installDirOf(ref));
    if (!dir.existsSync()) return {};
    final rootPath = dir.absolute.path.replaceAll('\\', '/');
    final files = <String, String>{};
    for (final f in dir.listSync(recursive: true)) {
      if (f is! File) continue;
      final abs = f.path.replaceAll('\\', '/');
      final rel = abs.substring(rootPath.length + 1);
      if (rel.startsWith('.')) continue;
      final lower = rel.toLowerCase();
      // 包里只有 JSON 是文本（manifest / character / story / event）；
      // 图片按空串进 files（加载器只关心它们存在）。
      if (lower.endsWith('.json')) {
        files[rel] = f.readAsStringSync();
      } else {
        files[rel] = '';
      }
    }
    return files;
  }

  PlaySessionData? loadPlaySession(PackageRef ref) {
    final files = _readPackageFiles(ref);
    if (files.isEmpty) return null;
    try {
      final content = PackageLoader.fromFiles(files);
      // 游戏内显示的**包名**走 manifest.name；角色自己的名字是角色目录名。
      final packageTitle = content.manifest.name;
      final characterName = content.characters.isEmpty
          ? packageTitle
          : content.characters.first.id;
      // 基础人格：character.json 的 `prompt`（内联，不再有 promptFile）。
      // 只存原始人格，协议壳由 systemPromptFor() 在组消息时固定拼上 ——
      // 这样换角色时壳不用重算，人格里含 "JSON" 也不会误跳过壳。
      var prompt = '';
      for (final c in content.characters) {
        if (c.prompt.trim().isNotEmpty) {
          prompt = c.prompt;
          break;
        }
      }
      return PlaySessionData(
        characterName: characterName,
        packageTitle: packageTitle,
        packageIntro: content.manifest.description,
        characterPrompt: prompt,
        content: content,
        installDir: packages.installDirOf(ref),
        portraitExpressionIds: content.characters.isEmpty
            ? const []
            : content.characters.first.emotions,
        sceneGraph: content.sceneGraph,
        eventDefs: content.eventDefs,
      );
    } catch (e) {
      // 原来这里静默吞异常：包读不出来时玩家只看到「未选择内容包」，
      // 日志里至少留下是哪一步炸的。
      appLog.e('package',
          '读取内容包失败：${ref.packageId} v${ref.version}', e);
      return null;
    }
  }

  List<PackageRef> listPackagesForHome() {
    final all = packages.listInstalled();
    final def = all.where((r) => r.packageId == defaultPackageId).toList();
    PackageRef? defaultRef;
    for (final r in def) {
      if (r.version == defaultPackageVersion) {
        defaultRef = r;
        break;
      }
    }
    defaultRef ??= def.isNotEmpty ? def.first : null;
    PackageRef? dailyRef;
    for (final r in all.where((r) => r.packageId == dailyPackageId)) {
      if (r.version == dailyPackageVersion) {
        dailyRef = r;
        break;
      }
    }
    final dailyAll = all.where((r) => r.packageId == dailyPackageId).toList();
    dailyRef ??= dailyAll.isNotEmpty ? dailyAll.first : null;
    final rest = all
        .where((r) =>
            r.packageId != defaultPackageId &&
            r.packageId != dailyPackageId)
        .toList();
    return [
      if (defaultRef != null) defaultRef,
      if (dailyRef != null) dailyRef,
      ...rest,
    ];
  }

  /// 包里显示的包名：manifest.name（游戏内标题、内容包与存档页都用它）。
  String packageDisplayName(PackageRef ref) {
    final session = loadPlaySession(ref);
    if (session != null) return session.packageTitle;
    return ref.displayName ?? ref.packageId;
  }
}
