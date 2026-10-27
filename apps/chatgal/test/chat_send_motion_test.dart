import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:chatgal/app/app_services.dart';
import 'package:chatgal/features/session/chat_page.dart';
import 'package:chatgal/features/settings/api_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gal_ai/gal_ai.dart';
import 'package:gal_protocol/gal_protocol.dart';
import 'package:gal_storage/gal_storage.dart';

const ref = PackageRef(
  packageId: 'test.motion',
  version: '1',
  contentHash: 'test',
);

/// 入场动画层在 chat_page 里挂的标记。
const enterKey = ValueKey('chat-bubble-enter');
const sendKey = ValueKey('chat-send-button');

class ControlledProvider implements DialogueProvider {
  final requests = <GenerateRequest>[];
  final results = <Completer<ProviderResult>>[];
  final callbacks = <void Function(String)?>[];
  final agentResults = <Completer<ProviderResult>>[];
  final agentTokens = <CancelToken>[];

  @override
  Future<ProviderResult> generate(
    GenerateRequest request, {
    CancelToken? cancel,
    void Function(String)? onDelta,
  }) {
    if (request.messages.any(
      (m) => m['role'] == 'system' && (m['content'] ?? '').contains('立绘'),
    )) {
      final done = Completer<ProviderResult>();
      agentResults.add(done);
      agentTokens.add(cancel!);
      return done.future;
    }
    requests.add(request);
    callbacks.add(onDelta);
    final done = Completer<ProviderResult>();
    results.add(done);
    return done.future;
  }

  void complete(int index, String text) {
    results[index].complete(
      ProviderResult.ok(
        response: parseAiResponse(text).response!,
        rawText: text,
      ),
    );
  }
}

class Settings extends ApiSettingsStore {
  Settings(super.rootDir, this.provider, this.stream);
  final ControlledProvider provider;
  final bool stream;
  @override
  AppSettings load() => AppSettings.empty.copyWith(streamOutput: stream);
  @override
  DialogueProvider createProvider() => provider;
}

class Packages extends PackageStore {
  Packages(super.rootDir);
  @override
  PackageRef? findExact(String id, String version, String hash) => ref;
}

class Services implements AppServices {
  Services(this.root, ControlledProvider provider, bool stream)
    : api = Settings(root.path, provider, stream);
  @override
  final Directory root;
  @override
  final Settings api;
  @override
  late final packages = Packages(root.path);
  @override
  late final saves = SaveRepository(rootDir: root.path, packages: packages);
  @override
  PlaySessionData loadPlaySession(PackageRef ref) {
    final character = CharacterDef.fromJson({
      'id': '测试',
      'prompt': '测试角色',
      'states': ['校服'],
      'emotions': ['平常'],
      'defaultState': '校服',
      'defaultEmotion': '平常',
    });
    final scene = SceneDef.fromJson({
      'displayName': '测试',
      'background': '',
      'narration': '场景',
      'characters': [
        {'charId': '测试', 'state': '校服', 'emotion': '平常'},
      ],
      'target': <Object?>[],
    }, id: 'start');
    final graph = SceneGraph(scenes: {'start': scene}, entrypoint: 'start');
    return PlaySessionData(
      characterName: '测试',
      packageTitle: '测试',
      packageIntro: '',
      characterPrompt: '',
      installDir: root.path,
      sceneGraph: graph,
      content: PackageContent(
        manifest: const PackageManifest(
          packageId: 'test.motion',
          version: '1',
          name: '测试',
          author: 'test',
          description: '',
        ),
        characters: [character],
        variables: [],
        scenes: graph.scenes,
        sceneGraph: graph,
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> waitFor(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 200 && !ready(); i++) {
    await tester.pump(const Duration(milliseconds: 20));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  expect(ready(), isTrue);
}

class Harness {
  Harness(this.root, this.provider, this.services, this.slot);
  final Directory root;
  final ControlledProvider provider;
  final Services services;
  final SaveSlot slot;
}

/// 铺一个读档局面：历史/场景已经铺好，还没有本轮消息。
Future<Harness> makeHarness(WidgetTester tester, {required bool stream}) async {
  final root = Directory.systemTemp.createTempSync('chatgal_motion_');
  addTearDown(() async {
    // 先排空真实文件 IO 与 fake-zone 里的续跑，再销毁页面：
    // 否则后台保存还占着存档文件，临时目录删不掉（会记成本次测试失败）。
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    for (var attempt = 0; ; attempt++) {
      try {
        if (root.existsSync()) await root.delete(recursive: true);
        break;
      } on FileSystemException {
        if (attempt >= 20) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    }
  });
  final provider = ControlledProvider();
  final services = Services(root, provider, stream);
  final slot = (await tester.runAsync(
    () => services.saves.create(
      label: '测试',
      packageRef: ref,
      storyId: 'start',
      world: const WorldSnapshot(
        variables: {'day': 1},
        characters: {},
        story: {'storyId': 'start', 'nodeId': 'start'},
        presentation: {},
        eventHistory: {},
        rngState: 1,
      ),
    ),
  ))!;
  await tester.pumpWidget(
    MaterialApp(
      home: ChatPage(services: services, packageRef: ref, saveId: slot.saveId),
    ),
  );
  // 不用默认 10 分钟超时的 pumpAndSettle：页面里有常驻动画（顶栏标题跑马灯等），
  // 包名一长就会一直有动画在跑，那样不是失败而是把测试挂死。给个短超时。
  await tester.pumpAndSettle(
    const Duration(milliseconds: 50),
    EnginePhase.sendSemanticsUpdate,
    const Duration(seconds: 8),
  );
  return Harness(root, provider, services, slot);
}

/// 结束本轮，避免测试收尾时还挂着请求或打字计时器。
Future<void> finishRound(
  WidgetTester tester,
  Harness h, {
  required bool stream,
  String text = '好的',
}) async {
  if (stream) h.provider.callbacks[0]!(text);
  h.provider.complete(0, text);
  await waitFor(
    tester,
    () => tester.widget<IconButton>(find.byKey(sendKey)).onPressed != null,
  );
}

List<double> enterOpacities(WidgetTester tester, {required bool inList}) {
  final finder = inList
      ? find.descendant(of: find.byType(ListView), matching: find.byKey(enterKey))
      : find.byKey(enterKey);
  return tester
      .widgetList<Opacity>(finder)
      .map((o) => o.opacity)
      .toList(growable: false);
}

void main() {
  for (final stream in [true, false]) {
    final mode = stream ? 'stream' : 'typewriter';

    testWidgets('$mode: 发送校验通过后立即收起键盘，输入框仍可写草稿', (tester) async {
      final h = await makeHarness(tester, stream: stream);
      final field = find.byType(TextField);
      TextField input() => tester.widget<TextField>(field);

      await tester.enterText(field, '第一句');
      await tester.pump();
      expect(input().focusNode!.hasFocus, isTrue, reason: '先聚焦才谈得上收起');

      await tester.tap(find.byKey(sendKey));
      await tester.pump();

      expect(h.provider.requests, hasLength(1));
      expect(
        input().focusNode!.hasFocus,
        isFalse,
        reason: '消息发出去就收起键盘',
      );
      expect(input().controller!.text, isEmpty);
      expect(input().enabled, isTrue, reason: '生成中允许写下一句');

      // 再点一下输入框：键盘回来，草稿照样能写。
      await tester.tap(field);
      await tester.pump();
      expect(input().focusNode!.hasFocus, isTrue);

      await finishRound(tester, h, stream: stream);
    });

    testWidgets('$mode: 只有本轮新气泡播入场动画，读档历史不播且不重播', (tester) async {
      final h = await makeHarness(tester, stream: stream);

      expect(
        enterOpacities(tester, inList: true),
        isEmpty,
        reason: '读档铺出来的场景/历史不是本轮新产生的消息',
      );

      await tester.enterText(find.byType(TextField), '第一句');
      await tester.tap(find.byKey(sendKey));
      await tester.pump();

      final entering = enterOpacities(tester, inList: true);
      expect(entering, isNotEmpty, reason: '本轮新气泡要挂入场层');
      expect(
        entering.reduce(math.min),
        lessThan(1),
        reason: '第一帧还在淡入，不是瞬间出现',
      );

      await tester.pump(const Duration(milliseconds: 400));
      expect(
        enterOpacities(tester, inList: true),
        everyElement(1.0),
        reason: '动画结束回到完全不透明',
      );

      if (stream) {
        // 流式增量会重建气泡：不能把已经入场的动画打回透明、也不该重放。
        h.provider.callbacks[0]!('好的');
        await tester.pump(const Duration(milliseconds: 16));
        expect(enterOpacities(tester, inList: true), everyElement(1.0));
      }
      await finishRound(tester, h, stream: stream);

      // 全场只剩「本轮新气泡」挂过入场层：历史始终没份。
      expect(h.provider.requests, hasLength(1));
    });

    testWidgets('$mode: 每轮收尾重建消息流时不掐断正在播的入场动画', (tester) async {
      final h = await makeHarness(tester, stream: stream);
      await tester.enterText(find.byType(TextField), '第一句');
      await tester.tap(find.byKey(sendKey));
      await tester.pump(); // t=0：入场层刚挂上，还不透明

      // 让这一轮尽快收尾：正文很短，打字机一两拍就走完，紧接着
      // _recordTurn → _rebuildStreamFromWindow 会把消息流整体重建一次。
      if (stream) h.provider.callbacks[0]!('好');
      h.provider.complete(0, '好');
      await tester.pump(const Duration(milliseconds: 32));
      await tester.pump();

      // 重建前入场层是「元素」，重建后如果换了对象就会换成新元素并直接满不透明。
      final layers = enterOpacities(tester, inList: true);
      expect(
        layers,
        isNotEmpty,
        reason: '重建消息流后入场层必须还在，否则动画会被截成「唰一下全亮」',
      );
      expect(
        layers.reduce(math.min),
        lessThan(1),
        reason: '这时离 300ms 还很远，重建不该把它直接跳到完全不透明',
      );

      await waitFor(
        tester,
        () => tester.widget<IconButton>(find.byKey(sendKey)).onPressed != null,
      );
    });

    testWidgets('$mode: 忙碌时只剩进度环，解锁瞬间回到箭头', (tester) async {
      final h = await makeHarness(tester, stream: stream);
      await tester.enterText(find.byType(TextField), '第一句');
      await tester.tap(find.byKey(sendKey));
      await tester.pump();

      final button = find.byKey(sendKey);
      Finder inButton(Finder what) =>
          find.descendant(of: button, matching: what);
      expect(tester.widget<IconButton>(button).onPressed, isNull);
      expect(
        inButton(find.byType(CircularProgressIndicator)),
        findsOneWidget,
      );
      expect(
        inButton(find.byIcon(Icons.arrow_upward_rounded)),
        findsNothing,
        reason: '忙碌时箭头不能和进度环同时挂着',
      );

      await finishRound(tester, h, stream: stream);

      expect(
        inButton(find.byType(CircularProgressIndicator)),
        findsNothing,
        reason: '解锁后进度环必须立刻离开 widget 树，不留退场动画继续转',
      );
      expect(inButton(find.byIcon(Icons.arrow_upward_rounded)), findsOneWidget);
    });
  }
}
