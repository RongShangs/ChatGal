import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Crash-recovery log for install pipeline.
/// Phases: staging | hashed | registered | failed
///
/// **append-only，一行一条 JSON（JSONL）**。以前是「读全表 → 追加 → 整表重写」：
/// 每写一条日志都要把整个文件读进内存再重写一遍，写到一半被杀就把**历史一起**毁掉。
/// 现在只往尾部 append 一行，代价与文件大小无关。
///
/// 读的一侧（[readAll]）容忍尾行损坏：append 到一半被杀最多丢最后那一条，
/// 不能因为一行坏了就把整份证据丢掉。
///
/// 超过 [maxEntries] 条就轮转（重写成最后一段 + 继续 append）。500 条是权衡：
/// 一条日志 ~200 字节，500 条 ≈ 100KB —— 足够回答「最近几次安装为什么失败」，
/// 又不会无限长。
class InstallLog {
  InstallLog(this.path, {this.maxEntries = 500});

  final String path;
  final int maxEntries;

  /// 轮转判据用的每条日志粗估字节数（200 字节上下，给足余量）：
  /// 文件没超过这个估算就不读文件，避免每次写都整份读一遍。
  static const _estimatedBytesPerEntry = 512;

  Future<void> write(Map<String, Object?> entry) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      '${jsonEncode({
        ...entry,
        'at': DateTime.now().toUtc().toIso8601String(),
      })}\n',
      mode: FileMode.append,
      flush: true,
    );
    await _rotateIfNeeded(file);
  }

  /// 读全部条目（**只有排查问题时才调**；写入路径不再读它）。
  Future<List<Map<String, Object?>>> readAll() async {
    final file = File(path);
    if (!file.existsSync()) return [];
    final out = <Map<String, Object?>>[];
    List<String> lines;
    try {
      lines = await file.readAsLines();
    } catch (_) {
      return out;
    }
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map) {
          out.add(Map<String, Object?>.from(decoded));
        } else if (decoded is List) {
          // 旧格式：整份日志是一个 JSON 数组（单行写出）。兼容读一次。
          out.addAll(
            decoded.whereType<Map>().map(Map<String, Object?>.from),
          );
        }
      } catch (_) {
        // 尾行损坏（append 到一半被杀）或不是日志的行：跳过这一行，别丢整份。
      }
    }
    return out;
  }

  /// 整份删掉。目前没有调用方，保留给「清空安装日志」这类运维/排查入口。
  Future<void> clear() async {
    final file = File(path);
    if (file.existsSync()) await file.delete();
  }

  /// 只保留最近 [maxEntries] 条：超过估算阈值时才读文件，读完仍超量才重写。
  /// 重写走「临时文件 + 同目录改名」，中途被杀也是完整旧日志或完整新日志。
  Future<void> _rotateIfNeeded(File file) async {
    try {
      if (await file.length() <= maxEntries * _estimatedBytesPerEntry) return;
      final lines = (await file.readAsLines())
          .where((l) => l.trim().isNotEmpty)
          .toList();
      if (lines.length <= maxEntries) return;
      final kept = lines.sublist(lines.length - maxEntries);
      final tmp = File(p.join(
        p.dirname(path),
        '.${p.basename(path)}.rotate.tmp',
      ));
      await tmp.writeAsString('${kept.join('\n')}\n', flush: true);
      await tmp.rename(path);
    } catch (_) {
      // 轮转失败不影响日志本身（顶多多留几条）。
    }
  }
}
