import 'dart:io';

import 'package:chatgal/app/app_logger.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('chatgal_log_');
  });

  tearDown(() {
    // Windows 上文件句柄可能还没释放（写盘是异步的），删不掉就留给系统清临时目录。
    try {
      if (root.existsSync()) root.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('内存环形缓冲只保留最近 maxEntries 条', () {
    final logger = AppLogger(maxEntries: 3);
    for (var i = 0; i < 6; i++) {
      logger.i('t', '第 $i 条');
    }
    expect(logger.entries, hasLength(3));
    expect(logger.entries.first.message, '第 3 条');
    expect(logger.entries.last.message, '第 5 条');
  });

  test('revision 每次写入都变（日志页据此刷新）', () {
    final logger = AppLogger();
    final before = logger.revision.value;
    logger.d('t', 'x');
    logger.w('t', 'y');
    expect(logger.revision.value, before + 2);
  });

  test('snapshot 按级别 / 标签 / 文本过滤，且按级别取「不低于」', () {
    final logger = AppLogger();
    logger.d('tts', '合成一句话');
    logger.i('provider', '切换供应商');
    logger.w('tts', '语音超时');
    logger.e('install', '安装失败', 'boom');

    expect(logger.snapshot(), hasLength(4));
    expect(logger.snapshot(minLevel: LogLevel.warn), hasLength(2));
    expect(logger.snapshot(tagQuery: 'tts'), hasLength(2));
    expect(logger.snapshot(textQuery: '安装'), hasLength(1));
    expect(logger.snapshot(minLevel: LogLevel.info, tagQuery: 'tts'),
        hasLength(1));
  });

  test('错误条目会带上 error 与堆栈前几行', () {
    final logger = AppLogger();
    try {
      throw StateError('炸了');
    } catch (e, st) {
      logger.e('t', '捕获', e, st);
    }
    final line = logger.entries.single.message;
    expect(line, contains('捕获'));
    expect(line, contains('炸了'));
  });

  test('enabled=false 时不再记录', () {
    final logger = AppLogger()..enabled = false;
    logger.i('t', '不该出现');
    expect(logger.entries, isEmpty);
  });

  test('line 格式包含年份-毫秒的时间、级别、标签与内容', () {
    final logger = AppLogger(clock: () => DateTime(2026, 9, 14, 8, 5, 3, 7));
    logger.i('splash', '用户已同意用户须知');
    expect(
      logger.entries.single.line,
      '2026-09-14 08:05:03.007 [I] splash: 用户已同意用户须知',
    );
  });

  test('attach 后追加写盘，flush 能等到落盘', () async {
    final logger = AppLogger();
    logger.attach(root.path);
    expect(logger.filePath, isNotNull);
    logger.i('t', '第一行');
    logger.i('t', '第二行');
    await logger.flush();
    final content = File(logger.filePath!).readAsStringSync();
    expect(content, contains('第一行'));
    expect(content, contains('第二行'));
    expect(content.trim().split('\n'), hasLength(2));
  });

  test('文件不会无限长大：涨到批量窗口就裁回上限', () async {
    final logger = AppLogger(maxEntries: 200);
    logger.attach(root.path);
    for (var i = 0; i < 260; i++) {
      logger.i('t', '第 $i 行');
    }
    await logger.flush();
    final lines = File(logger.filePath!).readAsLinesSync();
    expect(lines.length, lessThanOrEqualTo(logger.fileTrimThreshold));
    // 裁掉的是最旧的，最新的那条一定还在。
    expect(lines.last, contains('第 259 行'));
    expect(lines.first, isNot(contains('第 0 行')));
  });

  test('裁剪是批量的：260 条追加只重写文件一两次，不是每多一条就重写', () async {
    final logger = AppLogger(maxEntries: 200);
    logger.attach(root.path);
    expect(logger.fileRewriteCount, 0);
    for (var i = 0; i < 260; i++) {
      logger.i('t', '第 $i 行');
    }
    await logger.flush();
    // 窗口 = 200 + max(50, 50) = 250：第 251 条时裁一次，之后不再触发。
    expect(logger.fileRewriteCount, lessThanOrEqualTo(2));
    expect(logger.fileTrimThreshold, 250);
  });

  test('把上限改小会立刻裁到新上限（不是等下一批）', () async {
    final logger = AppLogger(maxEntries: 500);
    logger.attach(root.path);
    for (var i = 0; i < 400; i++) {
      logger.i('t', '第 $i 行');
    }
    await logger.flush();
    expect(File(logger.filePath!).readAsLinesSync().length, 400);
    logger.setLimit(200);
    await logger.flush();
    expect(logger.maxEntries, 200);
    expect(File(logger.filePath!).readAsLinesSync().length,
        lessThanOrEqualTo(200));
  });

  test('重启后从盘上恢复最近 N 条（日志不是只存在内存里）', () async {
    final first = AppLogger(maxEntries: 500);
    first.attach(root.path);
    first.i('app', '上一轮启动');
    first.i('chat', '上一轮说了句话');
    await first.flush();

    // 模拟重启：新建一个 logger，attach 同一个目录。
    final second = AppLogger(maxEntries: 500);
    second.attach(root.path);
    expect(second.entries, hasLength(2));
    expect(second.entries.first.message, '上一轮启动');
    expect(second.entries.last.tag, 'chat');
    expect(second.entries.last.level, LogLevel.info);
    // 恢复出来的条目时间来自行本身，不是「现在」。
    expect(second.entries.last.line, contains('['));
  });

  test('恢复时忽略不是本程序写的行', () async {
    final file = File('${root.path}/logs/chatgal.log');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('这不是日志\n2026-09-14 08:05:03.007 [I] t: 这是日志\n');
    final logger = AppLogger(maxEntries: 500);
    logger.attach(root.path);
    expect(logger.entries, hasLength(1));
    expect(logger.entries.single.message, '这是日志');
  });

  test('setLimit 立刻裁内存并可再存回设置', () async {
    final logger = AppLogger(maxEntries: 500);
    logger.attach(root.path);
    for (var i = 0; i < 400; i++) {
      logger.i('t', '第 $i 条');
    }
    logger.setLimit(200);
    expect(logger.maxEntries, 200);
    expect(logger.entries, hasLength(200));
    expect(logger.entries.last.message, '第 399 条');
    await logger.flush();
    expect(File(logger.filePath!).readAsLinesSync().length,
        lessThanOrEqualTo(200));
  });

  test('上限被夹到合法区间', () {
    expect(AppLogger.clampLimit(10), AppLogger.minMaxEntries);
    expect(AppLogger.clampLimit(999999), AppLogger.maxMaxEntries);
    final logger = AppLogger()..setLimit(5);
    expect(logger.maxEntries, AppLogger.minMaxEntries);
  });

  test('clear 清内存也清文件', () async {
    final logger = AppLogger();
    logger.attach(root.path);
    logger.i('t', '要清掉的');
    await logger.flush();
    logger.clear();
    await logger.flush();
    expect(logger.entries, isEmpty);
    expect(File(logger.filePath!).readAsStringSync(), isEmpty);
  });

  test('没 attach 时也能用（测试/无数据目录场景）', () {
    final logger = AppLogger();
    logger.i('t', '没有落点');
    expect(logger.entries, hasLength(1));
    expect(logger.filePath, isNull);
    expect(logger.readFileText(), isEmpty);
  });
}
