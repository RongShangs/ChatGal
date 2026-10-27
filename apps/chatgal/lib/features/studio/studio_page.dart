import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:gal_protocol/gal_protocol.dart';
import 'package:gal_storage/gal_storage.dart';

import '../../app/app_services.dart';
import '../../design_system/shell.dart';
import '../../design_system/tokens.dart';
import 'hints.dart';
import 'studio_editor_page.dart';

/// 内容包创作台的**工程列表**页。
///
/// 一个「工程」= `<root>/studio/<目录名>/` 这棵包目录树，**身份是目录名**（不是
/// packageId），所以同一个包名可以有多份工程并存（复制出来做分支尝试）。
/// 本页负责工程的新建 / 导入 / 复制 / 重命名 / 导出 / 装到本地 / 体检 / 删除；
/// 改内容进 [StudioEditorPage]。
class StudioPage extends StatefulWidget {
  const StudioPage({
    super.key,
    required this.theme,
    required this.services,
  });

  final ChatGalTheme theme;
  final AppServices services;

  @override
  State<StudioPage> createState() => _StudioPageState();
}

class _StudioPageState extends State<StudioPage> {
  List<StudioProject> _projects = [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    // 多处 await 之后会回调到这里：页面已经 pop 掉时不能 setState。
    if (!mounted) return;
    setState(() => _projects = widget.services.studio.listProjects());
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 所有异步动作统一走这里：`_busy` 挡重入，结束时一定复位。
  Future<void> _run(Future<void> Function() body) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await body();
    } catch (e) {
      _toast('操作失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openEditor(String slug) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => StudioEditorPage(
          theme: widget.theme,
          services: widget.services,
          slug: slug,
        ),
      ),
    );
    _reload();
  }

  // ------------------------------------------------------------ 新建 / 导入

  /// 新建工程用的默认值：不再弹表单 —— 反正进去编辑器都要填。
  /// 建完直接进编辑器，用一句提示告诉用户先去改包名与版本号。
  static const _defaultProjectName = '我的内容包';
  static const _defaultProjectVersion = '1';

  /// `local.pack.<6 位>`：不同工程不会撞 id（真撞了也能在基础信息里改）。
  static String _defaultPackageId() =>
      'local.pack.${DateTime.now().millisecondsSinceEpoch % 1000000}';

  Future<void> _newProject() => _run(() async {
        final created = await widget.services.studio.createBlank(
          name: _defaultProjectName,
          packageId: _defaultPackageId(),
          version: _defaultProjectVersion,
        );
        if (!mounted) return;
        _reload();
        _toast('已新建「${created.slug}」：记得先在「基础信息」里改包名与版本');
        await _openEditor(created.slug);
      });

  Future<void> _importProject() => _run(() async {
        final source = await showModalBottomSheet<_ImportSource>(
          context: context,
          backgroundColor: widget.theme.card,
          builder: _importSourceSheet,
        );
        if (source == null) return;
        if (!mounted) return;
        switch (source) {
          case _ImportSource.file:
            await _importFromFile();
          case _ImportSource.installed:
            await _importFromInstalled();
        }
      });

  Future<void> _importFromFile() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['chatgal', 'zip'],
    );
    if (files.isEmpty) return;
    if (!mounted) return;
    final path = files.first.path;
    if (path == null) {
      _toast('无法读取所选文件路径');
      return;
    }
    final imported = await widget.services.studio.importFromZip(path);
    if (!mounted) return;
    _reload();
    _toast('已导入工程「${imported.slug}」');
    await _openEditor(imported.slug);
  }

  Future<void> _importFromInstalled() async {
    final installed = widget.services.packages.listInstalled();
    if (installed.isEmpty) {
      _toast('本地还没有已安装的内容包');
      return;
    }
    final ref = await showModalBottomSheet<PackageRef>(
      context: context,
      backgroundColor: widget.theme.card,
      builder: (ctx) => _installedSheet(ctx, installed),
    );
    if (ref == null) return;
    if (!mounted) return;
    final name = widget.services.packageDisplayName(ref);
    final imported = await widget.services.studio.importFromInstalled(ref);
    if (!mounted) return;
    _reload();
    _toast('已把「$name」导入成工程「${imported.slug}」');
    await _openEditor(imported.slug);
  }

  Widget _importSourceSheet(BuildContext ctx) {
    final t = widget.theme;
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 20),
        children: [
          HintLabel(theme: t, title: '导入内容包', hintKey: 'studio.import'),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.folder_open, size: 20, color: t.accent),
            title: Text(
              '从文件导入',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: t.ink,
              ),
            ),
            subtitle: Text(
              '.chatgal 或 .zip · 只读文件，不改动原文件',
              style: TextStyle(fontSize: 11, color: t.sub),
            ),
            onTap: () => Navigator.pop(ctx, _ImportSource.file),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.inventory_2, size: 20, color: t.accent),
            title: Text(
              '从已装到本地的内容包导入',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: t.ink,
              ),
            ),
            subtitle: Text(
              '复制一份成工程，已装的包原样不动',
              style: TextStyle(fontSize: 11, color: t.sub),
            ),
            onTap: () => Navigator.pop(ctx, _ImportSource.installed),
          ),
        ],
      ),
    );
  }

  Widget _installedSheet(BuildContext ctx, List<PackageRef> installed) {
    final t = widget.theme;
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 6),
            child: Text(
              '选择要导入成工程的内容包',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: t.ink,
              ),
            ),
          ),
          ...installed.map(
            (r) => ListTile(
              title: Text(
                widget.services.packageDisplayName(r),
                style: TextStyle(fontSize: 14, color: t.ink),
              ),
              subtitle: Text(
                '${r.packageId} v${r.version}',
                style: TextStyle(fontSize: 11, color: t.sub),
              ),
              onTap: () => Navigator.pop(ctx, r),
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ ⋮ 菜单动作

  Future<void> _menu(StudioProject p, String action) async {
    switch (action) {
      case 'install':
        await _installProject(p);
      case 'duplicate':
        await _duplicateProject(p);
      case 'rename':
        await _renameProject(p);
      case 'export':
        await _exportProject(p);
      case 'check':
        await _checkProject(p);
      case 'delete':
        await _deleteProject(p);
    }
  }

  /// 导入到本地包：先做**版本比对**，把结论与本地已装版本摆给用户看。
  Future<void> _installProject(StudioProject p) => _run(() async {
        // 内置包 id 不许占用：装上去之后，下次 APK 升级时它会被当成
        // 「旧版本的默认包」静默删掉，而绑在它上面的存档还会悄悄接到官方新包的内容上。
        if (AppServices.builtInPackageIds.contains(p.packageId)) {
          _toast('「${p.packageId}」是内置包 id，不能占用。请先在基础信息里换个包名。');
          return;
        }
        final plan = await widget.services.studio.installPlan(p.slug);
        if (!mounted) return;
        final next = StudioStore.nextVersion(p.version);
        final go = await showDialog<bool>(
          context: context,
          builder: (ctx) {
            final t = widget.theme;
            return AlertDialog(
              title: const Text('导入到本地包'),
              content: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    HintLabel(
                      theme: t,
                      title: '版本比对',
                      hintKey: 'project.install',
                    ),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: plan.canInstall
                            ? t.accent.withValues(alpha: 0.08)
                            : Colors.redAccent.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: plan.canInstall
                              ? t.accent.withValues(alpha: 0.25)
                              : Colors.redAccent.withValues(alpha: 0.35),
                        ),
                      ),
                      child: Text(
                        plan.message,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.55,
                          color: t.ink,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '本地已装的同包名版本',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: t.ink,
                      ),
                    ),
                    const SizedBox(height: 4),
                    if (plan.installed.isEmpty)
                      Text(
                        '（没有，这是新装）',
                        style: TextStyle(fontSize: 11.5, color: t.sub),
                      )
                    else
                      ...plan.installed.map(
                        (r) => Padding(
                          padding: const EdgeInsets.only(bottom: 3),
                          child: Text(
                            '· v${r.version} · '
                            '${r.displayName ?? r.packageId} · '
                            '内容 ${_shortHash(r.contentHash)}',
                            style: TextStyle(
                              fontSize: 11.5,
                              height: 1.5,
                              color: t.sub,
                            ),
                          ),
                        ),
                      ),
                    if (!plan.canInstall) ...[
                      const SizedBox(height: 10),
                      Text(
                        '装不进去：本地已有 v${p.version}，而这份工程的内容和它不一样'
                        '（存档绑在内容上）。到编辑器里把版本号改成 $next 就能装。',
                        style: TextStyle(
                          fontSize: 11.5,
                          height: 1.6,
                          color: Colors.redAccent,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed:
                      plan.canInstall ? () => Navigator.pop(ctx, true) : null,
                  child: Text(plan.canInstall ? '装入本地' : '不能装'),
                ),
              ],
            );
          },
        );
        if (go != true) return;
        if (!mounted) return;
        final result = await widget.services.studio.installToPackages(p.slug);
        if (!mounted) return;
        if (result.ok) {
          final ref = result.packageRef!;
          _toast(
            '已装入本地：${ref.displayName ?? ref.packageId} v${ref.version}',
          );
        } else {
          _toast('装入失败：${result.error!.message}');
        }
      });

  Future<void> _duplicateProject(StudioProject p) => _run(() async {
        final copy = await widget.services.studio.duplicate(p.slug);
        if (!mounted) return;
        _reload();
        _toast('已复制为工程「${copy.slug}」');
      });

  Future<void> _renameProject(StudioProject p) => _run(() async {
        final name = await showDialog<String>(
          context: context,
          builder: (_) => _RenameProjectDialog(
            theme: widget.theme,
            initial: p.slug,
            packageName: p.name,
          ),
        );
        if (name == null) return;
        if (!mounted) return;
        final renamed = await widget.services.studio.renameProject(p.slug, name);
        if (!mounted) return;
        _reload();
        _toast('已重命名为「${renamed.slug}」');
      });

  Future<void> _exportProject(StudioProject p) => _run(() async {
        // 有 error 就不导：避免分享出去一个装不上的包。
        final result = widget.services.studio.check(p.slug);
        if (result.loaded && result.errors.isNotEmpty) {
          _toast('体检有 ${result.errors.length} 个 error，先修好再导出');
          await _showCheck(p, result);
          return;
        }
        if (!result.loaded) {
          _toast('读不出来，无法导出');
          await _showCheck(p, result);
          return;
        }
        final exported = await widget.services.studio.exportZip(p.slug);
        if (!exported.ok) {
          _toast('导出失败：${exported.error!.message}');
          return;
        }
        final bytes = await File(exported.file!).readAsBytes();
        if (!mounted) return;
        final safe = (p.name.trim().isEmpty ? p.slug : p.name.trim())
            .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
        final saved = await FilePicker.saveFile(
          dialogTitle: '导出 .chatgal',
          fileName: '${safe}_v${p.version}.chatgal',
          bytes: bytes,
          type: FileType.custom,
          allowedExtensions: ['chatgal'],
          mimeType: 'application/zip',
        );
        _toast(saved == null ? '已取消导出' : '已导出\n${saved.toFilePath()}');
      });

  Future<void> _checkProject(StudioProject p) => _run(() async {
        final result = widget.services.studio.check(p.slug);
        if (!mounted) return;
        await _showCheck(p, result);
      });

  Future<void> _showCheck(StudioProject p, StudioCheckResult result) {
    return showDialog<void>(
      context: context,
      builder: (ctx) {
        final t = widget.theme;
        return AlertDialog(
          title: Text('体检 · ${p.slug}'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                HintLabel(
                  theme: t,
                  title: '体检结果',
                  hintKey: 'project.check',
                ),
                if (!result.loaded)
                  Text(
                    '读不出来：${result.loadError ?? '未知原因'}',
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.55,
                      color: Colors.redAccent,
                    ),
                  )
                else ...[
                  Text(
                    result.errors.isEmpty
                        ? '没有 error。'
                        : '${result.errors.length} 个 error（必须修）',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: result.errors.isEmpty
                          ? t.ink
                          : Colors.redAccent,
                    ),
                  ),
                  ...result.errors.map(
                    (e) => _issueTile(t, e, Colors.redAccent),
                  ),
                  if (result.warnings.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      '${result.warnings.length} 个 warning（建议修）',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Colors.orange,
                      ),
                    ),
                    ...result.warnings.map(
                      (e) => _issueTile(t, e, Colors.orange),
                    ),
                  ],
                  if (result.errors.isEmpty && result.warnings.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '结构与内容都没发现问题，可以导出或装到本地。',
                        style: TextStyle(
                          fontSize: 11.5,
                          height: 1.5,
                          color: t.sub,
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('知道了'),
            ),
          ],
        );
      },
    );
  }

  Widget _issueTile(ChatGalTheme t, ValidationError e, Color color) {
    final hint = e.hint;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            e.message,
            style: TextStyle(fontSize: 11.5, height: 1.5, color: t.ink),
          ),
          const SizedBox(height: 2),
          Text(
            e.path.isEmpty ? e.code : '${e.path} · ${e.code}',
            style: TextStyle(fontSize: 10.5, height: 1.4, color: t.sub),
          ),
          if (hint != null && hint.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              '提示：$hint',
              style: TextStyle(fontSize: 10.5, height: 1.4, color: t.sub),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _deleteProject(StudioProject p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final t = widget.theme;
        return AlertDialog(
          title: const Text('删除工程'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                HintLabel(
                  theme: t,
                  title: '删除「${p.slug}」',
                  hintKey: 'project.delete',
                ),
                Text(
                  '只会删掉这个工程目录，已装到本地的内容包不受影响。\n'
                  '删除不可撤销。',
                  style: TextStyle(fontSize: 12, height: 1.6, color: t.ink),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Colors.redAccent,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除'),
            ),
          ],
        );
      },
    );
    if (ok != true) return;
    if (!mounted) return;
    await _run(() async {
      final done = await widget.services.studio.delete(p.slug);
      if (!mounted) return;
      _reload();
      _toast(done ? '已删除工程「${p.slug}」' : '工程已不存在');
    });
  }

  // ------------------------------------------------------------------ 渲染

  String _shortHash(String hash) =>
      hash.length <= 8 ? hash : hash.substring(0, 8);

  String _fmtTime(DateTime d) {
    final l = d.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} '
        '${two(l.hour)}:${two(l.minute)}';
  }

  Widget _actionButton(
    ChatGalTheme t,
    IconData icon,
    String label,
    VoidCallback? onTap,
  ) {
    return Material(
      color: t.accent.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(Radii.button),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.button),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 17, color: t.accent),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: t.accent,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _emptyCard(ChatGalTheme t) {
    return Container(
      margin: const EdgeInsets.only(bottom: Spacing.md),
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: t.card,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: t.sub.withValues(alpha: 0.15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '还没有工程',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: t.ink,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '先新建一个内容包，或把 .chatgal 导入成工程。',
            style: TextStyle(fontSize: 12, height: 1.5, color: t.sub),
          ),
        ],
      ),
    );
  }

  Widget _projectCard(ChatGalTheme t, StudioProject p) {
    return Container(
      margin: const EdgeInsets.only(bottom: Spacing.md),
      decoration: BoxDecoration(
        color: t.card,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: p.readable
              ? t.sub.withValues(alpha: 0.15)
              : Colors.redAccent.withValues(alpha: 0.45),
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => _openEditor(p.slug),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 2, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        p.name,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: t.ink,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${p.packageId} v${p.version}',
                        style: TextStyle(fontSize: 11.5, color: t.sub),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${p.scenes} 幕 | ${p.events} 事件 | ${p.characters} 角色',
                        style: TextStyle(fontSize: 11.5, color: t.sub),
                      ),
                      if (p.description.trim().isNotEmpty) ...[
                        const SizedBox(height: 5),
                        Text(
                          p.description.trim(),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
                            height: 1.45,
                            color: t.sub,
                          ),
                        ),
                      ],
                      const SizedBox(height: 5),
                      Text(
                        '最近修改 ${_fmtTime(p.updatedAt)}',
                        style: TextStyle(fontSize: 10.5, color: t.sub),
                      ),
                      if (!p.readable) ...[
                        const SizedBox(height: 5),
                        Text(
                          'manifest 读不出来：建议删掉重新导入。',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: Colors.redAccent,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: '更多操作',
                  icon: Icon(Icons.more_vert, size: 20, color: t.sub),
                  onSelected: (action) => _menu(p, action),
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'install',
                      child: Text('导入到本地包', style: TextStyle(color: t.ink)),
                    ),
                    PopupMenuItem(
                      value: 'duplicate',
                      child: Text('复制', style: TextStyle(color: t.ink)),
                    ),
                    PopupMenuItem(
                      value: 'rename',
                      child: Text('重命名工程', style: TextStyle(color: t.ink)),
                    ),
                    PopupMenuItem(
                      value: 'export',
                      child: Text('导出 .chatgal', style: TextStyle(color: t.ink)),
                    ),
                    PopupMenuItem(
                      value: 'check',
                      child: Text('体检', style: TextStyle(color: t.ink)),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Text('删除', style: TextStyle(color: t.ink)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    return ChatGalShell(
      theme: t,
      title: '内容包创作台',
      body: ListView(
        padding: const EdgeInsets.all(Spacing.md),
        children: [
          StudioSection(
            theme: t,
            title: '内容包创作台',
            hintKey: 'project.identity',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _actionButton(
                        t,
                        Icons.add,
                        '新建内容包',
                        _busy ? null : _newProject,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _actionButton(
                        t,
                        Icons.unarchive,
                        '导入内容包',
                        _busy ? null : _importProject,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                HintLabel(
                  theme: t,
                  title: '新建内容包工程',
                  hintKey: 'studio.new',
                ),
                HintLabel(
                  theme: t,
                  title: '导入成工程',
                  hintKey: 'studio.import',
                ),
              ],
            ),
          ),
          if (_projects.isEmpty)
            _emptyCard(t)
          else
            ..._projects.map((p) => _projectCard(t, p)),
        ],
      ),
    );
  }
}

enum _ImportSource { file, installed }

/// 重命名工程：改的是**工程目录名**（工程身份），不是 manifest 里的包名。
class _RenameProjectDialog extends StatefulWidget {
  const _RenameProjectDialog({
    required this.theme,
    required this.initial,
    required this.packageName,
  });

  final ChatGalTheme theme;
  final String initial;
  final String packageName;

  @override
  State<_RenameProjectDialog> createState() => _RenameProjectDialogState();
}

class _RenameProjectDialogState extends State<_RenameProjectDialog> {
  late final TextEditingController _slug =
      TextEditingController(text: widget.initial);
  String? _error;

  @override
  void dispose() {
    _slug.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _slug.text.trim();
    if (value.isEmpty) {
      setState(() => _error = '工程目录名不能为空');
      return;
    }
    Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    return AlertDialog(
      title: const Text('重命名工程'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            HintLabel(
              theme: t,
              title: '工程目录名',
              hintKey: 'project.identity',
            ),
            TextField(
              controller: _slug,
              autofocus: true,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: '新的工程目录名',
                errorText: _error,
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '包名（manifest.name「${widget.packageName}」）不会跟着变：'
              '这次改的只是工程的身份。',
              style: TextStyle(fontSize: 11, height: 1.5, color: t.sub),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: t.accent,
            foregroundColor: Colors.white,
          ),
          onPressed: _submit,
          child: const Text('确定'),
        ),
      ],
    );
  }
}
