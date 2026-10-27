import 'dart:convert';
import 'dart:io';

import 'package:chatgal/app/app_services.dart';
import 'package:chatgal/design_system/tokens.dart';
import 'package:chatgal/features/session/chat_page.dart';
import 'package:chatgal/features/settings/api_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gal_protocol/gal_protocol.dart';
import 'package:gal_storage/gal_storage.dart';
import 'package:path/path.dart' as p;

/// 不可进入的存档**不能被覆盖**（复审 P1）。
///
/// 以前 `load.canEnter == false` 时页面照样初始化、照样铺起始场景，看起来像
/// 「正常开局」；之后的保存只检查 `slot != null`，会把当前状态写回、由 `update()`
/// 写成当前 schema —— 「不支持的存档」就变成了「被当前版本覆盖的存档」。
/// 验收：进页面、点返回、尝试交互之后，原文件**字节完全不变**。
const _ref = PackageRef(
  packageId: 'test.locked',
  version: '1',
  contentHash: 'h',
);

class _Packages extends PackageStore {
  _Packages(super.rootDir);
  @override
  PackageRef? findExact(String id, String version, String hash) => _ref;
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
  late final saves = SaveRepository(rootDir: root.path, packages: packages);

  @override
  PlaySessionData loadPlaySession(PackageRef ref) {
    final scene = SceneDef.fromJson({
      'displayName': '第一幕',
      'background': '',
      'narration': '入场词',
      'characters': <Object?>[],
      'target': <Object?>[],
    }, id: 'start');
    final later = SceneDef.fromJson({
      'displayName': '后续幕',
      'narration': '后续入场',
    }, id: 'later');
    final graph = SceneGraph(
      scenes: {'start': scene, 'later': later},
      entrypoint: 'start',
    );
    return PlaySessionData(
      characterName: '测试',
      packageTitle: '测试',
      packageIntro: '',
      characterPrompt: '',
      installDir: root.path,
      sceneGraph: graph,
      content: PackageContent(
        manifest: const PackageManifest(
          packageId: 'test.locked',
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
  for (final id in ['later', 'deleted']) {
    testWidgets('空 L1 读档保持位置，缺失情景锁档：$id', (tester) async {
      final root = Directory.systemTemp.createTempSync('chatgal_position_');
      addTearDown(() => root.deleteSync(recursive: true));
      final services = _Services(root);
      final slot = await tester.runAsync(
        () => services.saves.create(
          label: '当前位置',
          packageRef: _ref,
          storyId: id,
          world: WorldSnapshot(
            variables: const {'day': 8},
            characters: const {},
            eventHistory: const {},
            presentation: const {},
            rngState: 1,
            story: {'storyId': id, 'nodeId': id, 'day': 8},
          ),
        ),
      );
      final file = File(p.join(root.path, 'saves', '${slot!.saveId}.json'));
      final before = file.readAsBytesSync();
      await tester.pumpWidget(
        MaterialApp(
          home: ChatPage(
            services: services,
            packageRef: _ref,
            saveId: slot.saveId,
          ),
        ),
      );
      await tester.pump();
      if (id == 'later') {
        expect(find.text('第8天 · 后续幕'), findsWidgets);
        expect(find.textContaining('第一幕'), findsNothing);
      } else {
        expect(find.text('这份存档打不开'), findsOneWidget);
        expect(find.byType(TextField), findsNothing);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      expect(file.readAsBytesSync(), before);
    });
  }

  testWidgets('高版本 schema 的存档：页面明确拒绝进入，且原文件字节不变', (tester) async {
    final root = Directory.systemTemp.createTempSync('chatgal_locked_');
    addTearDown(() => root.deleteSync(recursive: true));
    final services = _Services(root);

    // 先造一份正常存档，再把它改成「更高版本写的」。
    final slot = await tester.runAsync(
      () => services.saves.create(
        label: '未来版本',
        packageRef: _ref,
        storyId: 'start',
        world: const WorldSnapshot(
          variables: {'day': 5},
          characters: {},
          story: {'storyId': 'start', 'nodeId': 'start', 'day': 5},
          presentation: {},
          eventHistory: {},
          rngState: 3,
        ),
      ),
    );
    final file = File(p.join(root.path, 'saves', '${slot!.saveId}.json'));
    final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    json['saveSchemaVersion'] = SaveSlot.currentSchemaVersion + 5;
    file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(json));
    final before = file.readAsBytesSync();
    // 确认存储层确实拒绝进入
    expect(services.saves.load(slot.saveId).canEnter, isFalse);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ChatPage(
                    theme: ChatGalTheme.violet,
                    services: services,
                    packageRef: _ref,
                    saveId: slot.saveId,
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
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // 明确的「不可玩」页：没有输入框、没有起始场景卡片。
    expect(find.text('这份存档打不开'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('第5天 · 第一幕'), findsNothing);

    // 从这里返回（系统返回键）：直接离开，不弹保存确认。
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(ChatPage), findsNothing, reason: '应能直接离开');
    expect(find.text('保存失败'), findsNothing);

    // 关键验收：整个来回之后，存档文件一个字节都没变。
    // 先给真实磁盘 I/O 留出时间：万一真有谁偷偷写了盘，这里一定看得出来。
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
    }
    expect(file.readAsBytesSync(), before, reason: '不可进入的存档不允许被任何保存写回');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });
}
