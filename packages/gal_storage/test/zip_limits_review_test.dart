import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:gal_storage/gal_storage.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  setUp(
      () => root = Directory.systemTemp.createTempSync('chatgal_zip_review_'));
  tearDown(() => root.deleteSync(recursive: true));

  test('malformed archive returns failure rather than throwing', () async {
    final zip = File('${root.path}/broken.chatgal')
      ..writeAsBytesSync([1, 2, 3]);
    final result =
        await PackageInstaller(rootDir: root.path).installFromPath(zip.path);
    expect(result.ok, isFalse);
  });

  test('oversized output rejects import and cleans staging', () async {
    final archive = Archive()
      ..addFile(ArchiveFile('large.bin', 4096, List.filled(4096, 0)));
    final zip = File('${root.path}/large.chatgal')
      ..writeAsBytesSync(ZipEncoder().encode(archive));
    final installer = PackageInstaller(
        rootDir: root.path,
        limits: const InstallLimits(maxExtractedBytes: 100));
    await expectLater(installer.extractTo(zip.path, '${root.path}/out'),
        throwsA(isA<InstallException>()));
    // 现在连 staging 都不会建：声明大小在解压前就被中央目录检查挡下了。
    _expectCleanStaging(root);
  });

  test('single wrapper extracted without leaving staging directory', () async {
    final archive = Archive()..addFile(ArchiveFile('pack/a.txt', 3, [1, 2, 3]));
    final zip = File('${root.path}/wrapped.chatgal')
      ..writeAsBytesSync(ZipEncoder().encode(archive));
    await PackageInstaller(rootDir: root.path)
        .extractTo(zip.path, '${root.path}/out');
    expect(File('${root.path}/out/a.txt').readAsBytesSync(), [1, 2, 3]);
    expect(Directory('${root.path}/staging').listSync(), isEmpty);
  });

  test('forged small declared size is still limited during decompression',
      () async {
    final archive = Archive()
      ..addFile(ArchiveFile('large.bin', 4096, List.filled(4096, 0)));
    final bytes = Uint8List.fromList(ZipEncoder().encode(archive));
    final data = ByteData.sublistView(bytes);
    for (var i = 0; i + 28 <= bytes.length; i++) {
      final signature = data.getUint32(i, Endian.little);
      if (signature == 0x04034b50) data.setUint32(i + 22, 1, Endian.little);
      if (signature == 0x02014b50) data.setUint32(i + 24, 1, Endian.little);
    }
    final zip = File('${root.path}/forged.chatgal')..writeAsBytesSync(bytes);
    await expectLater(
        PackageInstaller(
                rootDir: root.path,
                limits: const InstallLimits(maxExtractedBytes: 100))
            .extractTo(zip.path, '${root.path}/out'),
        throwsA(isA<InstallException>()));
    expect(Directory('${root.path}/staging').listSync(), isEmpty);
  });

  // ---------------------------------------------------------------- 中央目录前置检查

  test('伪造条目数：解压前就被中央目录挡下', () async {
    final bytes = _zipOf([
      ArchiveFile('a.bin', 3, [1, 2, 3]),
      ArchiveFile('b.bin', 3, [4, 5, 6]),
    ]);
    const limits = InstallLimits(maxEntries: 2);
    // 真实条目数 2 = 上限：放行
    expect(ZipPreflight.check(bytes, limits, path: 'ok.chatgal'), isNull);

    // 把 EOCD 里声明的总条目数改成 99（> 上限）——不改任何条目数据
    ByteData.sublistView(bytes).setUint16(_eocdOffset(bytes) + 10, 99, Endian.little);
    expect(
      ZipPreflight.check(bytes, limits, path: 'forged.chatgal')?.message,
      'Too many entries',
    );

    final zip = File('${root.path}/entries.chatgal')..writeAsBytesSync(bytes);
    await expectLater(
      PackageInstaller(rootDir: root.path, limits: limits)
          .extractTo(zip.path, '${root.path}/out'),
      throwsA(isA<InstallException>()),
    );
    _expectCleanStaging(root);
  });

  test('伪造声明解压大小：总字节在解压前就被挡下（单个文件都不过限）', () async {
    final bytes = _zipOf([
      ArchiveFile('a.bin', 10, List<int>.filled(10, 1)),
      ArchiveFile('b.bin', 10, List<int>.filled(10, 2)),
    ]);
    // 每个条目都声明成解压后 600 字节：单个都不过限（600 ≤ 1000），
    // 合起来 1200 > 1000 —— 只看单个文件的限额是挡不住的。
    const limits = InstallLimits(maxExtractedBytes: 1000);
    final data = ByteData.sublistView(bytes);
    for (final offset in _centralEntries(bytes)) {
      data.setUint32(offset + 24, 600, Endian.little);
    }
    expect(
      ZipPreflight.check(bytes, limits, path: 'forged.chatgal')?.message,
      'Extracted size exceeds limit',
    );

    final zip = File('${root.path}/declared.chatgal')..writeAsBytesSync(bytes);
    await expectLater(
      PackageInstaller(rootDir: root.path, limits: limits)
          .extractTo(zip.path, '${root.path}/out'),
      throwsA(isA<InstallException>()),
    );
    _expectCleanStaging(root);
  });

  test('symlink 条目：解压前就被拒绝', () async {
    final bytes = _zipOf([ArchiveFile('link.bin', 3, [1, 2, 3])]);
    final limits = InstallLimits.defaults;
    expect(ZipPreflight.check(bytes, limits, path: 'ok.chatgal'), isNull);

    final data = ByteData.sublistView(bytes);
    final offset = _centralEntries(bytes).single;
    // versionMadeBy 高 16 位 = 3：unix 打的包（archive 也只在此时把权限位当 symlink）
    data.setUint16(offset + 4, 0x031E, Endian.little);
    // external attributes 高 16 位 = 0xA1FF → mode & 0xf000 == 0xa000
    data.setUint32(offset + 38, 0xA1FF0000, Endian.little);
    expect(
      ZipPreflight.check(bytes, limits, path: 'symlink.chatgal')?.message,
      'Symlink entry is not allowed',
    );

    final zip = File('${root.path}/symlink.chatgal')..writeAsBytesSync(bytes);
    await expectLater(
      PackageInstaller(rootDir: root.path)
          .extractTo(zip.path, '${root.path}/out'),
      throwsA(isA<InstallException>()),
    );
    _expectCleanStaging(root);
  });

  test('解析不出中央目录（zip64 哨兵）时保守放行', () async {
    final bytes = _zipOf([ArchiveFile('a.bin', 3, [1, 2, 3])]);
    // 中央目录偏移写成 zip64 哨兵：前置检查看不懂 → 放行，交给 decode 后的校验
    final data = ByteData.sublistView(bytes);
    data.setUint32(_eocdOffset(bytes) + 16, 0xffffffff, Endian.little);
    expect(
      ZipPreflight.check(bytes, InstallLimits.defaults, path: 'zip64.chatgal'),
      isNull,
    );
  });
}

/// EOCD（`0x06054b50`）在字节里的偏移；注释长度必须正好接到文件末尾。
int _eocdOffset(Uint8List bytes) {
  for (var i = bytes.length - 22; i >= 0; i--) {
    if (bytes[i] == 0x50 &&
        bytes[i + 1] == 0x4b &&
        bytes[i + 2] == 0x05 &&
        bytes[i + 3] == 0x06) {
      final comment = bytes[i + 20] | (bytes[i + 21] << 8);
      if (i + 22 + comment == bytes.length) return i;
    }
  }
  throw StateError('EOCD not found');
}

/// 中央目录里每个条目的起始偏移。
List<int> _centralEntries(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final eocd = _eocdOffset(bytes);
  final count = data.getUint16(eocd + 10, Endian.little);
  var offset = data.getUint32(eocd + 16, Endian.little);
  final out = <int>[];
  for (var i = 0; i < count; i++) {
    out.add(offset);
    offset += 46 +
        data.getUint16(offset + 28, Endian.little) +
        data.getUint16(offset + 30, Endian.little) +
        data.getUint16(offset + 32, Endian.little);
  }
  return out;
}

Uint8List _zipOf(List<ArchiveFile> files) {
  final archive = Archive();
  for (final f in files) {
    archive.addFile(f);
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

/// 前置检查失败时 staging 目录可能还没建起来。
void _expectCleanStaging(Directory root) {
  final staging = Directory('${root.path}/staging');
  expect(
    staging.existsSync() ? staging.listSync() : const <FileSystemEntity>[],
    isEmpty,
  );
}
