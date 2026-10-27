import 'dart:typed_data';

import 'package:gal_protocol/gal_protocol.dart';

import 'install_limits.dart';

/// ZIP 中央目录前置检查：在 `ZipDecoder().decodeBytes()` **之前**就能挡下的三类包。
///
/// 为什么要在解压前做：原来的限额全部落在 decode **之后**
/// （`archive.length` / `file.size` / `file.symbolicLink`），而 decode 会为每个
/// 条目建对象、symlink 条目还会**立刻把链接内容读出来** —— 一个声明了几万条目
/// 或塞满 symlink 的 zip 能在任何限额生效之前就把内存吃掉。
///
/// 只读中央目录，不碰条目数据。**解析不出来一律放行**（zip64、自解压前缀、
/// 尾部有垃圾字节……），交给 decode 之后原有的那套校验 ——
/// 宁可漏挡，也不能因为自己的解析保守就把合法包拒了。
class ZipPreflight {
  const ZipPreflight._();

  static const _centralFileHeaderSignature = 0x02014b50;
  static const _centralFileHeaderSize = 46;
  static const _zip64 = 0xffffffff;

  /// 返回 null = 放行（含「解析不出来，交给 decode 后校验」）。
  ///
  /// [path] 只用于错误里指认来源文件。
  static ValidationError? check(
    Uint8List bytes,
    InstallLimits limits, {
    required String path,
  }) {
    final eocd = _findEndOfCentralDirectory(bytes);
    if (eocd == null) return null;
    final data = ByteData.sublistView(bytes);

    final entries = data.getUint16(eocd + 10, Endian.little);
    final centralSize = data.getUint32(eocd + 12, Endian.little);
    final centralOffset = data.getUint32(eocd + 16, Endian.little);
    // zip64：真正的值在 zip64 记录里，这里读到的全是 0xffff/0xffffffff 哨兵。
    if (entries == 0xffff || centralSize == _zip64 || centralOffset == _zip64) {
      return null;
    }
    final centralEnd = centralOffset + centralSize;
    if (centralEnd > bytes.length ||
        centralOffset + 4 > bytes.length ||
        data.getUint32(centralOffset, Endian.little) !=
            _centralFileHeaderSignature) {
      // EOCD 与中央目录对不上（自解压前缀 / 结构损坏）：保守放行。
      return null;
    }

    if (entries > limits.maxEntries) {
      return ValidationError(
        code: ErrorCodes.invalidValue,
        message: 'Too many entries',
        path: path,
        hint: 'entries=$entries 上限=${limits.maxEntries}',
      );
    }

    var offset = centralOffset;
    var declaredTotal = 0;
    for (var i = 0; i < entries; i++) {
      if (offset + _centralFileHeaderSize > centralEnd ||
          data.getUint32(offset, Endian.little) !=
              _centralFileHeaderSignature) {
        // 中央目录读不通：保守放行（decode 之后的校验照样会跑）。
        return null;
      }
      final versionMadeBy = data.getUint16(offset + 4, Endian.little);
      final declaredSize = data.getUint32(offset + 24, Endian.little);
      final nameLength = data.getUint16(offset + 28, Endian.little);
      final extraLength = data.getUint16(offset + 30, Endian.little);
      final commentLength = data.getUint16(offset + 32, Endian.little);
      final externalAttributes = data.getUint32(offset + 38, Endian.little);

      // 条目级 zip64（大小写进扩展字段）：拆不出来就整体放行。
      if (declaredSize == _zip64) return null;

      declaredTotal += declaredSize;
      if (declaredTotal > limits.maxExtractedBytes) {
        return ValidationError(
          code: ErrorCodes.invalidValue,
          message: 'Extracted size exceeds limit',
          path: path,
          hint: '声明解压后共 $declaredTotal 字节，上限=${limits.maxExtractedBytes}',
        );
      }

      // 只有 unix 系统打的包才把高 16 位当权限位 —— 与 archive 自己的判据一致
      // （ZipDecoder 也是看到 `versionMadeBy` 高位为 3 才把它当 symlink），
      // 所以这里拒绝的集合与原来 decode 之后的 check 完全相同，不会多拒合法包。
      if (versionMadeBy >> 8 == 3 && (externalAttributes >> 16) & 0xf000 == 0xa000) {
        return ValidationError(
          code: ErrorCodes.invalidValue,
          message: 'Symlink entry is not allowed',
          path: path,
          hint: '第 ${i + 1} 个中央目录条目是符号链接',
        );
      }

      offset += _centralFileHeaderSize + nameLength + extraLength + commentLength;
    }
    return null;
  }

  /// 从尾部找 EOCD（`0x06054b50`）。注释最长 65535 字节，所以最多回看 64KB+22。
  /// 只认「注释长度与文件末尾严丝合缝」的那一条，避免把条目数据里的字节当成 EOCD。
  static int? _findEndOfCentralDirectory(Uint8List bytes) {
    const minSize = 22;
    if (bytes.length < minSize) return null;
    final lowest = bytes.length - minSize - 0xffff;
    for (var i = bytes.length - minSize; i >= (lowest < 0 ? 0 : lowest); i--) {
      if (bytes[i] != 0x50 ||
          bytes[i + 1] != 0x4b ||
          bytes[i + 2] != 0x05 ||
          bytes[i + 3] != 0x06) {
        continue;
      }
      final commentLength = bytes[i + 20] | (bytes[i + 21] << 8);
      if (i + minSize + commentLength == bytes.length) return i;
    }
    return null;
  }
}
