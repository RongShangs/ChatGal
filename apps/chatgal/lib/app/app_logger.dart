import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// 一条日志。
enum LogLevel {
  debug('调试', 'D'),
  info('信息', 'I'),
  warn('警告', 'W'),
  error('错误', 'E');

  const LogLevel(this.label, this.short);

  final String label;
  final String short;

  static LogLevel? byShort(String s) {
    for (final l in LogLevel.values) {
      if (l.short == s) return l;
    }
    return null;
  }
}

class LogEntry {
  LogEntry({
    required this.time,
    required this.level,
    required this.tag,
    required this.message,
    this.raw,
  });

  final DateTime time;
  final LogLevel level;
  final String tag;
  final String message;

  /// 从磁盘恢复的条目带上原始行：再次导出时逐字照原样，不做二次格式化。
  final String? raw;

  String get line => raw ?? _format();

  String _format() {
    return '${time.year}-${_two(time.month)}-${_two(time.day)} '
        '${_two(time.hour)}:${_two(time.minute)}:${_two(time.second)}.'
        '${time.millisecond.toString().padLeft(3, '0')} '
        '[${level.short}] $tag: $message';
  }

  // 与 _format() 严格对应的反向解析（日志文件是我们自己写的，格式固定）。
  static final RegExp _linePattern = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})\.(\d{3}) '
    r'\[([DIWE])\] ([^:]*): (.*)$',
    dotAll: true,
  );

  /// 解析一行；不是本程序写的行返回 null（导入的杂文件不会污染日志页）。
  static LogEntry? parse(String rawLine) {
    final line = rawLine.trimRight();
    if (line.isEmpty) return null;
    final m = _linePattern.firstMatch(line);
    if (m == null) return null;
    final level = LogLevel.byShort(m.group(8)!);
    if (level == null) return null;
    try {
      final time = DateTime(
        int.parse(m.group(1)!),
        int.parse(m.group(2)!),
        int.parse(m.group(3)!),
        int.parse(m.group(4)!),
        int.parse(m.group(5)!),
        int.parse(m.group(6)!),
        int.parse(m.group(7)!),
      );
      return LogEntry(
        time: time,
        level: level,
        tag: m.group(9)!,
        message: m.group(10)!,
        raw: line,
      );
    } catch (_) {
      return null;
    }
  }

  static String _two(int v) => v.toString().padLeft(2, '0');
}

/// 应用运行日志：**内存 + 磁盘各留最近 N 条**（默认 1000，可设置）。
///
/// 设计要点（都是被真实问题逼出来的）：
/// * **落盘**：每条都追加写 `<app data>/logs/chatgal.log`，进程被杀也还在；
/// * **跨启动可见**：启动时把盘上尾部 N 条读回内存，日志页看到的是「上一轮
///   加上这一轮」的连续记录，而不是一重启就空白（用户反馈「日志怎么会是保存
///   在内存里面的」）；
/// * **上限**：内存与文件都按同一个上限裁剪，超过就把文件重写成最后 N 行，
///   不会无限长大；上限在日志页可调，改完立刻生效；
/// * 写盘走串行队列、吞掉 IO 异常 —— 日志本身永远不能把游戏搞崩。
class AppLogger {
  AppLogger({this.maxEntries = defaultMaxEntries, DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  static const int defaultMaxEntries = 1000;
  static const int minMaxEntries = 100;
  static const int maxMaxEntries = 20000;

  static AppLogger instance = AppLogger();

  /// 保留条数上限（内存与磁盘共用）。改它请用 [setLimit]，那样才会顺带裁剪。
  int maxEntries;

  final DateTime Function() _clock;

  final List<LogEntry> _entries = [];

  /// 读取方（日志页）监听它来刷新，避免每帧轮询。
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  File? _file;
  Future<void> _writeQueue = Future<void>.value();
  int _fileLineCount = 0;

  /// 文件被整份重写的次数（测试与自查用）。
  int fileRewriteCount = 0;

  /// 关掉之后 `log()` 直接返回（写盘也跟着停）。
  bool enabled = true;

  /// 日志文件的落点（没绑定目录时为 null）。
  String? get filePath => _file?.path;

  /// 当前盘上文件的条目数（供日志页显示）。
  int get fileLineCount => _fileLineCount;

  /// 文件涨到多少行才做一次裁剪。
  ///
  /// 以前是「每多一条就整份重写一遍」：稳定运行阶段每次记录都变成
  /// 读全文 + 写全文（上限 20000 时更吓人）。现在留一段缓冲，攒够了一批再裁，
  /// 平均下来几百次追加才重写一次，仍然不会无限增长。
  int get fileTrimThreshold => maxEntries + math.max(50, maxEntries ~/ 4);

  List<LogEntry> get entries => List.unmodifiable(_entries);

  /// 绑定到应用数据目录（`<root>/logs/chatgal.log`），并把盘上的最近 N 条
  /// 读回内存 —— 这一步就是「日志是真的记下来了」的兑现处。
  void attach(String rootDir, {int? maxEntries}) {
    if (maxEntries != null) this.maxEntries = clampLimit(maxEntries);
    _file = File(p.join(rootDir, 'logs', 'chatgal.log'));
    try {
      _file!.parent.createSync(recursive: true);
    } catch (_) {
      _file = null;
      return;
    }
    _restoreFromFile();
  }

  void _restoreFromFile() {
    final file = _file;
    if (file == null || !file.existsSync()) return;
    List<String> lines;
    try {
      lines = file.readAsLinesSync();
    } catch (_) {
      return;
    }
    _fileLineCount = lines.length;
    if (lines.length > maxEntries) {
      lines = lines.sublist(lines.length - maxEntries);
      _scheduleTrim();
    }
    final restored = <LogEntry>[];
    for (final line in lines) {
      final e = LogEntry.parse(line);
      if (e != null) restored.add(e);
    }
    if (restored.isEmpty) return;
    _entries
      ..clear()
      ..addAll(restored);
    revision.value++;
  }

  /// 调整保留上限并立即生效（裁剪内存、重写文件）。
  void setLimit(int next) {
    final v = clampLimit(next);
    if (v == maxEntries) return;
    maxEntries = v;
    _trimMemory();
    revision.value++;
    _scheduleTrim();
  }

  /// 把外部传来的上限夹到合法区间（设置里读回来的值也走它）。
  static int clampLimit(int v) =>
      v.clamp(minMaxEntries, maxMaxEntries).toInt();

  List<LogEntry> snapshot({
    LogLevel? minLevel,
    String? tagQuery,
    String? textQuery,
  }) {
    final min = minLevel ?? LogLevel.debug;
    final tag = (tagQuery ?? '').trim().toLowerCase();
    final text = (textQuery ?? '').trim().toLowerCase();
    return [
      for (final e in _entries)
        if (e.level.index >= min.index)
          if (tag.isEmpty || e.tag.toLowerCase().contains(tag))
            if (text.isEmpty ||
                e.message.toLowerCase().contains(text) ||
                e.tag.toLowerCase().contains(text))
              e,
    ];
  }

  void log(
    LogLevel level,
    String tag,
    String message, {
    Object? error,
    StackTrace? stack,
  }) {
    if (!enabled) return;
    var text = message;
    if (error != null) text = '$text | $error';
    if (stack != null) {
      // 只留前几行，整段堆栈进日志文件意义不大。
      final frames = stack.toString().split('\n').take(4).join(' <- ');
      text = '$text | $frames';
    }
    // 一条日志必须落成一行：换行会被行数裁剪与恢复解析当成两条。
    text = text.replaceAll(RegExp(r'\s*\r?\n\s*'), ' ');
    final entry = LogEntry(
      time: _clock(),
      level: level,
      tag: tag,
      message: text,
    );
    _entries.add(entry);
    _trimMemory();
    revision.value++;
    _append(entry);
  }

  void _trimMemory() {
    if (_entries.length <= maxEntries) return;
    _entries.removeRange(0, _entries.length - maxEntries);
  }

  void d(String tag, String message) => log(LogLevel.debug, tag, message);
  void i(String tag, String message) => log(LogLevel.info, tag, message);
  void w(String tag, String message) => log(LogLevel.warn, tag, message);
  void e(String tag, String message, [Object? error, StackTrace? stack]) =>
      log(LogLevel.error, tag, message, error: error, stack: stack);

  void _append(LogEntry entry) {
    final file = _file;
    if (file == null) return;
    // 串行追加：并发写同一文件会互相截断。
    _writeQueue = _writeQueue.then((_) async {
      try {
        await file.writeAsString('${entry.line}\n',
            mode: FileMode.append, flush: true);
        _fileLineCount++;
        // 攒够一批再裁：不是每多一条就整份重写。
        if (_fileLineCount > fileTrimThreshold) await _trimFile();
      } catch (_) {
        // 写不进去就算了：不能让日志拖垮游戏。
      }
    });
  }

  /// 把文件裁到最后 maxEntries 行（超限才做，代价是整份重写）。
  void _scheduleTrim() {
    final file = _file;
    if (file == null) return;
    _writeQueue = _writeQueue.then((_) async {
      try {
        if (!file.existsSync()) return;
        final lines = await file.readAsLines();
        if (lines.length <= maxEntries) {
          _fileLineCount = lines.length;
          return;
        }
        await _writeLines(file, lines.sublist(lines.length - maxEntries));
      } catch (_) {}
    });
  }

  Future<void> _trimFile() async {
    final file = _file;
    if (file == null || !file.existsSync()) return;
    final lines = await file.readAsLines();
    if (lines.length <= maxEntries) {
      _fileLineCount = lines.length;
      return;
    }
    await _writeLines(file, lines.sublist(lines.length - maxEntries));
  }

  /// 一次性重写（先写临时文件再改名，避免裁剪中途被杀留下半个文件）。
  Future<void> _writeLines(File file, List<String> lines) async {
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      lines.isEmpty ? '' : '${lines.join('\n')}\n',
      flush: true,
    );
    await tmp.rename(file.path);
    _fileLineCount = lines.length;
    fileRewriteCount++;
  }

  /// 等写盘队列排空（退出前 / 测试用）。
  Future<void> flush() => _writeQueue;

  void clear() {
    _entries.clear();
    revision.value++;
    final file = _file;
    if (file != null) {
      _writeQueue = _writeQueue.then((_) async {
        try {
          if (file.existsSync()) await file.writeAsString('', flush: true);
          _fileLineCount = 0;
        } catch (_) {}
      });
    }
  }

  /// 只读盘上那一整份日志（日志页的「磁盘」视图）。
  String readFileText() {
    final file = _file;
    if (file == null || !file.existsSync()) return '';
    try {
      return file.readAsStringSync();
    } catch (_) {
      return '';
    }
  }
}

/// 全局快捷日志（省得每处都写 `AppLogger.instance`）。
AppLogger get appLog => AppLogger.instance;
