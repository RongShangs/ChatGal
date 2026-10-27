import 'dart:io';

import 'package:archive/archive.dart';
import 'package:gal_protocol/gal_protocol.dart';
import 'package:gal_storage/gal_storage.dart';
import 'package:test/test.dart';

/// 把 `content/default_v2` 现打成一个 `.chatgal`（等价于仓库打包脚本的产物）
/// 再走一遍安装器。
///
/// 这里**不再依赖 `apps/chatgal/assets/hellojj_default.chatgal`**：那是上一版
/// 内容包格式的打包产物（manifest 里还有 schemaVersion / characterVariables，
/// version 是 "2.4.0-zh-id" 这种非数字），装不上也不该由本测试来断言。
/// 包源（content/default_v2）才是真相，版本号也从它读。
void main() {
  test('默认包（从 content/default_v2 现打包）能被安装', () async {
    final src = Directory('${Directory.current.path}/../../content/default_v2');
    expect(src.existsSync(), isTrue, reason: src.path);

    final manifestJson = decodeJsonc(
      File('${src.path}/manifest.json').readAsStringSync(),
    );
    final manifest = PackageManifest.fromJson(
      Map<String, Object?>.from(manifestJson! as Map),
    );

    // 打 zip：目录里的每一个文件都按包内相对路径放进归档
    final tmp = await Directory.systemTemp.createTemp('chatgal_install_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final archive = Archive();
    final rootPath = src.absolute.path.replaceAll(r'\', '/');
    for (final f in src.listSync(recursive: true).whereType<File>()) {
      final rel = f.path.replaceAll(r'\', '/').substring(rootPath.length + 1);
      archive.addFile(ArchiveFile.bytes(rel, f.readAsBytesSync()));
    }
    final zip = File('${tmp.path}/hellojj_default.chatgal');
    zip.writeAsBytesSync(ZipEncoder().encode(archive));
    expect(zip.lengthSync(), greaterThan(0));

    final installRoot = await Directory.systemTemp.createTemp('chatgal_root_');
    addTearDown(() => installRoot.deleteSync(recursive: true));
    final installer = PackageInstaller(rootDir: installRoot.path);
    final result = await installer.installFromPath(zip.path);
    expect(result.ok, isTrue, reason: '${result.error?.message}');

    // 版本号来自包源（数字），不是测试里写死的字符串
    expect(result.packageRef!.version, manifest.version);
    expect(result.packageRef!.packageId, manifest.packageId);

    final dir = Directory(result.installDir!);
    expect(File('${dir.path}/manifest.json').existsSync(), isTrue);
    expect(File('${dir.path}/home.png').existsSync(), isTrue);
    expect(
      Directory('${dir.path}/stories')
          .listSync()
          .where((e) => e is File && e.path.endsWith('.json'))
          .length,
      greaterThanOrEqualTo(2),
      reason: '扁平 stories/<情景id>.json',
    );
    // 角色目录与立绘名都是中文：解包/落盘必须原样保住（zip 里的 UTF-8 名字）
    expect(
      File('${dir.path}/characters/戒戒/character.json').existsSync(),
      isTrue,
    );
    expect(
      File('${dir.path}/characters/戒戒/校服_开心.png').existsSync(),
      isTrue,
    );
    expect(Directory('${dir.path}/events').existsSync(), isTrue);
  });

  test('被打包的默认包自检：内容包校验器认为它合规', () {
    final src = Directory('${Directory.current.path}/../../content/default_v2');
    final rootPath = src.absolute.path.replaceAll(r'\', '/');
    final files = <String, String>{};
    for (final f in src.listSync(recursive: true).whereType<File>()) {
      final rel = f.path.replaceAll(r'\', '/').substring(rootPath.length + 1);
      files[rel] = rel.endsWith('.png') ? '' : f.readAsStringSync();
    }
    final content = PackageLoader.fromFiles(files);
    final report = const PackageValidator().validate(content);
    expect(report.isValid, isTrue, reason: report.toString());
  });
}
