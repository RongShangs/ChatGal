import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_logger.dart';
import '../../design_system/shell.dart';
import '../../design_system/tokens.dart';
import '../settings/api_settings.dart';

/// 运行日志页。
///
/// 数据源是内存里那份（[AppLogger.snapshot]）——但它**不是唯一的一份**：
/// 每条日志同时追加写到 `<数据目录>/logs/chatgal.log`，启动时再把盘上最近
/// N 条读回内存。所以这一页看到的是跨启动的连续记录，重启不会空白；
/// 「保留条数」上限在页面顶部可调，内存与文件一起按它裁剪。
class LogPage extends StatefulWidget {
  const LogPage({super.key, required this.theme, required this.api});

  final ChatGalTheme theme;
  final ApiSettingsStore api;

  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  final _logger = AppLogger.instance;
  final _search = TextEditingController();
  final _scroll = ScrollController();
  LogLevel? _minLevel;
  bool _showFile = false;

  static const List<int> _limitChoices = [200, 500, 1000, 2000, 5000];

  @override
  void initState() {
    super.initState();
    _logger.revision.addListener(_onChanged);
  }

  @override
  void dispose() {
    _logger.revision.removeListener(_onChanged);
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// 改上限：立刻裁内存与文件，同时存进设置，下次启动照此恢复。
  Future<void> _setLimit(int value) async {
    _logger.setLimit(value);
    final limit = _logger.maxEntries;
    await widget.api.update((s) => s.copyWith(logMaxEntries: limit));
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('日志最多保留 ${_logger.maxEntries} 条')));
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Color _levelColor(ChatGalTheme t, LogLevel level) => switch (level) {
    LogLevel.debug => t.sub,
    LogLevel.info => t.accent,
    LogLevel.warn => Colors.orange.shade700,
    LogLevel.error => Colors.redAccent,
  };

  Future<void> _copy(List<LogEntry> entries) async {
    final text = entries.map((e) => e.line).join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('已复制 ${entries.length} 行日志')));
  }

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: widget.theme.card,
        title: Text('清空日志？', style: TextStyle(color: widget.theme.ink)),
        content: Text(
          '内存里的日志与磁盘上那份都会清掉。清空不会影响游戏数据。',
          style: TextStyle(color: widget.theme.sub, fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消', style: TextStyle(color: widget.theme.sub)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    _logger.clear();
    appLog.i('log', '用户清空了日志');
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    final entries = _logger.snapshot(
      minLevel: _minLevel,
      textQuery: _search.text,
    );

    return ChatGalShell(
      theme: t,
      title: '运行日志',
      actions: [
        IconButton(
          tooltip: _showFile ? '看内存日志' : '看磁盘日志',
          icon: Icon(
            _showFile ? Icons.dns_outlined : Icons.sd_storage_outlined,
            size: 20,
            color: t.ink,
          ),
          onPressed: () => setState(() => _showFile = !_showFile),
        ),
        IconButton(
          tooltip: '复制当前筛选结果',
          icon: Icon(Icons.copy_all_outlined, size: 20, color: t.ink),
          onPressed: entries.isEmpty ? null : () => _copy(entries),
        ),
        IconButton(
          tooltip: '清空',
          icon: Icon(Icons.delete_sweep_outlined, size: 20, color: t.ink),
          onPressed: _confirmClear,
        ),
      ],
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Spacing.md,
              Spacing.sm,
              Spacing.md,
              0,
            ),
            child: Column(
              children: [
                TextField(
                  controller: _search,
                  style: const TextStyle(fontSize: 13),
                  decoration: const InputDecoration(
                    isDense: true,
                    prefixIcon: Icon(Icons.search, size: 18),
                    hintText: '搜索内容或标签（如 tts、provider、install）',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 8),
                // 层级：**保留条数（设置）在上，级别筛选（筛选器）在下** ——
                // 上面是「日志留多少」，下面是「现在看哪些」，别让设置项挤在筛选器后面。
                Row(
                  children: [
                    Text('保留条数', style: TextStyle(fontSize: 11, color: t.sub)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            for (final v in _limitChoices)
                              Padding(
                                padding: const EdgeInsets.only(right: 5),
                                child: ChoiceChip(
                                  label: Text(
                                    '$v',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: t.ink,
                                    ),
                                  ),
                                  selected: _logger.maxEntries == v,
                                  selectedColor: t.accent.withValues(
                                    alpha: 0.25,
                                  ),
                                  backgroundColor: t.card,
                                  side: BorderSide(
                                    color: t.sub.withValues(alpha: 0.2),
                                  ),
                                  visualDensity: VisualDensity.compact,
                                  onSelected: (_) => _setLimit(v),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _levelChip(t, null),
                      for (final l in LogLevel.values) _levelChip(t, l),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '共 ${entries.length} 条 · 内存 ${_logger.entries.length} 条 · '
                        '文件 ${_logger.fileLineCount} 条',
                        style: TextStyle(fontSize: 11, color: t.sub),
                      ),
                    ),
                    Text(
                      _logger.filePath == null ? '未接通日志文件' : '已落盘',
                      style: TextStyle(
                        fontSize: 11,
                        color: _logger.filePath == null
                            ? Colors.orange.shade700
                            : t.sub,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: _showFile
                ? _fileView(t)
                : entries.isEmpty
                ? Center(
                    child: Text(
                      _logger.entries.isEmpty ? '还没有日志。' : '当前筛选下没有日志。',
                      style: TextStyle(color: t.sub),
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(
                      Spacing.md,
                      0,
                      Spacing.md,
                      Spacing.lg,
                    ),
                    itemCount: entries.length,
                    itemBuilder: (context, i) {
                      // 最新的在最上面：出问题时第一眼要看的是刚才发生的事。
                      final e = entries[entries.length - 1 - i];
                      return _entryRow(t, e);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _levelChip(ChatGalTheme t, LogLevel? level) {
    final selected = _minLevel == level;
    final label = level == null ? '全部' : '${level.label}+';
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        label: Text(label, style: TextStyle(fontSize: 12, color: t.ink)),
        selected: selected,
        selectedColor: t.accent.withValues(alpha: 0.25),
        backgroundColor: t.card,
        side: BorderSide(color: t.sub.withValues(alpha: 0.2)),
        onSelected: (_) => setState(() => _minLevel = level),
      ),
    );
  }

  Widget _entryRow(ChatGalTheme t, LogEntry e) {
    final color = _levelColor(t, e.level);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: t.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.18)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(
                    e.level.short,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: color,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  e.tag,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: t.ink,
                  ),
                ),
                const Spacer(),
                Text(
                  '${_two(e.time.hour)}:${_two(e.time.minute)}:'
                  '${_two(e.time.second)}.${e.time.millisecond.toString().padLeft(3, '0')}',
                  style: TextStyle(fontSize: 10, color: t.sub),
                ),
              ],
            ),
            const SizedBox(height: 5),
            SelectableText(
              e.message,
              style: TextStyle(fontSize: 12, height: 1.4, color: t.ink),
            ),
          ],
        ),
      ),
    );
  }

  Widget _fileView(ChatGalTheme t) {
    final text = _logger.readFileText();
    if (text.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _logger.filePath == null
                ? '还没接通日志文件（数据目录未就绪）。'
                : '磁盘上的日志还是空的。\n\n文件位置：\n${_logger.filePath}',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, height: 1.5, color: t.sub),
          ),
        ),
      );
    }
    // 只看尾部：文件可能很长，整份塞进 SelectableText 会卡。
    final tail = text.length > 20000
        ? text.substring(text.length - 20000)
        : text;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(Spacing.md, 0, Spacing.md, Spacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 把落盘位置明说出来：用户要导日志/发文件时找得到。
          SelectableText(
            '文件：${_logger.filePath}\n'
            '共 ${_logger.fileLineCount} 条（上限 ${_logger.maxEntries}）',
            style: TextStyle(fontSize: 10.5, color: t.sub, height: 1.4),
          ),
          const SizedBox(height: 8),
          SelectableText(
            tail,
            style: TextStyle(
              fontSize: 10.5,
              height: 1.35,
              color: t.ink,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }

  static String _two(int v) => v.toString().padLeft(2, '0');
}
