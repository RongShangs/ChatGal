import 'dart:io';

import 'package:chatgal/app/app_services.dart';
import 'package:chatgal/features/session/chat_page.dart';
import 'package:chatgal/features/settings/api_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gal_protocol/gal_protocol.dart';
import 'package:gal_storage/gal_storage.dart';

/// 「退出游戏后要记住上一次角色的表情」的回归。
///
/// 之前的 bug：模型逐段换表情只改内存里的 `_currentExpression`，
/// `world.presentation.appearance` 一直停在上一次换幕时的值 —— 于是存档里存的
/// 永远是那张旧脸，退出再进就回到旧表情。
///
/// 这个测试把「旧表情」写成 `害羞`、把角色声明的情绪设成只有 `平常`
/// （离线 mock 只会挑声明表里的情绪，所以一笔对话之后表情必然变成 `平常`），
/// 然后检查**存档里**的表情已经跟着变了 —— 与 mock 的调用次数无关，不依赖时序巧合。
const _ref = PackageRef(
  packageId: 'test.look',
  version: '1',
  contentHash: 'test',
);

/// 存档里那张「旧脸」。
const String _staleExpression = '害羞';
const String _characterId = '测试';

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
      'displayName': '表情测试',
      'background': '',
      'narration': '测试场景',
      'characters': [
        {
          'charId': _characterId,
          'state': '校服',
          'emotion': '平常',
          'scenePrompt': '测试',
        },
      ],
      'target': <Object?>[],
    }, id: 'start');
    final graph = SceneGraph(scenes: {'start': scene}, entrypoint: 'start');
    final character = CharacterDef.fromJson({
      'id': _characterId,
      'prompt': '你是测试角色。',
      'states': ['校服'],
      'emotions': ['平常'],
      'defaultState': '校服',
      'defaultEmotion': '平常',
    });
    return PlaySessionData(
      characterName: _characterId,
      packageTitle: '测试',
      packageIntro: '',
      characterPrompt: character.prompt,
      installDir: root.path,
      portraitExpressionIds: character.emotions,
      sceneGraph: graph,
      content: PackageContent(
        manifest: const PackageManifest(
          packageId: 'test.look',
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

void main() {
  testWidgets('聊一句之后退出，存档里记的是最新表情而不是旧表情', (tester) async {
    final root = Directory.systemTemp.createTempSync('chatgal_look_');
    addTearDown(() => root.deleteSync(recursive: true));
    final services = _Services(root);

    // 存档里先放着「旧脸」：害羞。
    final slot = await tester.runAsync(
      () => services.saves.create(
        label: '测试',
        packageRef: _ref,
        storyId: 'start',
        world: const WorldSnapshot(
          variables: {'day': 1},
          characters: {},
          story: {'storyId': 'start', 'nodeId': 'start', 'day': 1},
          presentation: {
            'scene': '',
            'appearance': {'expressionId': _staleExpression},
          },
          eventHistory: {},
          rngState: 1,
        ),
      ),
    );
    expect(slot, isNotNull);

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

    // 断言前置：读档先恢复成存档里那张旧脸。
    expect(
      _savedExpression(services, slot!.saveId),
      _staleExpression,
      reason: '读档时应当先恢复存档里的表情',
    );

    // 说一句话 → 离线 mock 从「可用立绘」表里挑表情（这里只有 平常）。
    await tester.enterText(find.byType(TextField), '你好');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));

    // 打字机 + 记忆整理 + 保存都是异步的，等到存档里出现新表情为止。
    String? saved;
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      saved = _savedExpression(services, slot.saveId);
      if (saved == '平常') break;
    }

    expect(
      saved,
      '平常',
      reason: '聊完这一句之后，存档里的表情应当是最新那张（而不是旧脸「$_staleExpression」）',
    );

    // 收尾：让页面正常销毁，避免遗留定时器。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });
}

/// 直接读存档文件里的表情（不经过页面状态）。
String? _savedExpression(AppServices services, String saveId) {
  final loaded = services.saves.load(saveId);
  final world = loaded.slot?.world;
  if (world == null) return null;
  final appearance = world.presentation['appearance'];
  if (appearance is! Map) return null;
  final v = appearance['expressionId'];
  return v is String ? v : null;
}
