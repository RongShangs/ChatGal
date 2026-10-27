import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../app/app_logger.dart';
import 'tts_settings.dart';

/// 云端 TTS 客户端：OpenAI 兼容 `POST {base}/audio/speech` → 音频字节。
///
/// **每个请求一个自己的 HttpClient**：超时/取消时能安全强关，下一个请求从零
/// 建立 —— 「复用一个 client，超时后关掉，之后再也发不出去」这个坑在设置页的
/// 模型列表上已经踩过一次，不能在这里重演。
class CloudTtsClient {
  CloudTtsClient({HttpClient Function()? clientFactory})
      : _newClient = clientFactory ?? HttpClient.new;

  /// 可注入：测试用它数「这次请求是不是新建了 client」。
  final HttpClient Function() _newClient;

  Future<Uint8List> synthesize({
    required TtsSettings settings,
    required String text,
    Duration timeout = const Duration(seconds: 45),
  }) async {
    if (text.trim().isEmpty) {
      throw const TtsException('没有可朗读的内容');
    }
    final uri = Uri.parse(settings.speechUrl());
    final client = _newClient();
    try {
      return await Future<Uint8List>(() async {
        final req = await client.postUrl(uri);
        req.headers.contentType =
            ContentType('application', 'json', charset: 'utf-8');
        if (settings.apiKey.trim().isNotEmpty) {
          req.headers.set(HttpHeaders.authorizationHeader,
              'Bearer ${settings.apiKey.trim()}');
        }
        req.add(utf8.encode(jsonEncode(settings.requestBody(text))));
        final resp = await req.close();
        final bytes = await _collect(resp);
        if (resp.statusCode != 200) {
          throw TtsException('HTTP ${resp.statusCode}：${_shortBody(bytes)}');
        }
        if (bytes.isEmpty) {
          throw const TtsException('服务返回了空音频');
        }
        return bytes;
      }).timeout(
        timeout,
        onTimeout: () {
          try {
            client.close(force: true);
          } catch (_) {}
          throw const TtsException('语音合成超时');
        },
      );
    } finally {
      // 正常路径也关掉：一次请求一个连接池，不会越积越多。
      try {
        client.close(force: false);
      } catch (_) {}
    }
  }

  Future<Uint8List> _collect(HttpClientResponse resp) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in resp) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  String _shortBody(Uint8List bytes) {
    try {
      final s = utf8.decode(bytes, allowMalformed: true);
      final oneLine = s.replaceAll(RegExp(r'\s+'), ' ').trim();
      return oneLine.length > 200 ? '${oneLine.substring(0, 200)}…' : oneLine;
    } catch (_) {
      return '${bytes.length} 字节的响应';
    }
  }
}

class TtsException implements Exception {
  const TtsException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 原生音频播放通道（Android `MediaPlayer`）。
///
/// 为什么不用插件：只为了「放一个 mp3 文件 + 知道放完了」不值得引入一个
/// 音频播放依赖；原生侧一共几十行，且能精确控制 stop。
///
/// **每次播放带一个任务编号**：原生回调把编号带回来，控制器据此判断这个回调
/// 属于不是还在跑的那次朗读 —— 否则「旧任务的回调结束新任务」会让新朗读凭空
/// 变成已播完。
class NativeAudio {
  NativeAudio({MethodChannel? channel})
      : _ch = channel ?? const MethodChannel('chatgal/media') {
    try {
      _ch.setMethodCallHandler(handleNativeCall);
    } catch (_) {
      // 没有 Flutter binding（纯 Dart 测试）时忽略：那种环境下也不会真的播。
    }
  }

  final MethodChannel _ch;

  /// 播放结束回调：(任务编号, 错误信息)。错误信息为 null = 正常播完。
  void Function(int taskId, String? error)? onFinished;

  Future<void> play(String path, {required int taskId}) async {
    try {
      await _ch.invokeMethod<void>('play', {
        'path': path,
        'taskId': taskId,
      });
    } on MissingPluginException {
      throw const TtsException('当前平台不支持原生播放（非 Android 或未构建）');
    } on PlatformException catch (e) {
      throw TtsException(e.message ?? '播放失败');
    }
  }

  Future<void> stop() async {
    try {
      await _ch.invokeMethod<void>('stop');
    } catch (_) {
      // 停止失败无所谓：最多留一句尾巴。
    }
  }

  /// 由原生侧回调（播完 / 出错）。
  Future<void> handleNativeCall(MethodCall call) async {
    final args = call.arguments;
    final taskId = args is Map ? (args['taskId'] as num?)?.toInt() ?? 0 : 0;
    switch (call.method) {
      case 'completed':
        onFinished?.call(taskId, null);
      case 'error':
        final message = args is Map ? '${args['message'] ?? '未知错误'}' : '未知错误';
        onFinished?.call(taskId, message);
    }
  }

  /// 摘掉回调（控制器销毁时）。不摘的话页面已经没了还会被叫一次。
  void detach() {
    onFinished = null;
    try {
      _ch.setMethodCallHandler(null);
    } catch (_) {}
  }
}

enum TtsState { idle, preparing, playing, error }

/// 朗读控制器：合成为文件 → 交给原生播放 → 播完通知。
///
/// 合成结果按（**服务地址** + 模型 + 音色 + 语速 + 格式 + 文本）缓存到
/// `<root>/tts_cache/`，同一句再朗读一次不会再花钱打一次请求。
///
/// **任务代次**是这里最关键的一条不变量：每次「停止 / 换一条朗读」都会让
/// [_gen] +1，于是旧任务在每个 await 之后都会发现自己已经过期——
/// * 合成途中点停止 → 合成回来也不会再开始播放（复审 P2）；
/// * 播放途中换一条 → 旧任务立刻收尾、新任务马上开始，不会卡到那次
///   五分钟的兜底超时（复审 P2）。
class TtsController extends ChangeNotifier {
  TtsController({
    required this.rootDir,
    required this.settingsSource,
    CloudTtsClient? client,
    NativeAudio? audio,
  })  : _client = client ?? CloudTtsClient(),
        _audio = audio ?? NativeAudio() {
    _audio.onFinished = _onNativeFinished;
  }

  final String rootDir;

  /// 只依赖「能读到 TtsSettings」这一件事，测试不必构造整个 ApiSettingsStore。
  final ApiSettingsLike settingsSource;
  final CloudTtsClient _client;
  final NativeAudio _audio;

  TtsState _state = TtsState.idle;
  TtsState get state => _state;
  String? _lastError;
  String? get lastError => _lastError;

  /// 依次朗读的句子队列（自动朗读时一组回复的多段会排队）。
  final List<String> _queue = [];
  bool _disposed = false;

  /// 任务编号：只增不减（新任务用它）。
  int _nextGen = 0;

  /// 当前**有效**任务的编号；0 = 没有任何有效任务（旧任务全部作废）。
  int _gen = 0;

  /// 正在跑的那次朗读（只用于「有没有在途任务」判断）。
  Future<void>? _task;

  bool _invalid(int gen) => _disposed || gen != _gen;

  Future<File> _cacheFile(String key, String ext) async {
    final dir = Directory(p.join(rootDir, 'tts_cache'));
    if (!dir.existsSync()) await dir.create(recursive: true);
    return File(p.join(dir.path, '$key.$ext'));
  }

  /// FNV-1a：稳定的缓存键（`String.hashCode` 跨进程不保证一致）。
  static String stableKey(String input) {
    var hash = 0x811c9dc5;
    for (final b in utf8.encode(input)) {
      hash ^= b;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  /// 服务地址要进缓存身份：两个服务商用同一组模型名与音色名时，
  /// 不带地址就会把前一个服务的音频播给后一个（「设置改了却不生效」）。
  ///
  /// 规范化**只对不区分大小写的部分**做：scheme 与 host 转小写、去掉末尾斜杠
  /// 与默认端口；**路径与查询保留原样** —— 自定义服务里 `/VoiceA` 和 `/voicea`
  /// 很可能是两个不同的接口，整体 `toLowerCase()` 会把它们当成同一家，复用错音频。
  /// userinfo（可能含密钥）不进缓存身份。
  static String normalizeEndpoint(String endpoint) {
    final raw = endpoint.trim();
    if (raw.isEmpty) return '';
    final uri = Uri.tryParse(raw);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      // 写了个半截地址（比如只有 host:port）：保守地只去尾部斜杠，不改大小写。
      return raw.replaceAll(RegExp(r'/+$'), '');
    }
    final scheme = uri.scheme.toLowerCase();
    final host = uri.host.toLowerCase();
    final defaultPort = switch (scheme) {
      'https' => 443,
      'http' => 80,
      _ => 0,
    };
    final port = uri.port == defaultPort ? '' : ':${uri.port}';
    var path = uri.path;
    if (path.endsWith('/')) path = path.replaceAll(RegExp(r'/+$'), '');
    final query = uri.hasQuery && uri.query.isNotEmpty ? '?${uri.query}' : '';
    return '$scheme://$host$port$path$query';
  }

  /// 缓存身份 = 规范化服务地址 + 模型 + 音色 + 语速 + 格式 + 文本。
  /// 公开是为了能单测钉住「换服务商之后不会播到上一个服务的音频」。
  String cacheKeyFor(TtsSettings s, String text) => stableKey(
        '${normalizeEndpoint(s.endpoint)}|${s.model}|${s.voice}|'
        '${s.speed}|${s.format}|$text',
      );

  /// 朗读一段文本。
  Future<void> speak(String text, {bool interrupt = false}) async {
    final settings = settingsSource.loadTts();
    if (!settings.enabled) {
      _fail('语音朗读未开启');
      return;
    }
    if (!settings.configured) {
      _fail('语音配置不完整：请填写 Base URL、模型与音色');
      return;
    }
    await _start([text], settings);
  }

  /// 依次朗读多段（AI 一条回复拆成多段时用）。
  Future<void> speakAll(List<String> texts) async {
    final settings = settingsSource.loadTts();
    if (!settings.enabled || !settings.configured) {
      _fail(settings.enabled ? '语音配置不完整' : '语音朗读未开启');
      return;
    }
    final usable = [
      for (final t in texts)
        if (t.trim().isNotEmpty) t,
    ];
    if (usable.isEmpty) return;
    await _start(usable, settings);
  }

  /// 作废当前任务 → 用新内容开始一次任务。
  Future<void> _start(List<String> texts, TtsSettings settings) async {
    // **先登记再 await**：`_cancelCurrent()` 里有 await（可能要等原生 stop 返回），
    // 这期间玩家点停止必须能让这次启动作废 —— 否则停止看起来生效了，
    // 等那个 await 回来它自己又开始合成、播放（复审 P2 的另一个时序窗口）。
    final gen = ++_nextGen;
    _pendingStart = gen;
    try {
      await _cancelCurrent(except: gen);
      // await 回来先核对：期间被停止、或被更晚的一次朗读顶掉 → 直接放弃启动。
      if (_disposed || _pendingStart != gen) return;
      _gen = gen;
      _queue
        ..clear()
        ..addAll(texts);
      final task = _drain(gen, settings);
      _task = task;
      try {
        await task;
      } finally {
        if (identical(_task, task)) _task = null;
      }
    } finally {
      if (_pendingStart == gen) _pendingStart = 0;
    }
  }

  /// 已登记但可能还没真正开始跑的启动请求编号（0 = 没有）。
  int _pendingStart = 0;

  /// 停止当前任务：让在途的合成/播放**立刻**作废。
  ///
  /// 两点都不能少：
  /// * 只调 `_audio.stop()` 不够 —— 原生停播不发完成回调，旧 `_drain` 会一直
  ///   等在 `_segmentDone` 上（最长五分钟），期间新朗读也起不来；
  /// * 但也**不能等旧任务退出** —— 它可能正卡在 HTTP 合成请求上，等它就等于
  ///   「点停止没反应」。所以这里只作废 + 唤醒等待位，旧任务自己在下一次
  ///   有效性检查处收尾（那时它既不会播放，也碰不到新任务的任何状态）。
  ///
  /// [except] 是本次调用要放过的启动请求（`_start` 自己调进来时传自己的编号）：
  /// 其它调用一律把待启动请求一起作废。
  Future<void> _cancelCurrent({int? except}) async {
    if (_pendingStart != except) _pendingStart = 0;
    final hasWork = _task != null || _segmentDone != null;
    if (!hasWork) {
      // 没有在途任务：只确保播放器停下（可能是上一轮遗留的声音）。
      await _audio.stop();
      return;
    }
    _gen = 0; // 作废：旧任务在每个 await 之后都会看到自己不再有效
    _queue.clear();
    final waiter = _segmentDone;
    _segmentDone = null;
    _segmentOwner = null;
    _currentPlayId = null;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
    await _audio.stop();
    // 旧任务由它自己收尾（可能在等 HTTP）。
    _task = null;
  }

  /// 一个任务里的播放等待位：只有「持有它的那个任务」能清掉它，
  /// 否则旧任务退出时会把新任务的等待位一起清空。
  Completer<void>? _segmentDone;
  int? _segmentOwner;

  /// 正在等待的那次**播放尝试**编号（原生回调按它匹配）。
  int _playSeq = 0;
  int? _currentPlayId;

  Future<void> _drain(int gen, TtsSettings settings) async {
    try {
      while (_queue.isNotEmpty) {
        if (_invalid(gen)) return;
        final text = _queue.removeAt(0);
        _setState(TtsState.preparing, gen);
        Uint8List bytes;
        try {
          bytes = await _synthesizeCached(settings, text);
        } on TtsException catch (e) {
          if (!_invalid(gen)) _fail(e.message);
          return;
        } catch (e) {
          if (!_invalid(gen)) _fail('$e');
          return;
        }
        // 合成期间被停止/替换：到这一步就不要开始播放了。
        if (_invalid(gen)) return;

        final file =
            await _cacheFile(cacheKeyFor(settings, text), settings.format);
        if (!file.existsSync() || file.lengthSync() == 0) {
          await file.writeAsBytes(bytes, flush: true);
        }
        if (_invalid(gen)) return;

        _setState(TtsState.playing, gen);
        final playId = ++_playSeq;
        final done = Completer<void>();
        _segmentDone = done;
        _segmentOwner = gen;
        _currentPlayId = playId;
        try {
          await _audio.play(file.path, taskId: playId);
        } on TtsException catch (e) {
          if (!_invalid(gen)) _fail(e.message);
          return;
        }
        // 等播完（原生回调）；给一个上限，避免回调彻底丢失时永远卡住。
        await done.future.timeout(const Duration(minutes: 5), onTimeout: () {});
        if (_invalid(gen)) return;
      }
      if (!_invalid(gen)) _setState(TtsState.idle, gen);
    } finally {
      // 只清「还是自己这一次」的等待位。
      if (_segmentOwner == gen) {
        _segmentDone = null;
        _segmentOwner = null;
        _currentPlayId = null;
      }
    }
  }

  /// 原生回调：按**播放尝试编号**匹配，旧任务的回调不能结束新任务。
  void _onNativeFinished(int taskId, String? error) {
    final current = _currentPlayId;
    if (current == null || taskId != current) return;
    final waiter = _segmentDone;
    final owner = _segmentOwner;
    if (error != null) {
      if (waiter != null && !waiter.isCompleted) waiter.complete();
      if (owner != null && owner == _gen) _fail('播放失败：$error');
      _gen = 0; // 这一段失败就作废整轮，不要接着读下一段
      return;
    }
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

  Future<Uint8List> _synthesizeCached(TtsSettings s, String text) async {
    final key = cacheKeyFor(s, text);
    final file = await _cacheFile(key, s.format);
    if (file.existsSync() && file.lengthSync() > 0) {
      appLog.d('tts', '缓存命中 $key');
      return await file.readAsBytes();
    }
    appLog.i('tts',
        '合成 ${text.length} 字（${normalizeEndpoint(s.endpoint)} · ${s.model} · ${s.voice} · ${s.speed}x）');
    final bytes = await _client.synthesize(settings: s, text: text);
    appLog.d('tts', '合成完成 ${bytes.length} 字节');
    return bytes;
  }

  Future<void> stop() async {
    await _cancelCurrent();
    if (!_disposed) _setState(TtsState.idle, _gen);
  }

  void _fail(String message) {
    _lastError = message;
    appLog.w('tts', message);
    _setState(TtsState.error, _gen);
  }

  void _setState(TtsState next, int gen) {
    if (_disposed || gen != _gen) return;
    _state = next;
    notifyListeners();
  }

  void clearError() {
    if (_lastError == null) return;
    _lastError = null;
    _setState(TtsState.idle, _gen);
  }

  /// 超过 [keep] 条就删最旧的缓存文件。
  Future<void> pruneCache({int keep = 60}) async {
    try {
      final dir = Directory(p.join(rootDir, 'tts_cache'));
      if (!dir.existsSync()) return;
      final files = dir.listSync().whereType<File>().toList()
        ..sort(
            (a, b) => b.statSync().modified.compareTo(a.statSync().modified));
      for (final f in files.skip(keep)) {
        try {
          f.deleteSync();
        } catch (_) {}
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _disposed = true;
    _gen = 0; // 作废在途任务；_disposed 也已经是 true，双保险
    // 先让原生停止播放，再摘回调：顺序反了会漏掉最后一条回调，
    // 而 stop() 之后本来也不需要它了。
    unawaited(stop());
    _audio.detach();
    super.dispose();
  }
}

/// [TtsController] 只依赖「能读到 TtsSettings」这一件事，
/// 这样测试不必构造整个 ApiSettingsStore。
abstract class ApiSettingsLike {
  TtsSettings loadTts();
}
