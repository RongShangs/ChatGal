import 'dart:async';
import 'dart:io';

import 'package:chatgal/app/app_logger.dart';
import 'package:chatgal/app/app_services.dart';
import 'package:chatgal/features/session/chat_page.dart';
import 'package:chatgal/features/settings/api_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gal_ai/gal_ai.dart';
import 'package:gal_protocol/gal_protocol.dart';
import 'package:gal_storage/gal_storage.dart';

/// 常驻**立绘 agent**（用户第四轮裁定）：
/// * 聊天请求只写台词（纯文本也行）；
/// * 每次回复都发一个专用请求：切成情绪节拍 + 给每节拍选合法立绘 + 顺带快捷回复；
/// * **agent 不许改台词**：节拍拼不回原文就整条退回一张立绘；
/// * agent 失败/乱回也不能影响对白显示，更不能多花一次「快捷回复」请求。
const _ref = PackageRef(
  packageId: 'test.agent',
  version: '1',
  contentHash: 'test',
);

class _Packages extends PackageStore {
  _Packages(super.rootDir);
  @override
  PackageRef? findExact(String id, String version, String hash) => _ref;
}

class _MemSaves extends SaveRepository {
  _MemSaves({required super.rootDir, required super.packages});
  SaveSlot? mem;

  @override
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
    mem = SaveSlot(
      saveId: 'save_test',
      sessionId: sessionId ?? 'save_test',
      label: label,
      packageRef: packageRef,
      storyId: storyId,
      world: world,
      createdAt: now,
      updatedAt: now,
      messageCheckpoint: messages ?? const [],
      memoryCheckpoint: memory ?? const {},
    );
    return mem!;
  }

  @override
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
    mem = slot.copyWith(
      world: world,
      messageCheckpoint: messages,
      label: label,
      revision: revision,
      runtimeCursor: runtimeCursor,
      committedTransitions: committedTransitions,
      appliedSettlementIds: appliedSettlementIds,
      pendingGalleryUnlocks: pendingGalleryUnlocks,
      memoryCheckpoint: memoryCheckpoint,
      updatedAt: DateTime.now().toUtc(),
    );
    return mem!;
  }

  @override
  SaveLoadResult load(String saveId) {
    final slot = mem;
    if (slot == null) {
      return const SaveLoadResult.locked(reason: SaveLockReason.missingPackage);
    }
    return SaveLoadResult.allowed(slot: slot);
  }
}

/// 按脚本逐个返回的 provider：用来分别控制「聊天回复」与「agent 回包」。
class _ScriptedApi extends ApiSettingsStore {
  _ScriptedApi(super.rootDir, this.scripts);

  final List<String> scripts;
  late final MockDialogueProvider provider =
      MockDialogueProvider(script: scripts);

  @override
  bool get isConfigured => true;

  @override
  DialogueProvider createProvider() => provider;
}

/// 可控流式的 provider：聊天请求立刻回一句纯文本台词；**agent 请求挂住**，
/// 由测试自己决定什么时候吐哪个字段 —— 用来验证「字段一闭合就先用起来」。
class _GatedAgentProvider implements DialogueProvider {
  final _agentDone = Completer<ProviderResult>();
  void Function(String delta)? _agentDelta;
  bool agentStarted = false;

  @override
  Future<ProviderResult> generate(
    GenerateRequest request, {
    CancelToken? cancel,
    void Function(String delta)? onDelta,
  }) {
    final isAgent = request.messages.any(
      (m) => '${m['content']}'.contains('立绘导演'),
    );
    if (isAgent) {
      agentStarted = true;
      _agentDelta = onDelta;
      return _agentDone.future;
    }
    onDelta?.call(_proseReply);
    return Future.value(
      ProviderResult.ok(
        response: parseAiResponse(_proseReply).response!,
        rawText: _proseReply,
      ),
    );
  }

  /// 给挂住的 agent 请求喂一段增量（模拟 SSE 分片）。
  void pushAgent(String delta) => _agentDelta?.call(delta);

  void finishAgent(String raw) => _agentDone.complete(
    ProviderResult.ok(response: parseAiResponse(raw).response!, rawText: raw),
  );
}

class _GatedApi extends ApiSettingsStore {
  _GatedApi(super.rootDir, this.provider);
  final _GatedAgentProvider provider;
  @override
  bool get isConfigured => true;
  @override
  DialogueProvider createProvider() => provider;
}

class _Services implements AppServices {
  _Services(this.root, this.api);
  @override
  final Directory root;
  @override
  final ApiSettingsStore api;
  @override
  late final packages = _Packages(root.path);
  @override
  late final _MemSaves saves = _MemSaves(rootDir: root.path, packages: packages);

  @override
  PlaySessionData loadPlaySession(PackageRef ref) {
    const charId = '测试';
    final scene = SceneDef.fromJson({
      'displayName': '第一幕',
      'background': '',
      'narration': '入场词',
      'characters': [
        {'charId': charId, 'state': '校服', 'emotion': '平常', 'scenePrompt': ''},
      ],
      'target': <Object?>[],
    }, id: 'start');
    final graph = SceneGraph(scenes: {'start': scene}, entrypoint: 'start');
    final character = CharacterDef.fromJson({
      'id': charId,
      'prompt': '你是测试角色。',
      'states': ['校服'],
      'emotions': ['平常', '开心'],
      'defaultState': '校服',
      'defaultEmotion': '平常',
    });
    return PlaySessionData(
      characterName: charId,
      packageTitle: '测试',
      packageIntro: '',
      characterPrompt: character.prompt,
      installDir: root.path,
      portraitExpressionIds: character.emotions,
      sceneGraph: graph,
      content: PackageContent(
        manifest: const PackageManifest(
          packageId: 'test.agent',
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

/// 聊天回复：纯文本台词（真机日志里模型就是这么回的）。
const _proseReply = '（小声）你回来啦。';

/// agent 回包：一个节拍，且能拼回原文 → 采用，并带快捷回复。
const _planOk = '{"replyExpression":"开心","replyPortrait":"校服_开心",'
    '"segments":[{"text":"（小声）你回来啦。","expressionId":"开心","portraitId":"校服_开心"}],'
    '"suggestedReplies":["嗯","好"]}';

/// agent 回包：把台词**改写了**（拼不回原文）→ 必须退回整条一张立绘。
const _planRewritten = '{"replyExpression":"开心","replyPortrait":"校服_开心",'
    '"segments":[{"text":"你回来啦。","expressionId":"开心","portraitId":"校服_开心"}]}';

/// agent 回包：**本版的正常形态**——只给总立绘 + 快捷回复，不切节拍。
/// 节拍从未被接线（打字机不按它换立绘），却要模型把整段台词重贴一遍，
/// 是它慢的根因；用户裁定「一次对话变一次立绘就基本够了」后去掉。
const _planNoBeats = '{"replyExpression":"开心","replyPortrait":"校服_开心",'
    '"suggestedReplies":["嗯","好"]}';

String _logText() =>
    AppLogger.instance.snapshot().map((e) => e.line).join('\n');

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() cond, {
  int rounds = 120,
}) async {
  for (var i = 0; i < rounds && !cond(); i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<SaveSlot> _enter(WidgetTester tester, _Services services) async {
  final slot = await services.saves.create(
    label: '测试',
    packageRef: _ref,
    storyId: 'start',
    world: const WorldSnapshot(
      variables: {'day': 1},
      characters: {},
      story: {'storyId': 'start', 'nodeId': 'start', 'day': 1},
      presentation: {'scene': '', 'appearance': {'expressionId': '平常'}},
      eventHistory: {},
      rngState: 1,
    ),
  );
  await tester.pumpWidget(
    MaterialApp(
      home: ChatPage(services: services, packageRef: _ref, saveId: slot.saveId),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
  return slot;
}

Future<void> _sendOne(WidgetTester tester) async {
  await tester.enterText(find.byType(TextField), '我回来了');
  await tester.pump();
  await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
}

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('chatgal_agent_');
    AppLogger.instance.clear();
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  testWidgets('聊天回纯文本也没关系：agent 切节拍 + 定立绘 + 给快捷回复，共两次请求',
      (tester) async {
    final api = _ScriptedApi(root.path, [_proseReply, _planOk]);
    final services = _Services(root, api);
    await _enter(tester, services);

    await _sendOne(tester);
    await _pumpUntil(tester, () => api.provider.calls >= 2);

    // 只两次：聊天 1 + agent 1（快捷回复由 agent 顺手带回来，不再单独问一次）
    expect(api.provider.calls, 2, reason: 'agent 设计下每轮固定两次请求');
    // 台词没被 agent 改动
    expect(find.textContaining('你回来啦'), findsOneWidget);
    // agent 给的快捷回复真的用上了
    expect(find.text('嗯'), findsOneWidget);
    expect(find.text('好'), findsOneWidget);

    final log = _logText();
    expect(log, contains('立绘 agent：节拍=1 重建成功'));
    expect(log, contains('立绘 agent 输入：形态=非 JSON'));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('agent 改写了台词 → 节拍不采用，台词仍是原话', (tester) async {
    final api = _ScriptedApi(root.path, [_proseReply, _planRewritten]);
    final services = _Services(root, api);
    await _enter(tester, services);

    await _sendOne(tester);
    await _pumpUntil(tester, () => api.provider.calls >= 2);

    // 关键安全性质：agent 不能改角色说了什么 —— 气泡仍是完整原话
    expect(find.textContaining('（小声）你回来啦。'), findsOneWidget);
    final log = _logText();
    expect(log, contains('重建失败（退回整条一张）'));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('agent 回包是垃圾 → 不影响对白，也不会崩', (tester) async {
    final api = _ScriptedApi(root.path, [_proseReply, '这不是 JSON']);
    final services = _Services(root, api);
    await _enter(tester, services);

    await _sendOne(tester);
    await _pumpUntil(tester, () => api.provider.calls >= 2);

    expect(find.textContaining('你回来啦'), findsOneWidget);
    expect(_logText(), contains('立绘 agent 回包无法解析'));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('本版正常形态：agent 只给总立绘 + 快捷回复，不切节拍', (tester) async {
    final api = _ScriptedApi(root.path, [_proseReply, _planNoBeats]);
    final services = _Services(root, api);
    await _enter(tester, services);

    await _sendOne(tester);
    await _pumpUntil(tester, () => api.provider.calls >= 2);

    // 仍是每轮两次请求（聊天 1 + agent 1），快捷回复由 agent 顺手带回
    expect(api.provider.calls, 2, reason: 'agent 设计下每轮固定两次请求');
    expect(find.text('嗯'), findsOneWidget);
    expect(find.text('好'), findsOneWidget);
    // 台词一个字都没被 agent 动过
    expect(find.textContaining('（小声）你回来啦。'), findsOneWidget);
    final log = _logText();
    expect(
      log,
      contains('无节拍'),
      reason: '日志要如实说「本版不切节拍」，不能报成重建失败',
    );
    expect(
      log,
      contains('立绘 agent 耗时：'),
      reason: '耗时量化那行要在，真机排查靠它',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('agent 走流式：字段一闭合就先切表情/快捷回复，不等整段回包', (tester) async {
    final gate = _GatedAgentProvider();
    final services = _Services(root, _GatedApi(root.path, gate));
    await _enter(tester, services);

    await _sendOne(tester);
    await _pumpUntil(tester, () => gate.agentStarted);

    // agent 还在跑：两颗推荐词都还是加载态（显示 …、点不动）
    expect(find.text('…'), findsNWidgets(2));

    // 只喂「总立绘 + 快捷回复」两段：占大头的节拍还没来
    gate.pushAgent('{"replyExpression":"开心","replyPortrait":"校服_开心",');
    gate.pushAgent('"suggestedReplies":["嗯","好"],');
    await tester.pump();

    expect(
      find.text('嗯'),
      findsOneWidget,
      reason: '字段闭合就该先用：不能等逐拍标注那段大输出写完',
    );
    expect(find.text('好'), findsOneWidget);
    expect(
      find.text('…'),
      findsNothing,
      reason: '推荐词已经可用，不该再停在加载态',
    );
    expect(
      _logText(),
      contains('立绘 agent（流式）：表情/立绘先到位'),
      reason: '表情/立绘也要在流里先切',
    );
    expect(_logText(), contains('立绘 agent（流式）：快捷回复先到位'));

    // 整段回包到齐：仍走既有的完整解析，两者不打架
    gate.finishAgent(_planOk);
    await _pumpUntil(tester, () => _logText().contains('立绘 agent：节拍=1'));

    expect(find.text('嗯'), findsOneWidget);
    expect(find.text('好'), findsOneWidget);
    expect(find.textContaining('你回来啦'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });
}
