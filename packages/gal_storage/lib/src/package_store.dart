import 'dart:io';

import 'package:gal_protocol/gal_protocol.dart';
import 'package:path/path.dart' as p;

/// Lists installed package versions under rootDir/packages.
class PackageStore {
  PackageStore(this.rootDir);

  final String rootDir;

  List<PackageRef> listInstalled() {
    final out = <PackageRef>[];
    final packages = Directory(p.join(rootDir, 'packages'));
    if (!packages.existsSync()) return out;
    for (final idDir in packages.listSync()) {
      if (idDir is! Directory) continue;
      for (final verDir in idDir.listSync()) {
        if (verDir is! Directory) continue;
        final manifestFile = File(p.join(verDir.path, 'manifest.json'));
        final hashFile = File(p.join(verDir.path, '.content_hash'));
        // 半安装不可见：安装器是「逐文件复制 → 写 .content_hash」，
        // 没有 .content_hash 的目录是复制到一半的残骸（进程被杀等），
        // 列出来会让玩家选到坏包。`.content_hash` 就是完成标记。
        if (!manifestFile.existsSync() || !hashFile.existsSync()) continue;
        try {
          // 已装包的 manifest.json 允许带 `//` 注释（安装器原样落盘），
          // 用裸 jsonDecode 会解析失败、异常被吞掉 —— 表现就是「装好的包
          // 突然看不见」，连存档都会被判成「包缺失」。走同一个 JSONC 解析。
          final decoded = decodeJsonc(manifestFile.readAsStringSync())
              as Map<String, dynamic>;
          final m = PackageManifest.fromJson(decoded.cast<String, Object?>());
          // 临时发布目录即使已有完成标记也不能冒充正式安装。
          if (p.basename(idDir.path) != m.packageId ||
              p.basename(verDir.path) != m.version) continue;
          out.add(PackageRef(
            packageId: m.packageId,
            version: m.version,
            contentHash: hashFile.readAsStringSync().trim(),
            displayName: m.name,
          ));
        } catch (_) {}
      }
    }
    return out;
  }

  PackageRef? findExact(String packageId, String version, String contentHash) {
    for (final r in listInstalled()) {
      if (r.packageId == packageId &&
          r.version == version &&
          r.contentHash == contentHash) {
        return r;
      }
    }
    return null;
  }

  String installDirOf(PackageRef ref) =>
      p.join(rootDir, 'packages', ref.packageId, ref.version);

  /// Remove an installed package directory.
  Future<bool> uninstall(PackageRef ref) async {
    final dir = Directory(installDirOf(ref));
    if (!dir.existsSync()) return false;
    await dir.delete(recursive: true);
    return true;
  }
}
