import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/app_services.dart';
import '../../design_system/tokens.dart';
import 'hints.dart';
import 'scene_editor.dart';

/// 变量类型下拉的选项（与 `VariableDef.types` 一致）。
const List<(String, String)> kVariableTypeOptions = [
  ('int', 'int 整数'),
  ('number', 'number 小数'),
  ('string', 'string 文本'),
  ('bool', 'bool 真/假'),
  ('enum', 'enum 枚举'),
];

/// 引擎角色（四维关系）下拉的选项。'' = 不填。
/// 变量表的一行（每个输入框一个 controller，父级负责 dispose）。
class _VarRow {
  _VarRow({
    required this.original,
    required String id,
    required this.type,
    required String defaultValue,
    required String min,
    required String max,
    required String label,
  })  : idCtrl = TextEditingController(text: id),
        defaultCtrl = TextEditingController(text: defaultValue),
        minCtrl = TextEditingController(text: min),
        maxCtrl = TextEditingController(text: max),
        labelCtrl = TextEditingController(text: label);

  /// 磁盘上的原对象（保存时用它兜住用户手动加过的未知字段）。
  final Map<String, Object?>? original;

  final TextEditingController idCtrl;
  final TextEditingController defaultCtrl;
  final TextEditingController minCtrl;
  final TextEditingController maxCtrl;
  final TextEditingController labelCtrl;
  String type;

  /// '' 表示不填。

  void dispose() {
    idCtrl.dispose();
    defaultCtrl.dispose();
    minCtrl.dispose();
    maxCtrl.dispose();
    labelCtrl.dispose();
  }
}

/// manifest.json 的表单（基础信息 + 变量表）。
///
/// 保存策略：先读出磁盘上的原 JSON，只覆盖本页认识的字段，其余原样写回 ——
/// 作者手动加过的字段不会被编辑器抹掉。
class ManifestEditor extends StatefulWidget {
  const ManifestEditor({
    super.key,
    required this.theme,
    required this.services,
    required this.slug,
    this.onSaved,
    this.onDirtyChanged,
  });

  final ChatGalTheme theme;
  final AppServices services;
  final String slug;
  final VoidCallback? onSaved;
  final ValueChanged<bool>? onDirtyChanged;

  @override
  State<ManifestEditor> createState() => _ManifestEditorState();
}

class _ManifestEditorState extends State<ManifestEditor> {
  ChatGalTheme get _t => widget.theme;

  Map<String, Object?> _raw = <String, Object?>{};

  TextEditingController? _packageId;
  TextEditingController? _version;
  TextEditingController? _name;
  TextEditingController? _author;
  TextEditingController? _description;

  List<_VarRow> _vars = <_VarRow>[];
  bool _busy = false;

  String _savedSignature = '';
  bool _lastReportedDirty = false;

  String _formSignature() {
    final parts = <String>[
      _packageId?.text ?? '',
      _version?.text ?? '',
      _name?.text ?? '',
      _author?.text ?? '',
      _description?.text ?? '',
      for (final v in _vars)
        '${v.idCtrl.text}|${v.type}|${v.defaultCtrl.text}|'
            '${v.minCtrl.text}|${v.maxCtrl.text}|${v.labelCtrl.text}',
    ];
    return parts.join(';;');
  }

  bool get _dirty => _formSignature() != _savedSignature;

  void _reportDirty() {
    if (!mounted) return;
    final d = _dirty;
    if (d != _lastReportedDirty) {
      _lastReportedDirty = d;
      widget.onDirtyChanged?.call(d);
    }
  }

  void _attachDirtyListeners() {
    void listen(TextEditingController? c) {
      c?.removeListener(_reportDirty);
      c?.addListener(_reportDirty);
    }

    listen(_packageId);
    listen(_version);
    listen(_name);
    listen(_author);
    listen(_description);
    for (final v in _vars) {
      listen(v.idCtrl);
      listen(v.defaultCtrl);
      listen(v.minCtrl);
      listen(v.maxCtrl);
      listen(v.labelCtrl);
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _disposeFields();
    super.dispose();
  }

  void _disposeFields() {
    _packageId?.dispose();
    _version?.dispose();
    _name?.dispose();
    _author?.dispose();
    _description?.dispose();
    for (final v in _vars) {
      v.dispose();
    }
  }

  void _load() {
    _disposeFields();
    final store = widget.services.studio;
    _raw = store.readJson(widget.slug, 'manifest.json') ?? <String, Object?>{};

    _packageId = TextEditingController(text: '${_raw['packageId'] ?? ''}');
    _version = TextEditingController(text: '${_raw['version'] ?? ''}');
    _name = TextEditingController(text: '${_raw['name'] ?? ''}');
    _author = TextEditingController(text: '${_raw['author'] ?? ''}');
    _description = TextEditingController(text: '${_raw['description'] ?? ''}');

    _vars = <_VarRow>[];
    final rawVars = _raw['variables'];
    if (rawVars is List) {
      for (final v in rawVars) {
        if (v is! Map) continue;
        final m = Map<String, Object?>.from(v);
        final d = m['default'];
        final min = m['min'];
        final max = m['max'];
        _vars.add(
          _VarRow(
            original: m,
            id: '${m['id'] ?? ''}',
            type: kVariableTypeOptions.any((o) => o.$1 == '${m['type']}')
                ? '${m['type']}'
                : 'int',
            defaultValue: d == null ? '' : '$d',
            min: min == null ? '' : '$min',
            max: max == null ? '' : '$max',
            label: '${m['label'] ?? ''}',
          ),
        );
      }
    }
    _savedSignature = _formSignature();
    _lastReportedDirty = false;
    _attachDirtyListeners();
    widget.onDirtyChanged?.call(false);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // -------------------------------------------------------- 字段说明弹窗

  /// 变量表四个字段的 brief + detail 全文，一次说完。
  ///
  /// 表里每列只留一行小字标签（如「类型 type」）—— 说明都收进这个弹窗，
  /// 免得变量一多就变成一墙文字。
  Future<void> _showVarFieldHelp() async {
    final t = _t;
    const fields = <(String, String)>[
      ('类型 type', 'var.type'),
      ('默认值 default / 上下限 min·max', 'var.bounds'),
      ('显示名 label', 'var.label'),
    ];
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: t.card,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.75,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '变量表这几列怎么填',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: t.ink,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '每个变量一行：id 是它在情景与条件里被引用的名字。'
                  '下面四段是最常要改的字段。',
                  style: TextStyle(fontSize: 11.5, height: 1.5, color: t.sub),
                ),
                const SizedBox(height: 12),
                for (final f in fields) _varFieldHelp(f.$1, f.$2),
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: Text('知道了', style: TextStyle(color: t.accent)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 弹窗里的一段：字段名加粗 + brief + detail。
  Widget _varFieldHelp(String fieldName, String hintKey) {
    final t = _t;
    final hint = kHints[hintKey];
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            fieldName,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: t.ink,
            ),
          ),
          if (hint != null) ...[
            const SizedBox(height: 3),
            Text(
              hint.brief,
              style: TextStyle(fontSize: 12, height: 1.55, color: t.ink),
            ),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: t.accent.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: t.accent.withValues(alpha: 0.25)),
              ),
              child: Text(
                hint.detail,
                style: TextStyle(fontSize: 11.5, height: 1.65, color: t.sub),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 校验

  bool get _versionOk => RegExp(r'^\d+$').hasMatch(_version?.text.trim() ?? '');

  String? _idError(_VarRow row) {
    final id = row.idCtrl.text.trim();
    if (id.isEmpty) return '变量 id 不能为空';
    if (id.contains('"') || id.contains("'")) {
      return '变量 id 里不要用引号（require 里引号是分隔符）';
    }
    final dup = _vars.where((r) => r.idCtrl.text.trim() == id).length;
    if (dup > 1) return '变量 id「$id」重复了，删掉多余的那行';
    return null;
  }

  String? _defaultError(_VarRow row) => _parseDefault(row).$2;

  String? _boundsError(_VarRow row) {
    final minText = row.minCtrl.text.trim();
    final maxText = row.maxCtrl.text.trim();
    final min = minText.isEmpty ? null : num.tryParse(minText);
    final max = maxText.isEmpty ? null : num.tryParse(maxText);
    if (minText.isNotEmpty && min == null) return '最小要填数字';
    if (maxText.isNotEmpty && max == null) return '最大要填数字';
    if (min != null && max != null && min > max) return '最小不能大于最大';
    return null;
  }

  (Object?, String?) _parseDefault(_VarRow row) {
    final text = row.defaultCtrl.text.trim();
    if (text.isEmpty) return (null, null);
    switch (row.type) {
      case 'int':
        final v = int.tryParse(text);
        return v == null ? (null, 'int 变量：默认值要写整数，例如 1') : (v, null);
      case 'number':
        final v = num.tryParse(text);
        return v == null ? (null, 'number 变量：默认值要写数字，例如 1.5') : (v, null);
      case 'bool':
        final low = text.toLowerCase();
        if (low == 'true') return (true, null);
        if (low == 'false') return (false, null);
        return (null, 'bool 变量：默认值只能写 true 或 false');
      default:
        return (text, null);
    }
  }

  /// 保存前的整体校验：有错就返回第一条人话错误。
  String? _firstError() {
    if ((_packageId?.text.trim() ?? '').isEmpty) return '包名 packageId 不能为空';
    if (!_versionOk) return '版本号只能是数字（例如 1、251）';
    if ((_name?.text.trim() ?? '').isEmpty) return '展示名 name 不能为空';
    for (final r in _vars) {
      final e = _idError(r) ?? _defaultError(r) ?? _boundsError(r);
      if (e != null) return e;
    }
    return null;
  }

  // ------------------------------------------------------------ 保存

  Future<void> _save() async {
    if (_busy) return;
    final err = _firstError();
    if (err != null) {
      _toast(err);
      return;
    }
    setState(() => _busy = true);
    try {
      final vars = <Map<String, Object?>>[];
      for (final r in _vars) {
        final m = <String, Object?>{...?r.original};
        m['id'] = r.idCtrl.text.trim();
        m['type'] = r.type;

        final def = _parseDefault(r).$1;
        if (def == null) {
          m.remove('default');
        } else {
          m['default'] = def;
        }

        final min = num.tryParse(r.minCtrl.text.trim());
        if (min == null) {
          m.remove('min');
        } else {
          m['min'] = min;
        }
        final max = num.tryParse(r.maxCtrl.text.trim());
        if (max == null) {
          m.remove('max');
        } else {
          m['max'] = max;
        }

        final label = r.labelCtrl.text.trim();
        if (label.isEmpty) {
          m.remove('label');
        } else {
          m['label'] = label;
        }
        vars.add(m);
      }

      final out = <String, Object?>{..._raw};
      out['packageId'] = _packageId!.text.trim();
      out['version'] = _version!.text.trim();
      out['name'] = _name!.text.trim();
      out['author'] = _author!.text.trim();
      out['description'] = _description!.text.trim();
      out['variables'] = vars;

      // 写盘异步，期间用户还能继续输入：先固定「这一份内容」的签名，
      // 否则写完拿当前表单算签名会变成「磁盘存 A、界面以为 B 已保存」。
      final savedSignature = _formSignature();
      await widget.services.studio
          .writeJson(widget.slug, 'manifest.json', out);
      if (!mounted) return;
      _raw = out;
      _savedSignature = savedSignature;
      // 重新比对当前表单：保存期间又改了要立刻算脏，不能重置成 false。
      final stillDirty = _formSignature() != _savedSignature;
      _lastReportedDirty = stillDirty;
      widget.onDirtyChanged?.call(stillDirty);
      widget.onSaved?.call();
    } catch (e) {
      _toast('保存失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // -------------------------------------------------------- 主页底图 home.png

  /// 主页底图固定是包根的 `home.png`（文件名由引擎与打包脚本写死），
  /// 所以这里不管选了哪张图，都会以它的字节存成 `home.png`。
  File _homeFile() =>
      File(widget.services.studio.absPathOf(widget.slug, 'home.png'));

  Future<void> _pickHomeImage() async {
    if (_busy) return;
    final picked =
        await pickStudioImages(dialogTitle: '选择主页底图（会存成 home.png）');
    if (picked.isEmpty || !mounted) return;
    final file = picked.first;
    final src = file.name;
    if (_homeFile().existsSync()) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: _t.card,
          title: Text('覆盖现在的主页底图？', style: TextStyle(color: _t.ink)),
          content: Text(
            '包根已经有 home.png，导入会把主页底图换成这张。'
            '它只影响主页背景，不影响任何剧情。',
            style: TextStyle(color: _t.sub, fontSize: 13, height: 1.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text('取消', style: TextStyle(color: _t.sub)),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('覆盖', style: TextStyle(color: Colors.red)),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    setState(() => _busy = true);
    try {
      final bytes = await readStudioImageBytes(file);
      if (!mounted) return;
      await widget.services.studio.writeBytes(widget.slug, 'home.png', bytes);
      if (!mounted) return;
      // `Image.file` 走 FileImage，缓存键只有「路径 + scale」：覆盖同一个
      // home.png 之后不 evict，界面上还是旧图（作者会以为导入失败）。
      await FileImage(_homeFile()).evict();
      if (!mounted) return;
      setState(() {});
      // 包内容变了（主页底图在/不在，影响体检里的那条 warning）：通知父页重跑体检。
      widget.onSaved?.call();
      _toast('已导入主页底图（$src → home.png）');
    } catch (e) {
      _toast('导入失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteHomeImage() async {
    if (_busy) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _t.card,
        title: Text('删除主页底图？', style: TextStyle(color: _t.ink)),
        content: Text(
          '删掉包根的 home.png 后，主页会用主题色兜底（体检会给一条 warning）。',
          style: TextStyle(color: _t.sub, fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消', style: TextStyle(color: _t.sub)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.services.studio.deletePath(widget.slug, 'home.png');
      if (!mounted) return;
      setState(() {});
      // 删掉后体检会多一条「缺 home.png」的 warning：同样要通知父页重跑。
      widget.onSaved?.call();
      _toast('已删除 home.png');
    } catch (e) {
      _toast('删除失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _homeImageSection(ChatGalTheme t) {
    final file = _homeFile();
    final has = file.existsSync();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 108,
                height: 68,
                child: has
                    ? Image.file(
                        file,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        errorBuilder: (context, error, stack) => Container(
                          color: t.sub.withValues(alpha: 0.12),
                          alignment: Alignment.center,
                          child: Icon(
                            Icons.broken_image_outlined,
                            size: 20,
                            color: t.sub,
                          ),
                        ),
                      )
                    : Container(
                        color: t.sub.withValues(alpha: 0.10),
                        alignment: Alignment.center,
                        child: Icon(
                          Icons.image_outlined,
                          size: 20,
                          color: t.sub,
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    has ? '已导入 home.png' : '还没有主页底图',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: t.ink,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    has
                        ? '主页背景用的就是这张图（固定文件名 home.png）。'
                        : '主页会退成主题色。选一张竖图或横图都行，'
                            '存进包里时会统一叫 home.png。',
                    style: TextStyle(fontSize: 11.5, height: 1.5, color: t.sub),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: _busy ? null : _pickHomeImage,
                        icon: const Icon(Icons.add_photo_alternate_outlined,
                            size: 17),
                        label: Text(
                          has ? '换一张' : '选择并导入',
                          style: const TextStyle(fontSize: 12.5),
                        ),
                      ),
                      if (has)
                        OutlinedButton.icon(
                          onPressed: _busy ? null : _deleteHomeImage,
                          icon: const Icon(
                            Icons.delete_outline_rounded,
                            size: 17,
                            color: Colors.red,
                          ),
                          label: const Text(
                            '删除',
                            style: TextStyle(fontSize: 12.5, color: Colors.red),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ------------------------------------------------------------ 界面

  @override
  Widget build(BuildContext context) {
    // 帧结束后检查脏状态并上报（覆盖下拉框/结构变化等非文本路径）。
    WidgetsBinding.instance.addPostFrameCallback((_) => _reportDirty());
    final t = _t;
    final hasDay = _vars.any((r) => r.idCtrl.text.trim() == 'day');
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 28),
      children: [
        _statusLine(),
        const SizedBox(height: 10),
        StudioSection(
          theme: t,
          title: '工程概况',
          hintKey: 'manifest.packageId',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              HintLabel(
                theme: t,
                title: '包名 packageId',
                hintKey: 'manifest.packageId',
                required: true,
              ),
              TextField(
                controller: _packageId,
                style: TextStyle(fontSize: 13.5, color: t.ink),
                decoration: const InputDecoration(
                  hintText: '例：com.你的名字.包名',
                ),
                onChanged: (_) => setState(() {}),
              ),
              if ((_packageId?.text.trim() ?? '').contains(' '))
                StudioNote(
                  theme: t,
                  text: '包名里出现了空格：建议改成反写域名风格、全小写、用点分段。',
                  color: Colors.orange,
                  icon: Icons.warning_amber_rounded,
                ),
              const SizedBox(height: 12),
              HintLabel(
                theme: t,
                title: '版本号 version',
                hintKey: 'manifest.version',
                required: true,
              ),
              TextField(
                controller: _version,
                keyboardType: TextInputType.number,
                style: TextStyle(
                  fontSize: 13.5,
                  color: _versionOk ? t.ink : Colors.red,
                ),
                decoration: InputDecoration(
                  hintText: '1',
                  enabledBorder: _versionOk
                      ? null
                      : OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: const BorderSide(color: Colors.red),
                        ),
                  focusedBorder: _versionOk
                      ? null
                      : OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: const BorderSide(color: Colors.red),
                        ),
                ),
                onChanged: (_) => setState(() {}),
              ),
              if (!_versionOk)
                StudioNote(
                  theme: t,
                  text: '版本号只能是数字（不能带字母、点、横线）。'
                      '本地已有同包名同版本但内容不同时，必须把版本号加一才能装。',
                  color: Colors.red,
                  icon: Icons.error_outline_rounded,
                ),
              const SizedBox(height: 12),
              HintLabel(
                theme: t,
                title: '展示名 name',
                hintKey: 'manifest.name',
                required: true,
              ),
              TextField(
                controller: _name,
                style: TextStyle(fontSize: 13.5, color: t.ink),
                decoration: const InputDecoration(hintText: '例：你好戒戒'),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              HintLabel(theme: t, title: '作者 author', hintKey: 'manifest.author'),
              TextField(
                controller: _author,
                style: TextStyle(fontSize: 13.5, color: t.ink),
                decoration: const InputDecoration(hintText: '你的名字（会显示在内容包与存档页）'),
              ),
              const SizedBox(height: 12),
              HintLabel(
                theme: t,
                title: '简介 description',
                hintKey: 'manifest.description',
              ),
              TextField(
                controller: _description,
                minLines: 2,
                maxLines: 5,
                style: TextStyle(fontSize: 13.5, color: t.ink),
                decoration:
                    const InputDecoration(hintText: '例：14 天主线 42 幕 · 三个结局后的日常'),
              ),
            ],
          ),
        ),
        StudioSection(
          theme: t,
          title: '主页底图 home.png',
          hintKey: 'manifest.home',
          child: _homeImageSection(t),
        ),
        StudioSection(
          theme: t,
          title: '变量表（共 ${_vars.length} 个）',
          hintKey: 'manifest.variables',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!hasDay)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.red.withValues(alpha: 0.4)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '没有 day 变量！',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                          color: Colors.red,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '天数与剧情分支全靠在 day 上加减（新的一天第一幕写 day +1）；'
                        '删了它，天数就不会再走，`"day" == 7` 这类条件也永远不成立。',
                        style: TextStyle(fontSize: 11.5, height: 1.5, color: t.sub),
                      ),
                      const SizedBox(height: 6),
                      OutlinedButton.icon(
                        onPressed: () => setState(() {
                          _vars.insert(
                            0,
                            _VarRow(
                              original: null,
                              id: 'day',
                              type: 'int',
                              // 默认 0：开局进 start 时由入场改值 +1 = 第 1 天
                              defaultValue: '0',
                              min: '',
                              max: '',
                              label: '',
                            ),
                          );
                        }),
                        icon: const Icon(
                          Icons.restore_rounded,
                          size: 16,
                          color: Colors.red,
                        ),
                        label: const Text(
                          '补回 day 变量（int，默认 0，配合 start 入场 +1）',
                          style: TextStyle(color: Colors.red, fontSize: 12.5),
                        ),
                      ),
                    ],
                  ),
                ),
              // 每列只在行里标一行字段名，说明收进这个按钮的弹窗里。
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: _showVarFieldHelp,
                  icon: Icon(
                    Icons.help_outline_rounded,
                    size: 16,
                    color: t.accent,
                  ),
                  label: Text(
                    '这些字段怎么填？',
                    style: TextStyle(color: t.accent, fontSize: 12),
                  ),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              for (var i = 0; i < _vars.length; i++) _varCard(i),
              OutlinedButton.icon(
                onPressed: () => setState(() {
                  _vars.add(
                    _VarRow(
                      original: null,
                      id: '',
                      type: 'int',
                      defaultValue: '0',
                      // 上下限默认留空 = 不设限。想要硬边界（例如好感 0~100）
                      // 再自己填；默认给 0/100 会让「忘了改」变成「悄悄夹住」。
                      min: '',
                      max: '',
                      label: '',
                    ),
                  );
                }),
                icon: Icon(Icons.add_rounded, size: 18, color: t.accent),
                label: Text(
                  '新增变量',
                  style: TextStyle(color: t.accent, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: t.accent,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          onPressed: _busy ? null : _save,
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save_outlined, size: 18),
          label: const Text('保存基础信息'),
        ),
      ],
    );
  }

  Widget _statusLine() {
    final t = _t;
    final store = widget.services.studio;
    final slug = widget.slug;
    final m = store.readJson(slug, 'manifest.json') ?? <String, Object?>{};
    final chars = store
        .listDirs(slug, 'characters')
        .where((id) => store.readJson(slug, 'characters/$id/character.json') != null)
        .length;
    final scenes = sceneIdsOf(store, slug).length;
    final events = store
        .listDirs(slug, 'events')
        .where((id) => store.readJson(slug, 'events/$id/event.json') != null)
        .length;
    final pkg = '${m['packageId'] ?? ''}'.trim();
    final ver = '${m['version'] ?? '?'}'.trim();
    final line = '${pkg.isEmpty ? '（还没填包名）' : pkg}'
        ' · v$ver · $chars 角色 · $scenes 情景 · $events 事件';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: t.accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: t.accent.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(Icons.folder_outlined, size: 15, color: t.accent),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              line,
              style: TextStyle(fontSize: 12, color: t.ink, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _varCard(int i) {
    final t = _t;
    final r = _vars[i];
    final idErr = _idError(r);
    final defErr = _defaultError(r);
    final boundsErr = _boundsError(r);
    // day 是系统变量：显示名与引擎角色由引擎约定，不让改（上下限仍可改）。
    final isDay = r.idCtrl.text.trim() == 'day';
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
      decoration: BoxDecoration(
        color: t.bg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: idErr != null
              ? Colors.red.withValues(alpha: 0.5)
              : t.sub.withValues(alpha: 0.18),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              StudioTag(theme: t, text: '变量 ${i + 1}'),
              const SizedBox(width: 6),
              if (r.idCtrl.text.trim() == 'day')
                StudioTag(theme: t, text: '系统变量·务必保留', color: Colors.orange),
              const Spacer(),
              IconButton(
                tooltip: '删除这个变量',
                onPressed: () => setState(() => _vars.removeAt(i).dispose()),
                icon: const Icon(Icons.delete_outline_rounded, size: 17),
                color: t.sub,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              ),
            ],
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _fieldLabel('变量 id', t),
                    const SizedBox(height: 2),
                    TextField(
                      controller: r.idCtrl,
                      style: TextStyle(fontSize: 13, color: t.ink),
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: '可用中文，如 戒戒好感',
                        contentPadding:
                            EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 132,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _fieldLabel('类型 type', t),
                    const SizedBox(height: 2),
                    StudioDropdown<String>(
                      theme: t,
                      value: r.type,
                      options: kVariableTypeOptions,
                      onChanged: (v) => setState(() => r.type = v ?? 'int'),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: HintDot(theme: t, hintKey: 'var.type'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(child: _smallField('默认值 default', r.defaultCtrl, t)),
              const SizedBox(width: 6),
              Expanded(child: _smallField('最小 min', r.minCtrl, t)),
              const SizedBox(width: 6),
              Expanded(child: _smallField('最大 max', r.maxCtrl, t)),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: isDay
                    // day 的显示名固定：它是系统变量，改了只会让控制台更难认。
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _fieldLabel('显示名 label（固定）', t),
                          const SizedBox(height: 4),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 11,
                            ),
                            decoration: BoxDecoration(
                              color: t.sub.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: t.sub.withValues(alpha: 0.18),
                              ),
                            ),
                            child: Text(
                              '天数',
                              style: TextStyle(fontSize: 13, color: t.sub),
                            ),
                          ),
                        ],
                      )
                    : _smallField(
                        '显示名 label（可留空）',
                        r.labelCtrl,
                        t,
                        hintKey: 'var.label',
                        numeric: false,
                      ),
              ),
              const SizedBox(width: 8),
            ],
          ),
          if (isDay) ...[
            const SizedBox(height: 4),
            StudioNote(
              theme: t,
              text: 'day 的默认值写 **0**：新游戏进 start 时由「入场改值」里的 day +1 '
                  '变成第 1 天（新的一天也是这么 +1 的）。上下限留空＝不设限。'
                  '默认包与教学包都是这套写法；新建工程会自动替你在 start 写好 day +1。',
              color: t.accent,
              icon: Icons.info_outline_rounded,
            ),
          ],
          if (idErr != null)
            StudioNote(
              theme: t,
              text: idErr,
              color: Colors.red,
              icon: Icons.error_outline_rounded,
            ),
          if (defErr != null) StudioNote(theme: t, text: defErr, color: Colors.red),
          if (boundsErr != null)
            StudioNote(theme: t, text: boundsErr, color: Colors.red),
        ],
      ),
    );
  }

  /// 一行小字字段名（例如「类型 type」）。
  ///
  /// 变量表里只标字段名，不再逐行渲染 brief 句子 —— 说明都在「这些字段怎么填？」里。
  Widget _fieldLabel(String label, ChatGalTheme t) => Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11, color: t.sub),
      );

  Widget _smallField(
    String label,
    TextEditingController ctrl,
    ChatGalTheme t, {
    String hintKey = 'var.bounds',
    bool numeric = true,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(child: _fieldLabel(label, t)),
            HintDot(theme: t, hintKey: hintKey),
          ],
        ),
        const SizedBox(height: 2),
        TextField(
          controller: ctrl,
          keyboardType: numeric
              ? const TextInputType.numberWithOptions(
                  signed: true,
                  decimal: true,
                )
              : null,
          style: TextStyle(fontSize: 13, color: t.ink),
          decoration: const InputDecoration(
            isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          ),
          onChanged: (_) => setState(() {}),
        ),
      ],
    );
  }
}
