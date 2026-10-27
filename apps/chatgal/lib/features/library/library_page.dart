import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:gal_protocol/gal_protocol.dart';
import 'package:gal_storage/gal_storage.dart';

import '../../app/app_services.dart';
import '../../design_system/shell.dart';
import '../../design_system/tokens.dart';

/// Merged package + save manager.
/// Top: installed packages (default first). Saves nested under each package.
/// Bottom: saves whose package is missing.
class LibraryPage extends StatefulWidget {
  const LibraryPage({
    super.key,
    required this.theme,
    required this.services,
  });

  final ChatGalTheme theme;
  final AppServices services;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  List<PackageRef> _packages = [];
  List<SaveSlot> _saves = [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    // 多处 await 之后会回调到这里：页面已经 pop 掉时不能 setState。
    if (!mounted) return;
    setState(() {
      _packages = widget.services.listPackagesForHome();
      _saves = widget.services.saves.listSaves();
    });
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Single entry: `.chatgal` → package; `.json` / `.chatgalsave` → save.
  Future<void> _importContent() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['chatgal', 'json', 'chatgalsave', 'zip'],
      );
      if (files.isEmpty) return;
      final f = files.first;
      final path = f.path;
      if (path == null) {
        _toast('无法读取所选文件路径');
        return;
      }
      final lower = path.toLowerCase();
      if (lower.endsWith('.json') || lower.endsWith('.chatgalsave')) {
        await _importSaveFromPath(path);
      } else {
        await _importPackageFromPath(path);
      }
    } catch (e) {
      _toast('导入失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importPackageFromPath(String path) async {
    final r = await widget.services.installer.installFromPath(path);
    if (!mounted) return;
    if (r.ok) {
      _toast('已安装 ${r.packageRef!.displayName ?? r.packageRef!.packageId}');
      _reload();
    } else {
      _toast('安装失败：${r.error}');
    }
  }

  Future<void> _importSaveFromPath(String path) async {
    final raw = await File(path).readAsString();
    final slot = await widget.services.saves.importFromJson(raw);
    if (slot == null) {
      _toast('导入失败：文件格式错误');
      return;
    }
    _reload();
    _toast('已导入「${slot.label}」');
  }

  Future<void> _exportPackage(PackageRef ref) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final installDir = widget.services.packages.installDirOf(ref);
      final r = await widget.services.installer.exportInstalled(installDir);
      if (!r.ok) {
        _toast('导出失败：${r.error}');
        return;
      }
      final bytes = await File(r.file!).readAsBytes();
      final safeName =
          '${widget.services.packageDisplayName(ref)}_${ref.version}'
              .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final saved = await FilePicker.saveFile(
        dialogTitle: '导出内容包',
        fileName: '$safeName.chatgal',
        bytes: bytes,
        type: FileType.custom,
        allowedExtensions: ['chatgal'],
        mimeType: 'application/zip',
      );
      _toast(saved == null ? '已取消导出' : '已导出\n${saved.toFilePath()}');
    } catch (e) {
      _toast('导出失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deletePackage(PackageRef ref) async {
    if (AppServices.builtInPackageIds.contains(ref.packageId)) {
      _toast('内置包不可删除');
      return;
    }
    final count = _saves
        .where((s) => s.packageRef.packageId == ref.packageId)
        .length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除内容包'),
        content: Text(
          '将删除「${widget.services.packageDisplayName(ref)}」。\n'
          '其下 $count 个存档将移入「缺失包」区域（不会删除）。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.services.packages.uninstall(ref);
    if (!mounted) return;
    _toast('已删除');
    _reload();
  }

  /// 能不能改名 / 复制这份存档。
  ///
  /// 打不开的档（旧版本 / 损坏）**不能**：写入会把未知分区的内容按新形状重写掉，
  /// 等于毁档（仓库那侧也拦了一道，这里只是把原因说给玩家听）。
  bool _canRewrite(SaveSlot s) {
    if (!s.isUnreadable && s.saveSchemaVersion == SaveSlot.currentSchemaVersion) {
      return true;
    }
    _toast('这份存档打不开（旧版本或已损坏），不能改名 / 复制');
    return false;
  }

  Future<void> _exportSave(SaveSlot s) async {
    if (s.isUnreadable) {
      _toast('这份存档打不开（旧版本或已损坏），没有可导出的内容');
      return;
    }
    try {
      final payload = {
        'exportType': 'chatgalsave',
        'slot': s.toJson(),
      };
      final bytes = utf8.encode(
        const JsonEncoder.withIndent('  ').convert(payload),
      );
      final safe = s.label.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final saved = await FilePicker.saveFile(
        dialogTitle: '导出存档',
        fileName: '$safe.chatgalsave.json',
        bytes: Uint8List.fromList(bytes),
        type: FileType.custom,
        allowedExtensions: ['json', 'chatgalsave'],
      );
      _toast(saved == null ? '已取消' : '已导出\n${saved.toFilePath()}');
    } catch (e) {
      _toast('导出失败：$e');
    }
  }

  Future<void> _renameSave(SaveSlot s) async {
    if (!_canRewrite(s)) return;
    // controller 交给弹窗自持：showDialog 的 future 在 pop 那一刻就完成，
    // 这时弹窗还在退场动画里，外面 dispose 会撞上「used after being disposed」。
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _NameSaveDialog(
        title: '重命名存档',
        label: '名称',
        initial: s.label,
        confirmText: '确定',
      ),
    );
    if (name == null || name.isEmpty) return;
    await widget.services.saves.rename(s.saveId, name);
    _reload();
  }

  Future<void> _copySave(SaveSlot s) async {
    if (!_canRewrite(s)) return;
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _NameSaveDialog(
        title: '复制存档',
        label: '新存档名称',
        initial: '${s.label} 副本',
        confirmText: '确定',
      ),
    );
    if (name == null || name.isEmpty) return;
    await widget.services.saves.copy(s.saveId, name);
    _reload();
  }

  Future<void> _deleteSave(SaveSlot s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除存档'),
        content: Text('确认删除「${s.label}」？不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.services.saves.delete(s.saveId);
    _reload();
  }

  List<SaveSlot> _savesFor(String packageId) =>
      _saves.where((s) => s.packageRef.packageId == packageId).toList();

  /// 包卡片标题下面的一行信息 + 简介。读包有文件 IO，按 (id, 版本) 缓存一次。
  final Map<String, ({String summary, String intro})> _infoCache = {};

  ({String summary, String intro}) _packageInfo(PackageRef ref) {
    final key = '${ref.packageId}@${ref.version}';
    final cached = _infoCache[key];
    if (cached != null) return cached;

    final session = widget.services.loadPlaySession(ref);
    ({String summary, String intro}) info;
    if (session == null) {
      info = (summary: '内容读不出来（v${ref.version}）', intro: '');
    } else {
      final c = session.content;
      final names = c.characters.map((e) => e.id).toList();
      info = (
        summary: [
          'v${ref.version}',
          '${c.scenes.length} 幕',
          '${c.eventDefs.length} 事件',
          if (names.isEmpty) '无角色' else '${names.length} 角色（${names.join('、')}）',
          // 变量规模：作者一眼看出这包改了多少数值
          if (c.variables.isNotEmpty) '${c.variables.length} 个变量',
        ].join(' · '),
        intro: c.manifest.description.trim(),
      );
    }
    _infoCache[key] = info;
    return info;
  }

  List<SaveSlot> get _orphanSaves {
    final ids = _packages.map((p) => p.packageId).toSet();
    return _saves.where((s) => !ids.contains(s.packageRef.packageId)).toList();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    return ChatGalShell(
      theme: t,
      title: '内容包与存档',
      actions: [
        TextButton.icon(
          onPressed: _busy ? null : _importContent,
          icon: Icon(Icons.file_open, size: 18, color: t.accent),
          label: Text(
            '导入内容包或存档',
            style: TextStyle(
              color: t.accent,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
      body: ListView(
        padding: const EdgeInsets.all(Spacing.md),
        children: [
          if (_packages.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(Spacing.md),
                child: Text('尚无内容包', style: TextStyle(color: t.sub)),
              ),
            ),
          ..._packages.map((ref) {
            // 内置包外观与普通包一致；删除键也一直显示，点了提示「内置包不可删除」。
            final saves = _savesFor(ref.packageId);
            final info = _packageInfo(ref);
            return Container(
              margin: const EdgeInsets.only(bottom: Spacing.md),
              padding: const EdgeInsets.all(Spacing.sm),
              decoration: BoxDecoration(
                color: t.card,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: t.sub.withValues(alpha: 0.15),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
                    child: Row(
                      children: [
                        Icon(
                          Icons.inventory_2,
                          size: 18,
                          color: t.sub,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.services.packageDisplayName(ref),
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: t.ink,
                                ),
                              ),
                              const SizedBox(height: 2),
                              // 包信息：版本 / 规模 / 角色 / 状态
                              Text(
                                info.summary,
                                style: TextStyle(fontSize: 11, color: t.sub),
                              ),
                            ],
                          ),
                        ),
                        TextButton(
                          onPressed: () => _exportPackage(ref),
                          child: Text(
                            '导出内容包',
                            style: TextStyle(
                              color: t.accent,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '删除',
                          icon: Icon(Icons.delete_outline,
                              size: 18, color: t.sub),
                          onPressed: () => _deletePackage(ref),
                        ),
                      ],
                    ),
                  ),
                  if (info.intro.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(34, 0, 12, 8),
                      child: Text(
                        info.intro,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: t.sub,
                          height: 1.4,
                        ),
                      ),
                    ),
                  if (saves.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                      child: Text(
                        '暂无存档',
                        style: TextStyle(fontSize: 12, color: t.sub),
                      ),
                    )
                  else
                    ...saves.map((s) => _saveTile(t, s)),
                ],
              ),
            );
          }),
          // Missing package section
          Container(
            margin: const EdgeInsets.only(bottom: Spacing.md),
            padding: const EdgeInsets.all(Spacing.sm),
            decoration: BoxDecoration(
              color: t.card,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: Colors.orange.withValues(alpha: 0.45),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 4, 8),
                  child: Row(
                    children: [
                      Icon(Icons.link_off, size: 18, color: Colors.orange),
                      const SizedBox(width: 8),
                      Text(
                        '缺失包的存档',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: t.ink,
                        ),
                      ),
                    ],
                  ),
                ),
                if (_orphanSaves.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    child: Text(
                      '没有孤立存档',
                      style: TextStyle(fontSize: 12, color: t.sub),
                    ),
                  )
                else
                  ..._orphanSaves.map((s) => _saveTile(t, s, orphan: true)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _saveTile(ChatGalTheme t, SaveSlot s, {bool orphan = false}) {
    final missing = s.packageRef.displayName ?? s.packageRef.packageId;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 4, 6),
      decoration: BoxDecoration(
        color: orphan
            ? Colors.orange.withValues(alpha: 0.08)
            : t.bg,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  s.label,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: t.ink,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  s.isUnreadable
                      ? '打不开：旧版本或已损坏（${s.saveId}）'
                      : orphan
                          ? '缺失包：$missing · ${s.storyId}'
                          : '${s.storyId} · ${s.updatedAt.toLocal()}',
                  style: TextStyle(fontSize: 11, color: t.sub),
                ),
              ],
            ),
          ),
          PopupMenuButton<String>(
            tooltip: '更多操作',
            icon: Icon(Icons.more_vert, size: 20, color: t.sub),
            onSelected: (action) {
              switch (action) {
                case 'rename':
                  _renameSave(s);
                case 'copy':
                  _copySave(s);
                case 'export':
                  _exportSave(s);
                case 'delete':
                  _deleteSave(s);
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'rename',
                child: Text('改名', style: TextStyle(color: t.ink)),
              ),
              PopupMenuItem(
                value: 'copy',
                child: Text('复制', style: TextStyle(color: t.ink)),
              ),
              PopupMenuItem(
                value: 'export',
                child: Text('导出', style: TextStyle(color: t.ink)),
              ),
              PopupMenuItem(
                value: 'delete',
                child: Text('删除', style: TextStyle(color: t.ink)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 存档命名/改名用的输入弹窗。
///
/// controller 必须由弹窗自己持有：`showDialog` 的 future 在 pop 那一刻就完成，
/// 这时弹窗还在退场动画里，调用方紧接着 dispose 会撞上
/// 「A TextEditingController was used after being disposed」。
class _NameSaveDialog extends StatefulWidget {
  const _NameSaveDialog({
    required this.title,
    required this.label,
    required this.initial,
    required this.confirmText,
  });

  final String title;
  final String label;
  final String initial;
  final String confirmText;

  @override
  State<_NameSaveDialog> createState() => _NameSaveDialogState();
}

class _NameSaveDialogState extends State<_NameSaveDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _name,
        autofocus: true,
        decoration: InputDecoration(labelText: widget.label),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _name.text.trim()),
          child: Text(widget.confirmText),
        ),
      ],
    );
  }
}
