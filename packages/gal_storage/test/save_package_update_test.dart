import 'dart:convert';
import 'dart:io';

import 'package:gal_protocol/gal_protocol.dart';
import 'package:gal_storage/gal_storage.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Map<String, String> _files({required String packageId, required String version}) => {
      'manifest.json': '{"packageId":"$packageId","version":"$version",'
          '"name":"演示","author":"t","description":"d",'
          '"variables":[{"id":"day","type":"int","default":1,"min":1,"max":9999}]}',
      'home.png': '',
      'characters/戒戒/character.json':
          '{"id":"戒戒","prompt":"你是戒戒。","states":["校服"],"emotions":["平常"],'
              '"defaultState":"校服","defaultEmotion":"平常"}',
      'characters/戒戒/校服_平常.png': '',
      'stories/start.json': '{"displayName":"白天·学校","background":"bg.png",'
          '"narration":"n",'
          '"characters":[{"charId":"戒戒","state":"校服","emotion":"平常",'
          '"scenePrompt":"本幕：学校。"}],'
          '"fixedEffects":[],'
          '"target":[{"kind":[{"kind":"story","to":"start"}]}]}',
      'stories/bg.png': '',
    };

/// 把一个包目录写盘并安装，返回它的 PackageRef。
Future<PackageRef> _install(
  Directory root,
  String dirName, {
  required String packageId,
  required String version,
}) async {
  final src = Directory(p.join(root.path, dirName))
    ..createSync(recursive: true);
  _files(packageId: packageId, version: version).forEach((rel, body) {
    final f = File(p.join(src.path, rel));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(body);
  });
  final installer = PackageInstaller(rootDir: root.path);
  final result = await installer.installFromPath(src.path);
  expect(result.ok, isTrue, reason: '${result.error?.message}');
  return result.packageRef!;
}

WorldSnapshot _world() => const WorldSnapshot(
      variables: {},
      characters: {},
      eventHistory: {},
      story: {'storyId': 'start'},
      presentation: {},
      rngState: 1,
    );

void main() {
  test('同一个包升版本后旧存档仍可进入（不再被锁成空档）', () async {
    final root = Directory.systemTemp.createTempSync('chatgal_upd_');
    final store = PackageStore(root.path);
    final saves = SaveRepository(rootDir: root.path, packages: store);

    // 版本号只能是数字，所以用 100 → 200 表示升版本
    final v1 = await _install(root, 'v1', packageId: 'demo.upd', version: '100');
    final slot = await saves.create(
      label: '测试档',
      packageRef: v1,
      storyId: 'start',
      world: _world(),
      messages: const [
        {'role': 'user', 'content': '第一句'},
        {'role': 'assistant', 'content': '嗯。'},
      ],
    );
    expect(saves.load(slot.saveId).canEnter, isTrue);

    // 装上同 id 的新版本，并按应用的清理策略卸载旧版
    // （AppServices.ensureDefaultPackage 就是这么干的）——
    // 这时旧存档的 packageRef 就解析不到精确命中了。
    await _install(root, 'v2', packageId: 'demo.upd', version: '200');
    await store.uninstall(v1);
    expect(store.findExact(v1.packageId, v1.version, v1.contentHash), isNull);

    final after = saves.load(slot.saveId);
    expect(after.canEnter, isTrue, reason: '同包升级不该把存档锁死');
    expect(after.detail, contains('包已更新'));
    // 存档内容原样保留
    expect(after.slot!.messageCheckpoint.length, 2);
    expect(after.slot!.messageCheckpoint.first['content'], '第一句');

    // 换成完全不同的包 id 才应该锁
    final strange = SaveSlot(
      saveId: 'save_strange',
      sessionId: 's',
      label: '别的包',
      packageRef: const PackageRef(
        packageId: 'nobody.here',
        version: '999',
        contentHash: 'x',
      ),
      storyId: 'start',
      world: _world(),
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    await store.listInstalled(); // 确保索引已建
    final file = File(p.join(root.path, 'saves', '${strange.saveId}.json'));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('${_jsonOf(strange)}');
    final missing = saves.load(strange.saveId);
    expect(missing.canEnter, isFalse);
    expect(missing.reason, SaveLockReason.missingPackage);

    root.deleteSync(recursive: true);
  });

  test('第一份存档就是完整的当前 schema', () async {
    final root = Directory.systemTemp.createTempSync('chatgal_new_');
    final store = PackageStore(root.path);
    final saves = SaveRepository(rootDir: root.path, packages: store);
    final ref = await _install(root, 'v1', packageId: 'demo.new', version: '100');
    final slot = await saves.create(
      label: '新档',
      packageRef: ref,
      storyId: 'start',
      world: _world(),
      messages: const [
        {'role': 'assistant', 'content': '（抬眼看了看你）'},
      ],
      memory: const {'byChar': {}},
    );
    final back = saves.load(slot.saveId).slot!;
    expect(back.saveSchemaVersion, SaveSlot.currentSchemaVersion);
    expect(back.memoryCheckpoint, isNotEmpty);
    expect(back.messageCheckpoint.length, 1);
    root.deleteSync(recursive: true);
  });
}

String _jsonOf(SaveSlot slot) {
  // 直接用仓库自己的序列化形状（写盘时也是这一份，只是多缩进）。
  return jsonEncode(slot.toJson());
}
