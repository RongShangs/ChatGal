import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:gal_protocol/gal_protocol.dart';
import 'package:path/path.dart' as p;

import 'install_limits.dart';
import 'install_log.dart';
import 'install_result.dart';
import 'package_files.dart';
import 'zip_preflight.dart';

/// Filesystem package installer: zip or directory → validated immutable install.
class PackageInstaller {
  PackageInstaller({
    required this.rootDir,
    InstallLimits limits = InstallLimits.defaults,
  })  : limits = limits,
        log = InstallLog(p.join(rootDir, 'install_log.json'));

  final String rootDir;
  final InstallLimits limits;
  final InstallLog log;

  /// Install from a .chatgal zip or a directory containing package files.
  Future<InstallResult> installFromPath(String sourcePath) async {
    final src = Directory(sourcePath);
    final zip = File(sourcePath);
    Directory staging;
    try {
      if (src.existsSync()) {
        staging = await _stagingFromDirectory(src);
      } else if (zip.existsSync()) {
        staging = await _stagingFromZip(zip);
      } else {
        return InstallResult.failure(
          error: ValidationError(
            code: ErrorCodes.invalidValue,
            message: 'Source not found',
            path: sourcePath,
          ),
        );
      }
    } on InstallException catch (e) {
      return InstallResult.failure(error: e.error);
    } catch (e) {
      return InstallResult.failure(
          error: ValidationError(
        code: ErrorCodes.invalidValue,
        message: 'Cannot read package: $e',
        path: sourcePath,
      ));
    }

    try {
      final scan = await _scanTree(staging, enforceInstallLimits: true);
      final files = scan.files;
      final content = PackageLoader.fromFiles(files);
      final report = const PackageValidator().validate(content);
      if (!report.isValid) {
        await log.write({
          'phase': 'failed',
          'reason': 'validation',
          'errors': report.errors.map((e) => e.toJson()).toList(),
        });
        await _deleteQuietly(staging);
        return InstallResult.failure(error: report.errors.first);
      }

      final hash = scan.contentHash;
      final m = content.manifest;
      final ref = PackageRef(
        packageId: m.packageId,
        version: m.version,
        contentHash: hash,
        displayName: m.name,
      );

      final installDir = p.join(rootDir, 'packages', m.packageId, m.version);
      final existingHash = _readInstalledHash(installDir);
      if (existingHash == hash) {
        // 同内容重装无需删除正在被存档使用的正式目录。
        await _deleteQuietly(staging);
        return InstallResult.success(
          packageRef: ref,
          installDir: installDir,
          contentHash: hash,
        );
      }
      // 旧 v1 哈希（无版本前缀）：重算旧安装的 v2 哈希再比较。
      // 只有实际内容一致才允许算法升级覆盖；内容不同仍按冲突拒绝。
      final existingIsStale =
          existingHash != null && !existingHash.startsWith('$_hashVersion:');
      if (existingIsStale) {
        final recomputed = await _rehashInstalled(installDir);
        if (recomputed == hash) {
          // 内容一致：升级哈希标记（原地写新 hash），无需重拷文件。
          await File(p.join(installDir, '.content_hash')).writeAsString(hash);
          await _deleteQuietly(staging);
          return InstallResult.success(
            packageRef: ref,
            installDir: installDir,
            contentHash: hash,
          );
        }
        // 内容确实不同：仍按同版本冲突拒绝。
        await _deleteQuietly(staging);
        await log.write({
          'phase': 'failed',
          'reason': 'content_hash_conflict_stale_upgrade',
          'packageId': m.packageId,
          'version': m.version,
          'existing': existingHash,
          'recomputed': recomputed,
          'incoming': hash,
        });
        return InstallResult.failure(
          error: ValidationError(
            code: ErrorCodes.invalidValue,
            message:
                'Same packageId+version with different content (stale hash upgrade refused)',
            path: '/manifest',
            hint:
                'existing=$existingHash recomputed=$recomputed incoming=$hash',
          ),
        );
      }
      if (existingHash != null && existingHash != hash) {
        // 同版本、同为 v2 哈希、但内容不同 → 真冲突，禁止覆盖。
        await _deleteQuietly(staging);
        await log.write({
          'phase': 'failed',
          'reason': 'content_hash_conflict',
          'packageId': m.packageId,
          'version': m.version,
        });
        return InstallResult.failure(
          error: ValidationError(
            code: ErrorCodes.invalidValue,
            message:
                'Same packageId+version with different contentHash is forbidden',
            path: '/manifest',
            hint: 'existing=$existingHash incoming=$hash',
          ),
        );
      }
      // existingHash == null：全新安装，继续走发布路径。

      // 原子发布：先写到旁路临时目录（含 .content_hash），再整目录换名就位。
      // 直接往正式目录逐文件复制时，进程被杀会留下半安装残骸 ——
      // 列表若没有完成标记就会把坏包列出来。
      final parent = Directory(p.dirname(installDir));
      await parent.create(recursive: true);
      final tmpDir = await parent.createTemp('${m.version}.tmp_install_');
      await _copyTree(staging, tmpDir);
      await File(p.join(tmpDir.path, '.content_hash')).writeAsString(hash);
      // 覆盖已存在的同版本目录（identical 重装路径）。
      if (Directory(installDir).existsSync()) {
        await _deleteQuietly(Directory(installDir));
      }
      await tmpDir.rename(installDir);
      await _deleteQuietly(staging);
      await log.write({
        'phase': 'registered',
        'packageId': m.packageId,
        'version': m.version,
        'contentHash': hash,
      });
      return InstallResult.success(
        packageRef: ref,
        installDir: installDir,
        contentHash: hash,
      );
    } on PackageFormatException catch (e) {
      await _deleteQuietly(staging);
      return InstallResult.failure(error: e.errors.first);
    } catch (e) {
      await _deleteQuietly(staging);
      return InstallResult.failure(
        error: ValidationError(
          code: ErrorCodes.invalidValue,
          message: 'Install failed: $e',
          path: '/',
        ),
      );
    }
  }

  /// Export an installed package directory as .chatgal zip.
  Future<ExportResult> exportInstalled(String installDir) async {
    final dir = Directory(installDir);
    if (!dir.existsSync()) {
      return ExportResult.failure(
        error: ValidationError(
          code: ErrorCodes.invalidValue,
          message: 'Install dir missing',
          path: installDir,
        ),
      );
    }
    final scan = await _scanTree(dir);
    final files = scan.files;
    final content = PackageLoader.fromFiles(files);
    final hashFile = File(p.join(installDir, '.content_hash'));
    final hash = hashFile.existsSync()
        ? hashFile.readAsStringSync().trim()
        : scan.contentHash;
    final m = content.manifest;
    final ref = PackageRef(
      packageId: m.packageId,
      version: m.version,
      contentHash: hash,
      displayName: m.name,
    );

    final archive = Archive();
    final rootPath = dir.absolute.path.replaceAll('\\', '/');
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final abs = entity.path.replaceAll('\\', '/');
      final rel = abs.substring(rootPath.length + 1);
      // 与读树同一份「包内容」判据：临时文件（`*.tmp`）和点前缀残留不进导出包。
      if (!isPackageContentPath(rel)) continue;
      final bytes = await entity.readAsBytes();
      archive.addFile(ArchiveFile(rel, bytes.length, bytes));
    }
    final zipBytes = ZipEncoder().encode(archive);
    if (zipBytes.isEmpty) {
      return ExportResult.failure(
        error: ValidationError(
          code: ErrorCodes.invalidValue,
          message: 'Zip encode failed',
          path: installDir,
        ),
      );
    }
    final outPath = p.join(
      rootDir,
      'exports',
      '${m.packageId}-${m.version}.chatgal',
    );
    await Directory(p.dirname(outPath)).create(recursive: true);
    await File(outPath).writeAsBytes(zipBytes, flush: true);
    await log.write({
      'phase': 'exported',
      'packageId': m.packageId,
      'version': m.version,
      'file': outPath,
    });
    return ExportResult.success(file: outPath, packageRef: ref);
  }

  String? _readInstalledHash(String installDir) {
    final f = File(p.join(installDir, '.content_hash'));
    if (!f.existsSync()) return null;
    return f.readAsStringSync().trim();
  }

  /// 把 .chatgal 解压到 [destDir]（供**内容包创作台**把包导入成工程），
  /// 复用与安装完全同一套安全校验：大小/条目上限、禁 `..` 与绝对路径、路径穿越。
  /// 解压后只保留包内容（zip 若套了一层外层目录，会被剥掉）。
  Future<void> extractTo(String zipPath, String destDir) async {
    final zip = File(zipPath);
    if (!zip.existsSync()) {
      throw InstallException(ValidationError(
        code: ErrorCodes.invalidValue,
        message: 'ZIP not found',
        path: zipPath,
      ));
    }
    final staging = await _stagingFromZip(zip);
    try {
      final dest = Directory(destDir);
      await dest.create(recursive: true);
      await _copyTree(staging, dest);
    } finally {
      await _deleteQuietly(staging);
    }
  }

  /// 目录内容的确定性哈希（与安装时写进 `.content_hash` 的算法一致），
  /// 用来判断「同 packageId + 同 version 但内容不同」。
  Future<String> hashOfDirectory(String dir) async {
    return (await _scanTree(Directory(dir))).contentHash;
  }

  /// 用当前算法重算已安装目录的哈希（用于 v1→v2 迁移比较）。
  /// 目录不存在或读取失败时返回空串（与任何真实哈希都不同）。
  Future<String> _rehashInstalled(String installDir) async {
    try {
      final dir = Directory(installDir);
      if (!dir.existsSync()) return '';
      return await hashOfDirectory(installDir);
    } catch (_) {
      return '';
    }
  }

  Future<Directory> _stagingFromZip(File zip) async {
    if (zip.lengthSync() > limits.maxZipBytes) {
      throw InstallException(ValidationError(
        code: ErrorCodes.invalidValue,
        message: 'ZIP exceeds size limit',
        path: zip.path,
      ));
    }
    final bytes = zip.readAsBytesSync();
    // **先看中央目录再解压**：条目数 / 声明解压大小 / symlink 条目这三类
    // 原来要等 decodeBytes 之后才判，而 decode 会为每个条目建对象、
    // symlink 还会立刻读出链接内容 —— 限额来不及生效。
    final preflight = ZipPreflight.check(bytes, limits, path: zip.path);
    if (preflight != null) {
      throw InstallException(preflight);
    }
    final archive = ZipDecoder().decodeBytes(bytes);
    if (archive.length > limits.maxEntries) {
      throw InstallException(ValidationError(
        code: ErrorCodes.invalidValue,
        message: 'Too many entries',
        path: zip.path,
      ));
    }
    final staging = Directory(
      p.join(rootDir, 'staging', '${DateTime.now().microsecondsSinceEpoch}'),
    );
    await staging.create(recursive: true);
    try {
      await log.write({'phase': 'staging', 'source': zip.path});

      var total = 0;
      for (final file in archive) {
        final name = file.name.replaceAll('\\', '/');
        if (name.isEmpty || name.contains('..') || name.startsWith('/')) {
          throw InstallException(ValidationError(
            code: ErrorCodes.invalidValue,
            message: 'Illegal zip path',
            path: name,
          ));
        }
        final dest = p.normalize(p.join(staging.path, name));
        if (!p.isWithin(staging.path, dest)) {
          throw InstallException(ValidationError(
            code: ErrorCodes.invalidValue,
            message: 'Path traversal blocked',
            path: name,
          ));
        }
        if (file.isFile) {
          final remaining = limits.maxExtractedBytes - total;
          final cap = name.toLowerCase().endsWith('.json') &&
                  limits.maxJsonBytes < remaining
              ? limits.maxJsonBytes
              : remaining;
          if (file.size < 0 || file.size > cap || file.symbolicLink != null) {
            throw InstallException(ValidationError(
              code: ErrorCodes.invalidValue,
              message: 'Extracted size exceeds limit',
              path: name,
            ));
          }
          await File(dest).parent.create(recursive: true);
          // 声明大小用于提前拒绝，实际输出也必须逐块限额，不能先整体解压。
          final output = _LimitedFileOutput(dest, cap);
          try {
            file.writeContent(output);
            total += output.length;
          } finally {
            output.closeSync();
          }
        } else {
          await Directory(dest).create(recursive: true);
        }
      }
      // If zip had a single top-level folder, unwrap it
      final entries = staging.listSync();
      if (entries.length == 1 && entries.first is Directory) {
        final wrapper = entries.first as Directory;
        for (final child in wrapper.listSync()) {
          await child.rename(p.join(staging.path, p.basename(child.path)));
        }
        await wrapper.delete();
      }
      return staging;
    } catch (_) {
      await _deleteQuietly(staging);
      rethrow;
    }
  }

  Future<Directory> _stagingFromDirectory(Directory src) async {
    await log.write({'phase': 'staging', 'source': src.path});
    final staging = Directory(
      p.join(rootDir, 'staging', '${DateTime.now().microsecondsSinceEpoch}'),
    );
    try {
      // 目录来源（创作台「装到本地」）同样过限额：以前这条路**一个上限都没有**，
      // 一棵超大工程树会被整棵复制、整棵读进内存。
      await _copyTree(src, staging, enforceLimits: true);
      return staging;
    } catch (_) {
      await _deleteQuietly(staging);
      rethrow;
    }
  }

  /// 一次遍历把「包文件内容」和「内容哈希」都拿到。
  ///
  /// 相比以前的写法有两个变化：
  /// * **二进制不再 base64 常驻内存**：map 里只留 key（值为空串），
  ///   字节在下面分块算哈希，不整份进内存
  ///   （以前装内置默认包会在内存里攥着 66MB 图片的 base64 ≈ 89MB 字符串）；
  /// * 目录来源安装可以边遍历边挡限额（[enforceInstallLimits]）。
  ///
  /// 哈希**必须与旧实现逐位一致**：它写在 `.content_hash` 里，存档又绑着它，
  /// 而且 app 启动时用 `startsWith('v2:')` 判断默认包要不要重装。
  /// 所以二进制照旧按 base64 文本摘要，见 [_digestOfBase64EncodedFile]。
  Future<_TreeScan> _scanTree(
    Directory dir, {
    bool enforceInstallLimits = false,
  }) async {
    final root = dir.absolute.path.replaceAll('\\', '/');
    final files = <String, String>{};
    final digests = <String, String>{};
    var entries = 0;
    var bytes = 0;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final abs = entity.path.replaceAll('\\', '/');
      final rel = abs.substring(root.length + 1);
      // 「哪些文件算包内容」只有这一份判据（与拷贝、导出共用）。
      if (!isPackageContentPath(rel)) continue;
      final length = await entity.length();
      entries++;
      bytes += length;
      if (enforceInstallLimits) {
        if (entries > limits.maxEntries) {
          throw InstallException(ValidationError(
            code: ErrorCodes.invalidValue,
            message: 'Too many entries',
            path: rel,
            hint: '上限=${limits.maxEntries}',
          ));
        }
        if (bytes > limits.maxExtractedBytes) {
          throw InstallException(ValidationError(
            code: ErrorCodes.invalidValue,
            message: 'Extracted size exceeds limit',
            path: rel,
            hint: '累计 $bytes 字节，上限=${limits.maxExtractedBytes}',
          ));
        }
      }
      if (isTextPackFile(rel)) {
        if (rel.toLowerCase().endsWith('.json') &&
            length > limits.maxJsonBytes) {
          throw InstallException(ValidationError(
            code: ErrorCodes.invalidValue,
            message: 'JSON too large',
            path: rel,
          ));
        }
        final text = await entity.readAsString();
        files[rel] = text;
        digests[rel] = '${sha256.convert(utf8.encode(text))}';
      } else {
        files[rel] = '';
        digests[rel] = '${await _digestOfBase64EncodedFile(entity)}';
      }
    }
    final keys = digests.keys.toList()..sort();
    final buf = StringBuffer();
    for (final k in keys) {
      buf.writeln('$k:${digests[k]}');
    }
    return _TreeScan(
      files,
      '$_hashVersion:${sha256.convert(utf8.encode(buf.toString()))}',
    );
  }

  Future<void> _copyTree(
    Directory from,
    Directory to, {
    bool enforceLimits = false,
  }) async {
    await to.create(recursive: true);
    final root = from.absolute.path.replaceAll('\\', '/');
    var entries = 0;
    var bytes = 0;
    await for (final entity in from.list(recursive: true, followLinks: false)) {
      final abs = entity.path.replaceAll('\\', '/');
      final rel = abs.substring(root.length + 1);
      // 与读树/导出同一份判据：临时文件与点前缀残留不跟进安装目录、工程量。
      if (!isPackageContentPath(rel)) continue;
      final segments = rel.split('/');
      final dest = p.joinAll([to.path, ...segments]);
      if (entity is File) {
        if (enforceLimits) {
          entries++;
          bytes += await entity.length();
          if (entries > limits.maxEntries) {
            throw InstallException(ValidationError(
              code: ErrorCodes.invalidValue,
              message: 'Too many entries',
              path: rel,
              hint: '上限=${limits.maxEntries}',
            ));
          }
          if (bytes > limits.maxExtractedBytes) {
            throw InstallException(ValidationError(
              code: ErrorCodes.invalidValue,
              message: 'Extracted size exceeds limit',
              path: rel,
              hint: '累计 $bytes 字节，上限=${limits.maxExtractedBytes}',
            ));
          }
        }
        await File(dest).parent.create(recursive: true);
        await entity.copy(dest);
      } else if (entity is Directory) {
        await Directory(dest).create(recursive: true);
      }
    }
  }

  /// 内容哈希算法版本：v2 起把二进制素材的字节也纳入哈希。
  /// 旧安装的 `.content_hash` 没有版本前缀（v1，只哈希文本），
  /// 升级后同内容会得到不同哈希 —— 通过前缀区分，旧标记一律视为过期。
  static const _hashVersion = 'v2';

  /// 分块把文件字节按 base64 编码后喂给 sha256（**不把整份 base64 留在内存**）。
  ///
  /// base64 是「每 3 字节一组、组与组独立」的编码，所以按 3 字节对齐切块、
  /// 逐块编码再拼接 = 整份 `base64Encode(bytes)`。于是摘要与旧实现
  /// `sha256(utf8.encode(base64Encode(bytes)))` 逐位相同 —— 哈希值一个字都不能变，
  /// 见 [_scanTree] 的说明。
  Future<Digest> _digestOfBase64EncodedFile(File file) async {
    final sink = _DigestSink();
    final input = sha256.startChunkedConversion(sink);
    final pending = <int>[];
    await for (final chunk in file.openRead()) {
      pending.addAll(chunk);
      final usable = pending.length - pending.length % 3;
      if (usable == 0) continue;
      input.add(utf8.encode(base64Encode(pending.sublist(0, usable))));
      pending.removeRange(0, usable);
    }
    if (pending.isNotEmpty) {
      input.add(utf8.encode(base64Encode(pending)));
    }
    input.close();
    return sink.value!;
  }

  Future<void> _deleteQuietly(Directory dir) async {
    try {
      if (dir.existsSync()) await dir.delete(recursive: true);
    } catch (_) {}
  }
}

class _TreeScan {
  const _TreeScan(this.files, this.contentHash);

  /// 文本文件的内容；**二进制文件只有 key**（值为空串，字节不驻内存）。
  final Map<String, String> files;
  final String contentHash;
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

class _LimitedFileOutput extends OutputFileStream {
  _LimitedFileOutput(String path, this.limit)
      : super.withFileHandle(FileHandle(path, mode: FileAccess.write));
  final int limit;

  void _check(int count) {
    if (count < 0 || length + count > limit) {
      throw InstallException(ValidationError(
        code: ErrorCodes.invalidValue,
        message: 'Extracted size exceeds limit',
        path: '/',
      ));
    }
  }

  @override
  void writeByte(int value) {
    _check(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _check(length ?? bytes.length);
    super.writeBytes(bytes, length: length);
  }
}

class InstallException implements Exception {
  InstallException(this.error);
  final ValidationError error;
}
