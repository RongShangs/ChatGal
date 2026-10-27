import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:chatgal/features/tts/tts_service.dart';
import 'package:chatgal/features/tts/tts_settings.dart';
import 'package:flutter_test/flutter_test.dart';

/// 只提供 TtsSettings 的假设置源（TtsController 只依赖这一个方法）。
class _FakeSettings implements ApiSettingsLike {
  TtsSettings settings = const TtsSettings(enabled: true);

  @override
  TtsSettings loadTts() => settings;
}

class _FakeClient extends CloudTtsClient {
  int calls = 0;

  /// 非空时合成要等它 —— 用来把「合成还在路上」这一段拉长。
  Completer<void>? gate;

  @override
  Future<Uint8List> synthesize({
    required TtsSettings settings,
    required String text,
    Duration timeout = const Duration(seconds: 45),
  }) async {
    calls++;
    final g = gate;
    if (g != null) await g.future;
    return Uint8List.fromList([1, 2, 3, 4]);
  }
}

class _FakeAudio extends NativeAudio {
  final played = <String>[];
  final taskIds = <int>[];
  int stopCalls = 0;

  /// 这个任务编号的「播放」不自动结束（模拟还在播）。
  int? holdTaskId;

  /// 播放即失败。
  bool failPlay = false;

  /// 非空时 `stop()` 会挂在这里 —— 模拟「原生停止还没返回」的窗口。
  Completer<void>? holdStop;

  @override
  Future<void> play(String path, {required int taskId}) async {
    played.add(path);
    taskIds.add(taskId);
    if (failPlay) {
      scheduleMicrotask(() => onFinished?.call(taskId, 'cannot play'));
      return;
    }
    if (taskId == holdTaskId) return;
    scheduleMicrotask(() => onFinished?.call(taskId, null));
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    final h = holdStop;
    if (h != null) await h.future;
  }
}

Future<void> _until(bool Function() cond,
    {Duration limit = const Duration(seconds: 3)}) async {
  final deadline = DateTime.now().add(limit);
  while (!cond() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late Directory root;
  late _FakeSettings settings;
  late _FakeClient client;
  late _FakeAudio audio;
  late TtsController controller;

  setUp(() {
    root = Directory.systemTemp.createTempSync('chatgal_tts_');
    settings = _FakeSettings();
    client = _FakeClient();
    audio = _FakeAudio();
    controller = TtsController(
      rootDir: root.path,
      settingsSource: settings,
      client: client,
      audio: audio,
    );
  });

  tearDown(() {
    controller.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('合成途中停止：合成回来也不再开始播放（复审 P2）', () async {
    client.gate = Completer<void>();
    final speaking = controller.speak('你好');
    await _until(() => client.calls == 1);
    expect(controller.state, TtsState.preparing);

    await controller.stop();
    expect(controller.state, TtsState.idle);

    // 合成这时才返回：旧任务已经作废，绝不能开播。
    client.gate!.complete();
    await speaking;
    expect(audio.played, isEmpty);
    expect(controller.state, TtsState.idle);
  });

  test('播放中换一条：新朗读马上开始，不卡在旧的五分钟兜底超时（复审 P2）', () async {
    audio.holdTaskId = 1; // 第一次朗读的播放不结束
    final first = controller.speak('第一句');
    await _until(() => audio.played.length == 1);
    expect(audio.taskIds, [1]);
    expect(controller.state, TtsState.playing);

    final started = DateTime.now();
    // 第二条：应当作废旧任务并立刻播新的一句。
    await controller.speak('第二句');
    final elapsed = DateTime.now().difference(started);

    expect(audio.played.length, 2, reason: '新的朗读要真的播出来');
    expect(audio.taskIds, [1, 2]);
    expect(elapsed.inSeconds, lessThan(5),
        reason: '不该等到旧任务那五分钟的兜底超时');

    // 旧任务被作废后立刻收尾（不会挂着一个 await 不放）。
    await first.timeout(const Duration(seconds: 2));
  });

  test('原生播放报错：状态是错误，且不会接着读下一段（复审 P2）', () async {
    audio.failPlay = true;
    await controller.speakAll(['第一段', '第二段']);
    expect(audio.played, hasLength(1), reason: '第一段就失败了，不该继续读第二段');
    expect(controller.state, TtsState.error);
    expect(controller.lastError, isNotNull);
  });

  test('播完正常收尾：状态回到 idle，多段依次播放', () async {
    await controller.speakAll(['第一段', '第二段']);
    expect(audio.played, hasLength(2));
    expect(audio.taskIds, [1, 2]);
    expect(controller.state, TtsState.idle);
  });

  test('未开启 / 配置不完整时不发请求', () async {
    settings.settings = const TtsSettings(enabled: false);
    await controller.speak('你好');
    expect(client.calls, 0);
    expect(controller.lastError, contains('未开启'));

    settings.settings = const TtsSettings(enabled: true, model: '');
    await controller.speak('你好');
    expect(client.calls, 0);
    expect(controller.lastError, contains('不完整'));
  });

  test('同一句第二次朗读走缓存，不再请求一次', () async {
    await controller.speak('同一句');
    await controller.speak('同一句');
    expect(client.calls, 1);
  });

  test('启动还没完成就停止：这次朗读不能自己开始（复审 P2）', () async {
    // 时序：speak() 先登记请求，再 await「作废旧任务」——而作废里可能要等
    // 原生 stop 返回。这一小段窗口里点停止，以前看不到「还没开始的任务」，
    // 等 await 回来它照样分配代次、照样合成播放。
    audio.holdStop = Completer<void>();
    final speaking = controller.speak('你好');
    // 让 speak 走进第一个 await（登记已完成）。
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final stopping = controller.stop();
    await Future<void>.delayed(const Duration(milliseconds: 10));

    // 现在放开原生停止：两边都继续跑。
    audio.holdStop!.complete();
    audio.holdStop = null;
    await speaking;
    await stopping;

    expect(client.calls, 0, reason: '被停止的启动请求不该发合成请求');
    expect(audio.played, isEmpty, reason: '更不该开始播放');
    expect(controller.state, TtsState.idle);
  });

  test('启动窗口里被更晚的一次朗读顶掉：只有后一次会跑', () async {
    audio.holdStop = Completer<void>();
    final first = controller.speak('第一句');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final second = controller.speak('第二句');
    await Future<void>.delayed(const Duration(milliseconds: 10));

    audio.holdStop!.complete();
    audio.holdStop = null;
    await first;
    await second;

    expect(client.calls, 1, reason: '只有后一次请求应该真的跑起来');
    expect(audio.played, hasLength(1));
  });

  test('缓存身份包含服务地址：换服务商不会播到上一个服务的音频（复审 P2）', () {
    const a = TtsSettings(enabled: true, endpoint: 'https://a.example/v1');
    const b = TtsSettings(enabled: true, endpoint: 'https://b.example/v1');
    expect(
      controller.cacheKeyFor(a, '你好'),
      isNot(controller.cacheKeyFor(b, '你好')),
    );
    // 只差大小写 / 末尾斜杠的地址是同一家。
    const a2 = TtsSettings(enabled: true, endpoint: 'HTTPS://A.example/v1/');
    expect(controller.cacheKeyFor(a, '你好'), controller.cacheKeyFor(a2, '你好'));
    // 不同文本、不同音色也要分开。
    expect(
      controller.cacheKeyFor(a, '你好'),
      isNot(controller.cacheKeyFor(a, '再见')),
    );
    expect(
      controller.cacheKeyFor(a, '你好'),
      isNot(controller.cacheKeyFor(a.copyWith(voice: 'other'), '你好')),
    );
  });

  test('normalizeEndpoint：scheme/host 不区分大小写，路径区分（复审 P3）', () {
    expect(TtsController.normalizeEndpoint('  HTTPS://X.example/v1//  '),
        'https://x.example/v1');
    expect(TtsController.normalizeEndpoint('http://127.0.0.1:8080/v1/'),
        'http://127.0.0.1:8080/v1');
    // 默认端口不该影响身份。
    expect(TtsController.normalizeEndpoint('https://x.example:443/v1'),
        TtsController.normalizeEndpoint('https://x.example/v1'));
    // **路径大小写必须保留**：/VoiceA 与 /voicea 可能是两个不同接口。
    expect(
      TtsController.normalizeEndpoint('https://x.example/VoiceA'),
      isNot(TtsController.normalizeEndpoint('https://x.example/voicea')),
    );
    // 查询串也保留大小写。
    expect(
      TtsController.normalizeEndpoint('https://x.example/v1?k=Abc'),
      isNot(TtsController.normalizeEndpoint('https://x.example/v1?k=abc')),
    );
    // userinfo（可能含密钥）不掺进身份。
    expect(TtsController.normalizeEndpoint('https://user:secret@x.example/v1'),
        'https://x.example/v1');
  });

  test('路径只有大小写不同 → 缓存身份也要分开', () {
    const upper = TtsSettings(enabled: true, endpoint: 'https://x.example/VoiceA');
    const lower = TtsSettings(enabled: true, endpoint: 'https://x.example/voicea');
    expect(
      controller.cacheKeyFor(upper, '你好'),
      isNot(controller.cacheKeyFor(lower, '你好')),
    );
  });
}
