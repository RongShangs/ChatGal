import 'dart:io';

import 'package:chatgal/app/app_services.dart';
import 'package:chatgal/features/session/chat_page.dart';
import 'package:chatgal/features/settings/api_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gal_protocol/gal_protocol.dart';
import 'package:gal_storage/gal_storage.dart';

const _ref = PackageRef(
  packageId: 'test.exit',
  version: '1',
  contentHash: 'test',
);

class _Packages extends PackageStore {
  _Packages(super.rootDir);
  @override
  PackageRef? findExact(String id, String version, String hash) => _ref;
}

class _Saves extends SaveRepository {
  _Saves({required super.rootDir, required super.packages});
  int failOnUpdate = 0;
  int updates = 0;
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
  }) {
    if (++updates == failOnUpdate) {
      throw FileSystemException('simulated disk failure');
    }
    return super.update(
      slot,
      world: world,
      messages: messages,
      label: label,
      revision: revision,
      runtimeCursor: runtimeCursor,
      committedTransitions: committedTransitions,
      appliedSettlementIds: appliedSettlementIds,
      pendingGalleryUnlocks: pendingGalleryUnlocks,
      memoryCheckpoint: memoryCheckpoint,
      pending: pending,
      clearPending: clearPending,
    );
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
    final scene = SceneDef.fromJson({
      'displayName': '出口测试',
      'background': '',
      'narration': '测试场景',
      'characters': [],
      'target': [
        {
          'kind': [
            {'kind': 'appShell', 'to': 'home'},
          ],
        },
      ],
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
          packageId: 'test.exit',
          version: '1',
          name: '测试',
          author: 'test',
          description: '',
        ),
        characters: [],
        variables: [],
        scenes: graph.scenes,
        sceneGraph: graph,
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final failAt in [0, 1, 2]) {
    final fail = failAt != 0;
    testWidgets('appShell ${fail ? '第 $failAt 次保存失败时留在游戏' : '直接返回主页且不弹确认'}', (
      tester,
    ) async {
      final root = Directory.systemTemp.createTempSync('chatgal_exit_');
      addTearDown(() => root.deleteSync(recursive: true));
      final services = _Services(root);
      final slot = await tester.runAsync(
        () => services.saves.create(
          label: '测试',
          packageRef: _ref,
          storyId: 'start',
          world: const WorldSnapshot(
            variables: {},
            characters: {},
            story: {'storyId': 'start', 'nodeId': 'start'},
            presentation: {},
            eventHistory: {},
            rngState: 1,
          ),
        ),
      );
      services.saves.failOnUpdate = failAt;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ChatPage(
                      services: services,
                      packageRef: _ref,
                      saveId: slot!.saveId,
                    ),
                  ),
                ),
                child: const Text('进入游戏'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('进入游戏'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.play_arrow_rounded));
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)),
        );
        if (fail
            ? find.textContaining('保存失败').evaluate().isNotEmpty
            : find.byType(ChatPage).evaluate().isEmpty) {
          break;
        }
      }
      expect(find.byType(ChatPage), fail ? findsOneWidget : findsNothing);
      expect(find.text('确定返回'), findsNothing);
      if (fail) expect(find.textContaining('保存失败'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });
  }
}
