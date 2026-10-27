import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gal_ai/gal_ai.dart';
import 'package:gal_protocol/gal_protocol.dart';
import 'package:path/path.dart' as p;

import '../../app/app_logger.dart';
import '../session/chat_layout.dart';
import '../tts/tts_service.dart';
import '../tts/tts_settings.dart';
import 'chat_font.dart';

/// OpenAI-compatible GET /models helper.
class ModelsClient {
  ModelsClient({HttpClient? client}) : _client = client ?? HttpClient();

  HttpClient? _client;
  bool _closedByTimeout = false;

  HttpClient _ensureClient() {
    // 超时强关后 client 不可复用：重建一个，否则重试会抛 StateError。
    if (_closedByTimeout || _client == null) {
      _client = HttpClient();
      _closedByTimeout = false;
    }
    return _client!;
  }

  Future<List<String>> listModels({
    required String endpoint,
    required String apiKey,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final base = endpoint.endsWith('/')
        ? endpoint.substring(0, endpoint.length - 1)
        : endpoint;
    final uri = Uri.parse('$base/models');
    final client = _ensureClient();
    // 对完整请求生命周期设截止时间：getUrl 的 timeout 只覆盖建连，
    // 读响应头/响应体没有超时，服务端挂起时会永远卡住。
    final result = await Future<({int status, String body})>(() async {
      final req = await client.getUrl(uri);
      // 本地服务可以没有 Key：空值不附带 Authorization，由服务端决定是否需要。
      if (apiKey.isNotEmpty) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
      }
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      return (status: resp.statusCode, body: body);
    }).timeout(
      timeout,
      onTimeout: () {
        try {
          client.close(force: true);
          _closedByTimeout = true;
        } catch (_) {}
        throw TimeoutException('模型列表请求超时');
      },
    );
    if (result.status != 200) {
      throw Exception('HTTP ${result.status}: ${_short(result.body)}');
    }
    final decoded = jsonDecode(result.body);
    if (decoded is! Map || decoded['data'] is! List) {
      throw Exception('unexpected models payload');
    }
    final ids = <String>[];
    for (final item in decoded['data'] as List) {
      if (item is Map && item['id'] is String) {
        ids.add(item['id'] as String);
      }
    }
    ids.sort();
    return ids;
  }

  String _short(String s) => s.length > 180 ? '${s.substring(0, 180)}…' : s;
}

/// One saved provider preset.
class ProviderPreset {
  const ProviderPreset({
    required this.id,
    required this.name,
    required this.endpoint,
    required this.apiKey,
    required this.model,
    this.enabled = true,
    this.isLocal = false,
  });

  final String id;
  final String name;
  final String endpoint;
  final String apiKey;
  final String model;
  final bool enabled;

  /// 本地模型（llama.cpp / Ollama / LM Studio 等进程内服务）：不需要 API Key。
  final bool isLocal;

  ProviderPreset copyWith({
    String? name,
    String? endpoint,
    String? apiKey,
    String? model,
    bool? enabled,
    bool? isLocal,
  }) {
    return ProviderPreset(
      id: id,
      name: name ?? this.name,
      endpoint: endpoint ?? this.endpoint,
      apiKey: apiKey ?? this.apiKey,
      model: model ?? this.model,
      enabled: enabled ?? this.enabled,
      isLocal: isLocal ?? this.isLocal,
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'endpoint': endpoint,
        'apiKey': apiKey,
        'model': model,
        'enabled': enabled,
        'isLocal': isLocal,
      };

  factory ProviderPreset.fromJson(Map<String, Object?> json) {
    return ProviderPreset(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? '未命名供应商'}',
      endpoint: '${json['endpoint'] ?? ''}',
      apiKey: '${json['apiKey'] ?? ''}',
      model: '${json['model'] ?? ''}',
      enabled: json['enabled'] != false,
      isLocal: json['isLocal'] as bool? ?? false,
    );
  }

  ProviderConfig toConfig() => ProviderConfig(
        endpoint: endpoint,
        model: model,
        apiKey: apiKey,
        temperature: 0.8,
        maxTokens: 2048,
      );
}

/// App settings: theme + provider presets (plaintext under app data).
class ApiSettingsStore implements ApiSettingsLike {
  ApiSettingsStore(this.rootDir);

  final String rootDir;
  final ModelsClient modelsClient = ModelsClient();

  String get _path => p.join(rootDir, 'app_settings.json');

  /// 设置文件路径（日志页/提示要用）。
  String get settingsPath => _path;

  /// 写入串行化 + 临时文件替换。
  ///
  /// 之前这里直接 `writeAsString` 整份覆盖：两个页面/滑条并发保存会互相盖，
  /// 写到一半被杀会留下半截 JSON，而下一次 `load()` 解析失败又**静默**返回默认值
  /// ——供应商、字体、语音配置就这么被默认值盖掉了（复审 P1）。
  /// 现在：串行队列保证不并发；先写 `.tmp` 再在同一目录改名替换，
  /// 任何时刻磁盘上都是一个完整文件。
  Future<void> _writeQueue = Future<void>.value();

  /// 最近一次读取失败的原因（null = 正常）。设置页据此提示，
  /// 而不是把「解析失败」和「从没配置过」当成同一件事。
  String? loadError;

  /// 损坏文件的备份只做一次：第一次读到坏文件时留着它，
  /// 免得后续每次 load 都覆盖掉最能说明问题的原始内容。
  bool get hasCorruptBackup =>
      File('$_path.corrupt').existsSync();

  AppSettings load() {
    final f = File(_path);
    if (!f.existsSync()) return AppSettings.empty;
    String raw;
    try {
      raw = f.readAsStringSync();
    } catch (e) {
      loadError = '设置文件读取失败：$e';
      return AppSettings.empty;
    }
    // 空文件不是损坏：`clear()` 之后就是这个样子。
    if (raw.trim().isEmpty) {
      loadError = null;
      return AppSettings.empty;
    }
    try {
      final parsed = _parse(raw);
      loadError = null;
      return parsed;
    } catch (e) {
      _preserveCorrupt(e);
      return AppSettings.empty;
    }
  }

  /// 解析失败：把原文件另存一份 `.corrupt`，并记下原因。
  void _preserveCorrupt(Object error) {
    loadError = '设置文件解析失败：$error';
    try {
      final src = File(_path);
      final backup = File('$_path.corrupt');
      if (src.existsSync() && !backup.existsSync()) {
        src.copySync(backup.path);
      }
    } catch (_) {}
    appLog.e('settings', '设置文件损坏，已保留备份：$_path.corrupt', error);
  }

  AppSettings _parse(String raw) {
    final m = jsonDecode(raw) as Map<String, dynamic>;
    final list = (m['providers'] as List? ?? const [])
        .map((e) => ProviderPreset.fromJson(Map<String, Object?>.from(e as Map)))
        .toList();
    final fonts = (m['importedFonts'] as List? ?? const [])
        .map((e) =>
            ImportedChatFont.fromJson(Map<String, Object?>.from(e as Map)))
        .toList();
    var fontId = '${m['chatFontId'] ?? kSystemFontId}';
    final known = <String>{
      for (final f2 in kChatFontPresets) f2.id,
      for (final f2 in fonts) f2.id,
    };
    // 指向一个已经不存在的字体（导入了又删掉）时退回系统默认，
    // 否则聊天页会拿到一个空族名、静默变回默认却还显示着旧名字。
    if (!known.contains(fontId)) fontId = kSystemFontId;
    final padRead = _readChatBottomPad(m);
    return AppSettings(
        themeId: '${m['themeId'] ?? 'violet'}',
        providers: list,
        activeProviderId: m['activeProviderId'] as String?,
        lastPackageId: m['lastPackageId'] as String?,
        lastPackageVersion: m['lastPackageVersion'] as String?,
        lastSaveId: m['lastSaveId'] as String?,
        showBg: m['showBg'] as bool? ?? true,
        // 记忆阈值只在设置里：存档不再保存它们，进游戏时由这里灌给运行时。
        memory: m['memory'] is Map
            ? MemoryThresholds.fromJson(
                Map<String, Object?>.from(m['memory'] as Map),
              )
            : MemoryThresholds.defaults,
        replyLength: '${m['replyLength'] ?? 'short'}',
        portraitHeight: ChatLayout.portrait(
          (m['portraitHeight'] as num?)?.toDouble() ?? 200,
        ),
        chatBottomPad: padRead.value,
        chatBottomPadTouched: padRead.touched,
        autoRemoveBg: m['autoRemoveBg'] as bool? ?? false,
        noticeAgreed: m['noticeAgreed'] as bool? ?? false,
        chatFontId: fontId,
        chatFontSize: ((m['chatFontSize'] as num?)?.toDouble() ??
                kChatFontSizeDefault)
            .clamp(kChatFontSizeMin, kChatFontSizeMax),
        importedFonts: fonts,
        tts: m['tts'] is Map
            ? TtsSettings.fromJson(Map<String, Object?>.from(m['tts'] as Map))
            : const TtsSettings(),
        logMaxEntries: AppLogger.clampLimit(
          (m['logMaxEntries'] as num?)?.toInt() ??
              AppLogger.defaultMaxEntries,
        ),
        // 缺省 true：有网时流式体验更好；用户可在供应商页关掉
        streamOutput: m['streamOutput'] as bool? ?? true,
      );
  }

  /// 读出「消息流留白调整」，并处理默认值迁移。
  ///
  /// 历史包袱：这个值先后默认过 35、60，两次都被写进过用户的设置文件，而现
  /// 在的默认值是 0（底部整块已经被让开，再默认加一段就只是凭空的缝隙）。
  /// 光看数值分不出「用户手动拖出来的 60」和「上一版默认写进去的 60」，
  /// 所以从这一版起多存一个 `chatBottomPadTouched`：用户真的拖过滑条就置 true，
  /// 之后**任何**默认值变动都不再动他的值。
  static ({double value, bool touched}) _readChatBottomPad(
    Map<String, Object?> m,
  ) {
    final touched = m['chatBottomPadTouched'] as bool? ?? false;
    final raw = (m['chatBottomPad'] as num?)?.toDouble();
    if (raw == null) {
      return (value: ChatLayout.defaultChatBottomPad, touched: touched);
    }
    if (!touched && ChatLayout.legacyDefaultPads.contains(raw)) {
      return (value: ChatLayout.defaultChatBottomPad, touched: false);
    }
    return (value: ChatLayout.pad(raw), touched: touched);
  }

  /// 保存整份设置（串行 + 原子替换）。失败会抛给调用方，队列不受影响。
  Future<void> save(AppSettings s) {
    loadError = null;
    final task = _writeQueue.then((_) => _write(s));
    // 一次失败不能毒死队列：后续保存照常排队。
    _writeQueue = task.then((_) {}).catchError((Object _) {});
    return task;
  }

  /// 按字段更新：**读最新值 → 改 → 写**。
  ///
  /// 「拿着页面打开时那份旧对象整份覆盖」会抹掉别处刚改的配置
  /// （比如日志页刚改的上限被设置页的旧快照盖回去）。改设置优先走这个。
  Future<AppSettings> update(AppSettings Function(AppSettings) transform) {
    final task = _writeQueue.then((_) async {
      final updated = transform(load());
      await _write(updated);
      return updated;
    });
    _writeQueue = task.then((_) {}).catchError((Object _) {});
    return task;
  }

  /// 等写盘队列排空（测试 / 退出前）。
  Future<void> flush() => _writeQueue;

  Future<void> _write(AppSettings s) async {
    final f = File(_path);
    await f.parent.create(recursive: true);
    final tmp = File('$_path.tmp');
    try {
      await tmp.writeAsString(jsonEncode(_toJson(s)), flush: true);
      // 同一目录内改名替换：磁盘上任何时刻都是完整文件，
      // 写到一半被杀最多留下一个 .tmp，不会毁掉旧设置。
      await tmp.rename(f.path);
      loadError = null;
    } catch (e) {
      appLog.e('settings', '设置保存失败：$_path', e);
      try {
        if (tmp.existsSync()) tmp.deleteSync();
      } catch (_) {}
      rethrow;
    }
  }

  Map<String, Object?> _toJson(AppSettings s) => {
        'themeId': s.themeId,
        'activeProviderId': s.activeProviderId,
        'lastPackageId': s.lastPackageId,
        'lastPackageVersion': s.lastPackageVersion,
        'lastSaveId': s.lastSaveId,
        'showBg': s.showBg,
        'memory': s.memory.toJson(),
        'replyLength': s.replyLength,
        'portraitHeight': s.portraitHeight,
        'chatBottomPad': s.chatBottomPad,
        'chatBottomPadTouched': s.chatBottomPadTouched,
        'autoRemoveBg': s.autoRemoveBg,
        'noticeAgreed': s.noticeAgreed,
        'chatFontId': s.chatFontId,
        'chatFontSize': s.chatFontSize,
        'importedFonts': s.importedFonts.map((e) => e.toJson()).toList(),
        'tts': s.tts.toJson(),
        'logMaxEntries': s.logMaxEntries,
        'streamOutput': s.streamOutput,
        'providers': s.providers.map((e) => e.toJson()).toList(),
      };

  bool get isConfigured => load().activeProvider != null;

  ProviderPreset? activeOf(AppSettings s) {
    final byId = s.activeProviderId;
    for (final p in s.providers) {
      if (byId != null && p.id == byId && p.enabled) return p;
    }
    for (final p in s.providers) {
      if (p.enabled) return p;
    }
    return null;
  }

  ProviderConfig? toProviderConfig() {
    final s = load();
    final active = activeOf(s);
    if (active == null) return null;
    return active.toConfig();
  }

  DialogueProvider createProvider() {
    final cfg = toProviderConfig();
    if (cfg == null) return MockDialogueProvider();
    return OpenAiCompatibleProvider(cfg);
  }

  Future<List<String>> fetchModels({
    required String endpoint,
    required String apiKey,
  }) {
    return modelsClient.listModels(endpoint: endpoint, apiKey: apiKey);
  }

  // ---- 朗读（TtsController 只认这一个方法，便于测试替换） ----

  @override
  TtsSettings loadTts() => load().tts;

  // ---- 导入字体：文件落在 `<app 数据>/fonts/` 下 ----

  Directory get fontDir => Directory(p.join(rootDir, 'fonts'));

  static const List<String> fontExtensions = ['.ttf', '.otf', '.ttc'];

  /// 把一个字体文件复制进应用数据目录并登记。
  ///
  /// 导入字体的体积上限。`.ttc` 字体集合动辄几十上百 MB：整份读进内存，
  /// 而且每次启动都要同步注册一遍。超限当场拒绝，比留到开屏卡顿才暴露要诚实。
  static const int maxFontBytes = 30 * 1024 * 1024;

  /// 只认扩展名（Flutter 的 FontLoader 不解码内容以外的元信息，
  /// 坏文件在渲染时表现为不生效，不会崩）。
  Future<ImportedChatFont> importFontFile(
    String sourcePath, {
    String? label,
  }) async {
    final src = File(sourcePath);
    if (!src.existsSync()) {
      throw Exception('字体文件不存在：$sourcePath');
    }
    final ext = p.extension(sourcePath).toLowerCase();
    if (!fontExtensions.contains(ext)) {
      throw Exception('只支持 ${fontExtensions.join(' / ')} 字体文件');
    }
    final size = src.lengthSync();
    if (size > maxFontBytes) {
      final mb = (size / (1024 * 1024)).toStringAsFixed(1);
      throw Exception(
        '字体文件太大（$mb MB），上限 ${maxFontBytes ~/ (1024 * 1024)} MB',
      );
    }
    final id = 'f_${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}';
    final dir = fontDir;
    if (!dir.existsSync()) await dir.create(recursive: true);
    final dest = File(p.join(dir.path, '$id$ext'));
    await src.copy(dest.path);
    final name = (label ?? p.basenameWithoutExtension(sourcePath)).trim();
    return ImportedChatFont(
      id: id,
      label: name.isEmpty ? id : name,
      family: id,
      path: dest.path,
      sizeBytes: dest.existsSync() ? dest.lengthSync() : 0,
    );
  }

  /// 删掉字体文件本身（登记信息由调用方从设置里去掉）。
  Future<void> deleteFontFile(ImportedChatFont font) async {
    try {
      final f = File(font.path);
      if (f.existsSync()) await f.delete();
    } catch (_) {
      // 文件删不掉不该挡住设置保存。
    }
  }

  static String newId() =>
      'p_${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}';
}

class AppSettings {
  const AppSettings({
    required this.themeId,
    required this.providers,
    this.activeProviderId,
    this.lastPackageId,
    this.lastPackageVersion,
    this.lastSaveId,
    this.showBg = true,
    this.memory = MemoryThresholds.defaults,
    this.replyLength = 'short',
    this.portraitHeight = 200,
    this.chatBottomPad = ChatLayout.defaultChatBottomPad,
    this.chatBottomPadTouched = false,
    this.autoRemoveBg = false,
    this.noticeAgreed = false,
    this.chatFontId = kSystemFontId,
    this.chatFontSize = kChatFontSizeDefault,
    this.importedFonts = const [],
    this.tts = const TtsSettings(),
    this.logMaxEntries = AppLogger.defaultMaxEntries,
    this.streamOutput = true,
  });

  final String themeId;
  final List<ProviderPreset> providers;
  final String? activeProviderId;
  final String? lastPackageId;

  /// 上次选中的包**版本**：同一 packageId 可以有多个版本并存，
  /// 只存 packageId 时重载会随便挑一个（通常是列表最后一个）。
  final String? lastPackageVersion;
  final String? lastSaveId;
  final bool showBg;

  /// 五层记忆的全部阈值（含 L5 上下文上限）。**只存在这里**，
  /// 存档不保存 —— 换档、换包、换设置都不会互相污染。
  final MemoryThresholds memory;

  /// 回复长度偏好：short / medium / long（会写进提示词）。
  final String replyLength;

  /// 立绘容器高度（逻辑像素）：直接控制底部立绘区高度。
  /// 图片顶满容器高度并完整显示（contain）。
  final double portraitHeight;

  /// 消息流留白调整（逻辑像素，**可正可负**）：正数把消息流往上推，
  /// 负数把它压下来靠近立绘。底部留白 = 底部整块（立绘 + 输入栏）+ 本值，
  /// 公式见 [ChatLayout.messageBottomInset]。
  final double chatBottomPad;

  /// 用户是否**手动拖过**留白滑条。
  ///
  /// 只用来做默认值迁移：这个值先后默认过 35 / 60，两次都被写进过设置文件，
  /// 光看数值分不出「手动拖的」和「上一版默认写的」。拖过一次就置 true，
  /// 之后默认值再怎么改都不动用户的值。
  final bool chatBottomPadTouched;

  /// 自动抠图：把立绘纯色背景替换为透明。需要时才开，有性能开销。
  final bool autoRemoveBg;

  /// 开屏页的用户须知是否已同意（同意过就不再拦）。
  final bool noticeAgreed;

  /// 聊天区字体：`kChatFontPresets[].id` 或导入字体的 `f_xxx`。
  final String chatFontId;

  /// 聊天区字号（逻辑像素）。**只对聊天对话生效**。
  final double chatFontSize;

  final List<ImportedChatFont> importedFonts;

  /// 语音朗读（云端 TTS）。
  final TtsSettings tts;

  /// 运行日志保留条数上限（内存与日志文件共用），默认 1000。
  final int logMaxEntries;

  /// 流式输出：对话请求边生成边显示（模型供应商页开关）。Mock 也支持。
  final bool streamOutput;

  static const empty = AppSettings(
    themeId: 'violet',
    providers: [],
    activeProviderId: null,
    lastPackageId: null,
    lastPackageVersion: null,
    lastSaveId: null,
    showBg: true,
    memory: MemoryThresholds.defaults,
    replyLength: 'short',
    portraitHeight: 200,
    chatBottomPad: ChatLayout.defaultChatBottomPad,
    chatBottomPadTouched: false,
    autoRemoveBg: false,
    noticeAgreed: false,
    chatFontId: kSystemFontId,
    chatFontSize: kChatFontSizeDefault,
    importedFonts: [],
    tts: TtsSettings(),
    logMaxEntries: AppLogger.defaultMaxEntries,
    streamOutput: true,
  );

  ProviderPreset? get activeProvider {
    if (activeProviderId != null) {
      for (final p in providers) {
        if (p.id == activeProviderId && p.enabled) return p;
      }
    }
    for (final p in providers) {
      if (p.enabled) return p;
    }
    return null;
  }

  AppSettings copyWith({
    String? themeId,
    List<ProviderPreset>? providers,
    String? activeProviderId,
    String? lastPackageId,
    String? lastPackageVersion,
    String? lastSaveId,
    bool? showBg,
    MemoryThresholds? memory,
    String? replyLength,
    double? portraitHeight,
    double? chatBottomPad,
    bool? chatBottomPadTouched,
    bool? autoRemoveBg,
    bool? noticeAgreed,
    String? chatFontId,
    double? chatFontSize,
    List<ImportedChatFont>? importedFonts,
    TtsSettings? tts,
    int? logMaxEntries,
    bool? streamOutput,
    // `?? this.x` 永远清不掉一个已有值：要置 null 必须显式说一声。
    bool clearActiveProvider = false,
    bool clearLastSave = false,
  }) {
    return AppSettings(
      themeId: themeId ?? this.themeId,
      providers: providers ?? this.providers,
      activeProviderId:
          clearActiveProvider ? null : (activeProviderId ?? this.activeProviderId),
      lastPackageId: lastPackageId ?? this.lastPackageId,
      lastPackageVersion: lastPackageVersion ?? this.lastPackageVersion,
      lastSaveId: clearLastSave ? null : (lastSaveId ?? this.lastSaveId),
      showBg: showBg ?? this.showBg,
      memory: memory ?? this.memory,
      replyLength: replyLength ?? this.replyLength,
      portraitHeight: portraitHeight ?? this.portraitHeight,
      chatBottomPad: chatBottomPad ?? this.chatBottomPad,
      chatBottomPadTouched: chatBottomPadTouched ?? this.chatBottomPadTouched,
      autoRemoveBg: autoRemoveBg ?? this.autoRemoveBg,
      noticeAgreed: noticeAgreed ?? this.noticeAgreed,
      chatFontId: chatFontId ?? this.chatFontId,
      chatFontSize: chatFontSize ?? this.chatFontSize,
      importedFonts: importedFonts ?? this.importedFonts,
      tts: tts ?? this.tts,
      logMaxEntries: logMaxEntries ?? this.logMaxEntries,
      // false 是合法值：`false ?? this.x` 在 Dart 里仍是 false
      streamOutput: streamOutput ?? this.streamOutput,
    );
  }
}

/// 回复长度档位的显示名（设置页与提示词共用一套词）。
String replyLengthLabel(String id) => switch (id) {
      'medium' => '中等',
      'long' => '较长',
      _ => '简短',
    };

/// 把回复长度档位翻成给模型的一句约束。
String replyLengthHint(String id) => switch (id) {
      'medium' => '回复长度：中等，一次回复 2~4 句。',
      'long' => '回复长度：较长，可以把动作与心理写细一些（但不要长篇独白）。',
      _ => '回复长度：简短，一次回复 1~2 句，多用短句。',
    };
