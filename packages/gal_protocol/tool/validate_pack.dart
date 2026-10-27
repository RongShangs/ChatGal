// 结构体检入口：把一个内容包目录喂给 PackageLoader + PackageValidator，
// 有问题打印出来并以退出码 1 结束。
//
// 为什么放在这里：校验逻辑**只有一份**（Dart 的 PackageValidator），
// 游戏内安装第三方包与仓库打包前检查用的是同一套，不会再出现
// 「python 脚本与 Dart 校验器各写一套、慢慢漂移」。
//
// 用法：
//   dart run packages/gal_protocol/tool/validate_pack.dart <包目录>
import 'dart:io';

import 'package:gal_protocol/gal_protocol.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('用法: dart run validate_pack.dart <包目录>');
    exit(2);
  }
  final root = Directory(args.first);
  if (!root.existsSync()) {
    stderr.writeln('目录不存在: ${root.path}');
    exit(2);
  }

  // 先 resolve 再列目录：`Directory.absolute` 不展开 ".."，那样算出来的前缀
  // 与列出来的子路径对不上，substring 会越界。
  final resolved = Directory(root.resolveSymbolicLinksSync());
  final base = resolved.path.replaceAll('\\', '/');
  final files = <String, String>{};
  for (final f in resolved.listSync(recursive: true)) {
    if (f is! File) continue;
    final rel = f.path.replaceAll('\\', '/').substring(base.length + 1);
    if (rel.split('/').any((p) => p.startsWith('.'))) continue;
    // 只有这些后缀按文本读，其余（png/jpg/webp/ttf/mp3…）一律记空串。
    // 以前只把 png/jpg/webp 当二进制，作者包里一有 .jpeg/.ttf/.mp3 就会在这里
    // readAsStringSync 抛 FormatException，打出一坨 Dart 栈、退出码非 0，
    // 上层还翻译成「结构体检不过」——报的却与结构无关。
    files[rel] = _isTextFile(rel) ? f.readAsStringSync() : '';
  }

  PackageContent content;
  try {
    content = PackageLoader.fromFiles(files);
  } catch (e) {
    stderr.writeln('FATAL 加载失败: $e');
    exit(1);
  }

  final report = const PackageValidator().validate(content);
  if (!report.isValid) {
    stderr.writeln('FATAL 结构体检不过（${report.errors.length} 项）：');
    for (final e in report.errors) {
      stderr.writeln('  - $e');
    }
    exit(1);
  }
  for (final w in report.warnings) {
    stdout.writeln('WARN $w');
  }
  stdout.writeln(
    'OK ${content.manifest.packageId} v${content.manifest.version} '
    'scenes=${content.scenes.length} events=${content.eventDefs.length} '
    'characters=${content.characters.length} entries=${files.length}',
  );
}

/// 按后缀判断是不是该当文本读的文件。
/// 与安装器 `_readTree` 的口径保持一致（那边也是 json/md/txt/csv 才算文本）。
bool _isTextFile(String rel) {
  final dot = rel.lastIndexOf('.');
  if (dot < 0) return false;
  return const {'.json', '.md', '.txt', '.csv'}.contains(
    rel.substring(dot).toLowerCase(),
  );
}
