import 'dart:io';

import 'package:chatgal/app/app_services.dart';
import 'package:chatgal/features/session/chat_page.dart';
import 'package:chatgal/features/settings/api_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gal_protocol/gal_protocol.dart';
import 'package:gal_storage/gal_storage.dart';

/// 事件结束回剧情这条路上的保存失败保护（复审 P1）。
///
/// 以前：更新内存世界 → 保存 → 只看 mounted → 播过场 + 请求开场白。
/// 保存失败照样往下走，产出一段**必然丢**的对白与记忆（普通换幕那条路已经
/// 挡着了，只有事件这条路漏了）。
/// 现在：失败就把入场动作挂起来，**所有恢复入口**都走同一个流程，
/// 重试保存成功后再补播一次，而且只补一次。
const _ref = PackageRef(
  packageId: 'test.event',
  version: '1',
  contentHash: 'test',
);

class _Packages extends PackageStore {
  _Packages(super.rootDir);
  @override
  PackageRef? findExact(String id, String version, String hash) => _ref;
}

/// 内存存档：故意不碰磁盘。
///
/// ChatPage 的保存是异步的；用真仓库 + 假时钟会让「真文件 I/O」与「假计时器」
/// 互相等，全量跑（多 isolate 并行）时整批 `did not complete`、单独跑却必过。
/// 纯内存后时序完全由假时钟决定，测试既稳又快。
class _Saves extends SaveRepository {
  _Saves({required super.rootDir, required super.packages});

  /// 第 N 次 update 抛异常（0 = 不注入）。
  int failOnUpdate = 0;
  int updates = 0;

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
    if (++updates == failOnUpdate) {
      throw FileSystemException('simulated disk failure');
    }
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

class _Services implements AppServices {
  _Services(this.root);
  @override
  final Directory root;
  @override
  late final api = ApiSettingsStore(root.path);
  @override
  late final packages = _Packages(root.path);
  @override
  late final _Saves saves = _Saves(rootDir: root.path, packages: packages);

  @override
  PlaySessionData loadPlaySession(PackageRef ref) {
    // 带一个角色：记忆窗口/owner 走的是真实路径，开场白气泡在「按 L1 窗口重建
    // 消息流」之后依然在，测试信号才稳定（没有角色时那个重建会把它换掉）。
    const charId = '测试';
    SceneDef scene(String id, String name) => SceneDef.fromJson({
      'displayName': name,
      'background': '',
      'narration': '$name 的入场词',
      'characters': [
        {'charId': charId, 'state': '校服', 'emotion': '平常', 'scenePrompt': '测试'},
      ],
      'target': <Object?>[],
    }, id: id);
    final graph = SceneGraph(
      scenes: {'start': scene('start', '第一幕'), 'next': scene('next', '第二幕')},
      entrypoint: 'start',
    );
    final character = CharacterDef.fromJson({
      'id': charId,
      'prompt': '你是测试角色。',
      'states': ['校服'],
      'emotions': ['平常'],
      'defaultState': '校服',
      'defaultEmotion': '平常',
    });
    final event = EventDef.fromJson({
      'slides': [
        {
          'image': null,
          'text': ['结局一'],
        },
      ],
      'target': [
        {
          'kind': [
            {'kind': 'story', 'to': 'next'},
          ],
        },
      ],
    }, id: 'ev');
    return PlaySessionData(
      characterName: charId,
      packageTitle: '测试',
      packageIntro: '',
      characterPrompt: character.prompt,
      installDir: root.path,
      portraitExpressionIds: character.emotions,
      sceneGraph: graph,
      eventDefs: {'ev': event},
      content: PackageContent(
        manifest: const PackageManifest(
          packageId: 'test.event',
          version: '1',
          name: '测试',
          author: 'test',
          description: '',
        ),
        characters: [character],
        variables: [],
        scenes: graph.scenes,
        sceneGraph: graph,
        eventDefs: {'ev': event},
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() cond, {
  int rounds = 60,
}) async {
  for (var i = 0; i < rounds && !cond(); i++) {
    await tester.pump(const Duration(milliseconds: 50));
    // 给真实事件循环让一点路：页面里的异步链（保存队列、记忆整理）要在真实
    // 时区里推进，只在假时钟里 pump 是不够的。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
  }
  // 让 SnackBar 进场动画走完：不然它的按钮还在屏幕外，点击会落空。
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// 建一个「停在事件最后一屏」的存档（点一下就会收尾）。
Future<SaveSlot> _eventSave(WidgetTester tester, _Services services) async {
  final slot = await services.saves.create(
    label: '测试',
    packageRef: _ref,
    storyId: 'start',
    world: const WorldSnapshot(
      variables: {'day': 1},
      characters: {},
      story: {'storyId': 'start', 'nodeId': 'start', 'day': 1},
      presentation: {
        'scene': '',
        'appearance': {'expressionId': '平常'},
      },
      eventHistory: {},
      rngState: 1,
    ),
  );
  await services.saves.update(
    slot,
    runtimeCursor: const RuntimeCursor(
      mode: RuntimeCursor.modeEventPlay,
      storyId: 'start',
      visitId: 1,
      eventId: 'ev',
      slideIndex: 0,
      eventVisitId: 1,
    ),
  );
  return slot;
}

void main() {
  testWidgets('已落盘待开场的存档：重启补播，完成后再次读档不重播', (tester) async {
    final root = Directory.systemTemp.createTempSync('chatgal_opening_resume_');
    addTearDown(() => root.deleteSync(recursive: true));
    final services = _Services(root);
    final slot = await services.saves.create(
      label: '待开场',
      packageRef: _ref,
      storyId: 'next',
      world: const WorldSnapshot(
        variables: {'day': 2},
        characters: {},
        eventHistory: {},
        rngState: 1,
        story: {'storyId': 'next', 'nodeId': 'next', 'day': 2},
        presentation: {
          'pendingOpening': {'storyId': 'next', 'visitId': 0},
        },
      ),
    );
    Future<void> open() => tester.pumpWidget(
      MaterialApp(
        home: ChatPage(
          services: services,
          packageRef: _ref,
          saveId: slot.saveId,
        ),
      ),
    );
    await open();
    await _pumpUntil(
      tester,
      () => services.saves.mem!.memoryCheckpoint.isNotEmpty,
      rounds: 150,
    );
    expect(find.textContaining('（小声）'), findsOneWidget);
    expect(
      services.saves.mem!.world.presentation.containsKey('pendingOpening'),
      isFalse,
    );
    final messages = services.saves.mem!.messageCheckpoint.length;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    await open();
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(services.saves.mem!.messageCheckpoint.length, messages);
    expect(find.textContaining('（小声）'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('事件返回剧情：写盘失败不生成开场白，重试成功才补播', (tester) async {
    final root = Directory.systemTemp.createTempSync('chatgal_event_save_');
    addTearDown(() => root.deleteSync(recursive: true));
    final services = _Services(root);
    final slot = await _eventSave(tester, services);
    // 让「收尾时的那一次写盘」失败。
    services.saves.failOnUpdate = services.saves.updates + 1;

    await tester.pumpWidget(
      MaterialApp(
        home: ChatPage(
          services: services,
          packageRef: _ref,
          saveId: slot.saveId,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    // 事件层在：点一下走完这一块 → 收尾。
    expect(find.text('结局一'), findsOneWidget);
    await tester.tap(find.text('结局一'));
    await _pumpUntil(
      tester,
      () => find.textContaining('保存失败').evaluate().isNotEmpty,
    );

    // 失败后的结果：还在游戏页、有可重试的提示、**没有**开场白（没落盘就不该产内容）。
    expect(find.byType(ChatPage), findsOneWidget);
    expect(find.textContaining('保存失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(
      find.textContaining('（小声）'),
      findsNothing,
      reason: '保存失败时不该请求下一幕的开场白',
    );
    // 存档里也没有推进到第二幕。
    expect(
      '${services.saves.load(slot.saveId).slot!.world.story['storyId']}',
      'start',
    );

    // 磁盘恢复 → 点「重试」：保存成功并补播开场白。
    services.saves.failOnUpdate = 0;
    await tester.tap(find.text('重试'));
    await _pumpUntil(
      tester,
      () => find.textContaining('（小声）').evaluate().isNotEmpty,
      rounds: 120,
    );

    expect(
      find.textContaining('（小声）'),
      findsOneWidget,
      reason: '重试成功后要补播开场白（不漏播）',
    );
    expect(
      '${services.saves.load(slot.saveId).slot!.world.story['storyId']}',
      'next',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('原提示消失后：从「推进」入口也只能走同一个恢复入口，且动作只执行一次', (tester) async {
    // 复审 P1：三条入口（推进 / 发送 / 点事件）以前各自 `_persist()`，
    // 保存成功会清掉失败状态，却不会执行挂起的入场动作 —— 开场白就此漏播。
    final root = Directory.systemTemp.createTempSync('chatgal_event_save2_');
    addTearDown(() => root.deleteSync(recursive: true));
    final services = _Services(root);
    final slot = await _eventSave(tester, services);
    services.saves.failOnUpdate = services.saves.updates + 1;

    await tester.pumpWidget(
      MaterialApp(
        home: ChatPage(
          services: services,
          packageRef: _ref,
          saveId: slot.saveId,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('结局一'));
    await _pumpUntil(
      tester,
      () => find.textContaining('保存失败').evaluate().isNotEmpty,
    );

    // 让那条提示消失（玩家划掉或超时）：挂起动作还在，只是没有可见提示了。
    tester
        .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger).first)
        .clearSnackBars();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('保存失败'), findsNothing, reason: '提示已消失');

    // 从「推进」入口尝试推进：必须被拦下，并重新给出同一个恢复提示。
    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await _pumpUntil(tester, () => find.text('重试保存').evaluate().isNotEmpty);
    expect(find.text('重试保存'), findsOneWidget, reason: '挂起动作还没做完时，别的入口也要能把它接回来');
    expect(find.textContaining('（小声）'), findsNothing, reason: '拦住了就不该开始产生内容');
    expect(
      '${services.saves.load(slot.saveId).slot!.world.story['storyId']}',
      'start',
    );

    // 磁盘恢复 → 点一次「重试保存」：保存成功并把挂起的入场动作补做一次。
    services.saves.failOnUpdate = 0;
    await tester.tap(find.text('重试保存'));
    await _pumpUntil(
      tester,
      () => find.textContaining('（小声）').evaluate().isNotEmpty,
      rounds: 120,
    );
    expect(
      find.textContaining('（小声）'),
      findsOneWidget,
      reason: '挂起的入场动作要被补做，且只做一次（不漏播、不重播）',
    );
    expect(
      '${services.saves.load(slot.saveId).slot!.world.story['storyId']}',
      'next',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });
}
