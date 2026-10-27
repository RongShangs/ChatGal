import 'dart:async';
import 'dart:io';

import 'package:chatgal/app/app_services.dart';
import 'package:chatgal/features/session/chat_page.dart';
import 'package:chatgal/features/settings/api_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gal_protocol/gal_protocol.dart';
import 'package:gal_storage/gal_storage.dart';

/// 事件的**选择题出口**在界面这一侧：
/// 最后一屏把选项铺出来，点哪个就去哪个（不是「点一下结束」）。
const _ref = PackageRef(
  packageId: 'test.event.choice',
  version: '1',
  contentHash: 'test',
);

class _Packages extends PackageStore {
  _Packages(super.rootDir);
  @override
  PackageRef? findExact(String id, String version, String hash) => _ref;
}

/// 纯内存存档（与 event_save_failure_test 同一套理由：真文件 I/O 与假时钟
/// 互相等会让整套测试偶发整批 did not complete）。
class _Saves extends SaveRepository {
  _Saves({required super.rootDir, required super.packages});

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
    const charId = '测试';
    SceneDef scene(String id, String name) => SceneDef.fromJson({
          'displayName': name,
          'background': '',
          'narration': '$name 的入场词',
          'characters': [
            {
              'charId': charId,
              'state': '校服',
              'emotion': '平常',
              'scenePrompt': '测试',
            },
          ],
          'target': <Object?>[],
        }, id: id);
    final graph = SceneGraph(
      scenes: {
        'start': scene('start', '第一幕'),
        'after': scene('after', '第二幕'),
      },
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
          'text': ['结局播完了。'],
        },
      ],
      'choice': {
        'title': '要继续留在这里吗？',
        'options': [
          {'text': '回到主页', 'kind': 'appShell', 'to': 'home'},
          {'text': '继续留在这里', 'kind': 'story', 'to': 'after'},
        ],
      },
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
          packageId: 'test.event.choice',
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

/// 建一个「停在事件最后一屏」的存档（事件是选择题，所以不会靠点击结束）。
Future<SaveSlot> _eventSave(_Services services) async {
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

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() cond, {
  int rounds = 80,
}) async {
  for (var i = 0; i < rounds && !cond(); i++) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
  }
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<Completer<String?>> _openChat(
  WidgetTester tester,
  _Services services,
) async {
  final popped = Completer<String?>();
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              popped.complete(
                await Navigator.of(context).push<String>(
                  MaterialPageRoute<String>(
                    builder: (_) => ChatPage(
                      services: services,
                      packageRef: _ref,
                      saveId: 'save_test',
                    ),
                  ),
                ),
              );
            },
            child: const Text('进入游戏'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('进入游戏'));
  await tester.pumpAndSettle();
  return popped;
}

void main() {
  testWidgets('选择题出口：最后一屏铺出选项，不靠点击结束', (tester) async {
    final root = Directory.systemTemp.createTempSync('chatgal_evchoice_');
    addTearDown(() => root.deleteSync(recursive: true));
    final services = _Services(root);
    await _eventSave(services);

    final popped = await _openChat(tester, services);
    await _pumpUntil(
      tester,
      () => find.text('继续留在这里').evaluate().isNotEmpty,
    );

    // 标题与两个选项都在屏幕上
    expect(find.text('要继续留在这里吗？'), findsOneWidget);
    expect(find.text('回到主页'), findsOneWidget);
    expect(find.text('继续留在这里'), findsOneWidget);
    // 选择题不用「点击结束」那套提示
    expect(find.text('点击结束'), findsNothing);

    // 点「继续留在这里」→ 按选项写的目的地去 after 那一幕
    await tester.tap(find.text('继续留在这里'));
    await _pumpUntil(
      tester,
      () =>
          services.saves.mem!.runtimeCursor.mode == RuntimeCursor.modeStoryChat &&
          services.saves.mem!.runtimeCursor.storyId == 'after',
    );
    final slot = services.saves.mem!;
    expect(slot.runtimeCursor.storyId, 'after');
    expect(slot.world.story['nodeId'], 'after');
    // 事件层收掉了，不会再看到选项
    expect(find.text('继续留在这里'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    // 这一路是「去下一幕」，不是回主页：push 的 future 不该已经完成
    expect(popped.isCompleted, isFalse);
  });

  testWidgets('选择题出口：点「回到主页」真的弹回上一页', (tester) async {
    final root = Directory.systemTemp.createTempSync('chatgal_evchoice_home_');
    addTearDown(() => root.deleteSync(recursive: true));
    final services = _Services(root);
    await _eventSave(services);

    final popped = await _openChat(tester, services);
    await _pumpUntil(
      tester,
      () => find.text('回到主页').evaluate().isNotEmpty,
    );

    await tester.tap(find.text('回到主页'));
    await _pumpUntil(
      tester,
      () => find.byType(ChatPage).evaluate().isEmpty,
    );
    expect(find.byType(ChatPage), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    // 出口是「回主页」→ 游戏页把这次玩的存档 id 交回来（主页据此跳到这个档）
    expect(await popped.future, 'save_test');
  });
}
