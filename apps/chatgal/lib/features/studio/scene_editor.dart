import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:gal_protocol/gal_protocol.dart';
import 'package:gal_storage/gal_storage.dart';

import '../../app/app_services.dart';
import '../../design_system/tokens.dart';
import 'hints.dart';
import 'require_editor.dart';

// ===========================================================================
//  公共：图片工具（本文件被 character_editor / event_editor 复用）
// ===========================================================================

/// 允许导入的图片扩展名（file_picker 的 allowedExtensions 与下拉筛选共用）。
const List<String> kStudioImageExtensions = ['png', 'jpg', 'jpeg', 'webp'];

/// 文件名是不是图片（按扩展名判断，大小写不敏感）。
bool isStudioImage(String fileName) {
  final i = fileName.lastIndexOf('.');
  if (i < 0 || i == fileName.length - 1) return false;
  return kStudioImageExtensions.contains(fileName.substring(i + 1).toLowerCase());
}

/// 弹系统选择器挑图片。[multiple] 为真时可多选。
Future<List<PlatformFile>> pickStudioImages({
  bool multiple = false,
  String dialogTitle = '选择图片',
}) async {
  if (multiple) {
    // pickFiles 默认就是多选（allowMultiple 已废弃）。
    return FilePicker.pickFiles(
      dialogTitle: dialogTitle,
      type: FileType.custom,
      allowedExtensions: kStudioImageExtensions,
    );
  }
  final one = await FilePicker.pickFile(
    dialogTitle: dialogTitle,
    type: FileType.custom,
    allowedExtensions: kStudioImageExtensions,
  );
  return one == null ? const <PlatformFile>[] : <PlatformFile>[one];
}

/// 读选中图片的字节。Android 的 SAF 下 [PlatformFile.path] 可能是 null，
/// 这时退回 `readAsBytes()`；能拿到本地路径时就直接读文件。
Future<List<int>> readStudioImageBytes(PlatformFile file) async {
  final path = file.path;
  if (path != null && path.isNotEmpty) {
    final f = File(path);
    if (f.existsSync()) return f.readAsBytes();
  }
  return file.readAsBytes();
}

/// 导入用的文件名清洗：去掉路径分隔符等非法字符（文件名不做重命名，
/// 尽量保留作者自己的命名）。
String sanitizeStudioFileName(String raw, {String fallback = 'image.png'}) {
  final cleaned = raw
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '')
      .replaceAll(RegExp(r'\s+'), '_')
      .trim();
  return cleaned.isEmpty ? fallback : cleaned;
}

// ===========================================================================
//  公共：小部件
// ===========================================================================

/// 一行小字（灰/彩色提示、错误），创作台里到处都在用。
class StudioNote extends StatelessWidget {
  const StudioNote({
    super.key,
    required this.theme,
    required this.text,
    this.color,
    this.icon,
  });

  final ChatGalTheme theme;
  final String text;
  final Color? color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final c = color ?? theme.sub;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: c),
            const SizedBox(width: 5),
          ],
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 11.5, height: 1.5, color: c),
            ),
          ),
        ],
      ),
    );
  }
}

/// 小胶囊标签。
class StudioTag extends StatelessWidget {
  const StudioTag({super.key, required this.theme, required this.text, this.color});

  final ChatGalTheme theme;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? theme.accent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 10, color: c, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// 创作台图片预览：选中后完整显示（contain，不裁切）。
class StudioImagePreview extends StatelessWidget {
  const StudioImagePreview({
    super.key,
    required this.theme,
    required this.file,
    this.height = 120,
    this.emptyText = '未选择图片',
  });

  final ChatGalTheme theme;
  final File? file;
  final double height;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    final t = theme;
    final f = file;
    final border = Border.all(color: t.sub.withValues(alpha: 0.2));
    if (f == null || !f.existsSync()) {
      final name = f == null
          ? emptyText
          : '文件不存在：${Uri.file(f.path).pathSegments.last}';
      return Container(
        height: height,
        width: double.infinity,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: t.bg,
          borderRadius: BorderRadius.circular(12),
          border: border,
        ),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Text(
            name,
            style: TextStyle(fontSize: 12, color: t.sub),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    }
    return Container(
      height: height,
      width: double.infinity,
      decoration: BoxDecoration(
        color: t.bg,
        borderRadius: BorderRadius.circular(12),
        border: border,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: InteractiveViewer(
          maxScale: 4,
          minScale: 0.5,
          child: Image.file(
            f,
            key: ValueKey(
              '${f.path}|${f.lastModifiedSync().millisecondsSinceEpoch}',
            ),
            // contain：完整看到整张图，不按框裁切
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => Center(
              child: Text(
                '图片无法预览',
                style: TextStyle(fontSize: 12, color: t.sub),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 选图器：左侧竖排候选缩略图 + 右侧当前图预览（并排）。
///
/// 候选区上下滚动，竖向大约露出三张；右侧预览与候选区等高，纵向更充分。
class StudioImagePicker extends StatelessWidget {
  const StudioImagePicker({
    super.key,
    required this.theme,
    required this.names,
    required this.selected,
    required this.fileOf,
    required this.onSelect,
    this.onImport,
    this.allowEmpty = false,
    this.emptyLabel = '（留空）',
    this.previewHeight,
  });

  final ChatGalTheme theme;
  final List<String> names;
  final String? selected;
  final File Function(String name) fileOf;
  final ValueChanged<String> onSelect;
  final Future<void> Function()? onImport;

  /// 情景背景允许留空（主题色兜底）；事件分块图也可「沿用上一张」。
  final bool allowEmpty;
  final String emptyLabel;

  /// 右侧预览高度；null = 跟随左侧候选区高度（约三张缩略图）。
  final double? previewHeight;

  /// 一张缩略图（含文件名）约 96 高；竖排露出 3 张 ≈ 288。
  static const double _thumbExtent = 96;
  static const double _thumbGap = 6;
  static const double _listHeight = _thumbExtent * 3 + _thumbGap * 2; // 300

  Widget _thumb(ChatGalTheme t, String name, {required bool emptyItem}) {
    final sel = name == (selected ?? '');
    final f = emptyItem ? null : fileOf(name);
    final exists = f != null && f.existsSync();
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => onSelect(name),
      child: Container(
        height: _thumbExtent,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: sel ? t.accent : t.sub.withValues(alpha: 0.25),
            width: sel ? 2 : 1,
          ),
          color: sel ? t.accent.withValues(alpha: 0.08) : t.card,
        ),
        child: Column(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(7),
              child: SizedBox(
                height: 64,
                width: double.infinity,
                child: emptyItem
                    ? Container(
                        color: t.bg,
                        alignment: Alignment.center,
                        child: Icon(
                          Icons.block,
                          size: 20,
                          color: t.sub,
                        ),
                      )
                    : exists
                        ? Image.file(
                            f,
                            key: ValueKey(
                              '${f.path}|${f.lastModifiedSync().millisecondsSinceEpoch}',
                            ),
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => _iconBox(t),
                          )
                        : _iconBox(t),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              emptyItem ? emptyLabel : name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 10,
                color: sel ? t.ink : t.sub,
                fontWeight: sel ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _iconBox(ChatGalTheme t) {
    return Container(
      color: t.bg,
      alignment: Alignment.center,
      child: Icon(Icons.broken_image_outlined, size: 18, color: t.sub),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = theme;
    final sel = selected ?? '';
    final sideH = previewHeight ?? _listHeight;
    final items = <String>[
      if (allowEmpty) '',
      ...names,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                names.isEmpty
                    ? '还没有可选图片，点右侧导入'
                    : '左侧点缩略图选择 · 候选 ${names.length} 张',
                style: TextStyle(fontSize: 11.5, color: t.sub),
              ),
            ),
            if (onImport != null)
              TextButton.icon(
                onPressed: onImport,
                icon: Icon(
                  Icons.add_photo_alternate_outlined,
                  size: 16,
                  color: t.accent,
                ),
                label: Text(
                  '导入',
                  style: TextStyle(color: t.accent, fontSize: 12.5),
                ),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 左：竖排候选，约三张高，上下滚动
            SizedBox(
              width: 92,
              height: sideH,
              child: items.isEmpty
                  ? Container(
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: t.bg,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: t.sub.withValues(alpha: 0.2)),
                      ),
                      child: Text(
                        '暂无',
                        style: TextStyle(fontSize: 12, color: t.sub),
                      ),
                    )
                  : ListView.separated(
                      scrollDirection: Axis.vertical,
                      itemCount: items.length,
                      separatorBuilder: (_, _) =>
                          const SizedBox(height: _thumbGap),
                      itemBuilder: (_, i) {
                        final n = items[i];
                        return _thumb(
                          t,
                          n,
                          emptyItem: allowEmpty && n.isEmpty,
                        );
                      },
                    ),
            ),
            const SizedBox(width: 10),
            // 右：当前图预览，与候选区等高
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    sel.isEmpty
                        ? emptyLabel
                        : '当前 · $sel',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: t.ink,
                    ),
                  ),
                  const SizedBox(height: 6),
                  StudioImagePreview(
                    theme: t,
                    file: sel.isEmpty ? null : fileOf(sel),
                    height: sideH - 24,
                    emptyText: emptyLabel,
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 顶部条目选择器：默认横向滑动；点「展开平铺」变 Wrap，项目多也好找。
class StudioIdSelector extends StatefulWidget {
  const StudioIdSelector({
    super.key,
    required this.theme,
    required this.ids,
    required this.selected,
    required this.onSelect,
    this.labelOf,
  });

  final ChatGalTheme theme;
  final List<String> ids;
  final String? selected;
  final ValueChanged<String> onSelect;
  final String Function(String id)? labelOf;

  @override
  State<StudioIdSelector> createState() => _StudioIdSelectorState();
}

class _StudioIdSelectorState extends State<StudioIdSelector> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    Widget chip(String id) {
      final sel = id == widget.selected;
      final label = widget.labelOf?.call(id) ?? id;
      return ChoiceChip(
        label: Text(label),
        selected: sel,
        showCheckmark: false,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        backgroundColor: t.bg,
        selectedColor: t.accent.withValues(alpha: 0.18),
        side: BorderSide(
          color: sel ? t.accent : t.sub.withValues(alpha: 0.25),
        ),
        labelStyle: TextStyle(
          fontSize: 12,
          color: sel ? t.ink : t.sub,
          fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
        ),
        onSelected: (_) => widget.onSelect(id),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              _expanded ? '平铺浏览（点条目切换）' : '横向滑动 · 可展开平铺',
              style: TextStyle(fontSize: 11, color: t.sub),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: () => setState(() => _expanded = !_expanded),
              icon: Icon(
                _expanded ? Icons.unfold_less_rounded : Icons.grid_view_rounded,
                size: 16,
                color: t.accent,
              ),
              label: Text(
                _expanded ? '收起' : '展开平铺',
                style: TextStyle(color: t.accent, fontSize: 12.5),
              ),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 6),
              ),
            ),
          ],
        ),
        if (_expanded)
          Container(
            constraints: const BoxConstraints(maxHeight: 148),
            padding: const EdgeInsets.only(bottom: 4),
            child: SingleChildScrollView(
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [for (final id in widget.ids) chip(id)],
              ),
            ),
          )
        else
          SizedBox(
            height: 40,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: widget.ids.length,
              separatorBuilder: (_, _) => const SizedBox(width: 6),
              itemBuilder: (_, i) => chip(widget.ids[i]),
            ),
          ),
      ],
    );
  }
}

/// ⓘ 小圆点：点一下弹出这一项的完整说明。
///
/// 密集的表单行（例如每个出场角色）用它会比整块 [HintLabel] 清爽，
/// 点开的内容与 [HintLabel] 完全一样。
class HintDot extends StatelessWidget {
  const HintDot({super.key, required this.theme, required this.hintKey});

  final ChatGalTheme theme;
  final String hintKey;

  @override
  Widget build(BuildContext context) {
    if (!kHints.containsKey(hintKey)) return const SizedBox.shrink();
    return InkWell(
      onTap: () => showStudioHint(context, theme, hintKey),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
        child: Icon(Icons.info_outline_rounded, size: 15, color: theme.accent),
      ),
    );
  }
}

/// 弹出某个 hintKey 的完整说明（底部弹窗，滚动到底）。
Future<void> showStudioHint(
  BuildContext context,
  ChatGalTheme theme,
  String hintKey, {
  String? title,
}) async {
  final hint = kHints[hintKey];
  if (hint == null) return;
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: theme.card,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(ctx).size.height * 0.7,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title ?? '字段说明',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: theme.ink,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                hint.brief,
                style: TextStyle(fontSize: 13, height: 1.6, color: theme.ink),
              ),
              const SizedBox(height: 10),
              Text(
                hint.detail,
                style: TextStyle(fontSize: 12.5, height: 1.75, color: theme.sub),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: Text('知道了', style: TextStyle(color: theme.accent)),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

// ===========================================================================
//  公共：出口块（target[]）—— 情景与事件用同一套
// ===========================================================================

/// 一个出口目的地：`{ "kind": "story|event|appShell", "to": "..." }`。
class TargetKindModel {
  TargetKindModel({required this.kind, required this.to});

  String kind;
  String to;
}

/// 一个出口块：可选 `require` 条件 + 若干等概率目的地。
class TargetBlockModel {
  TargetBlockModel({String require = '', List<TargetKindModel>? kinds})
      : id = _nextId++,
        requireCtrl = TextEditingController(text: require),
        kinds = kinds ?? <TargetKindModel>[];

  static int _nextId = 1;

  /// 稳定的块编号：只用来给 Widget 当 key（移动/删除时状态不会串到别的块上）。
  final int id;

  final TextEditingController requireCtrl;
  final List<TargetKindModel> kinds;

  bool get isFallback => requireCtrl.text.trim().isEmpty;

  /// 脏检测用的签名。
  String signature() => '${requireCtrl.text}||'
      '${kinds.map((k) => '${k.kind}:${k.to}').join(',')}';

  void dispose() => requireCtrl.dispose();
}

/// 从 JSON 读出口块（宽容：坏结构跳过，不是抛异常）。
List<TargetBlockModel> targetBlocksFromJson(Object? raw) {
  final out = <TargetBlockModel>[];
  if (raw is! List) return out;
  for (final e in raw) {
    if (e is! Map) continue;
    final m = Map<String, Object?>.from(e);
    final kinds = <TargetKindModel>[];
    final kr = m['kind'];
    if (kr is List) {
      for (final k in kr) {
        if (k is! Map) continue;
        final km = Map<String, Object?>.from(k);
        final kind = '${km['kind'] ?? ''}'.trim();
        final to = '${km['to'] ?? ''}'.trim();
        if (kind.isEmpty && to.isEmpty) continue;
        kinds.add(TargetKindModel(kind: kind.isEmpty ? 'story' : kind, to: to));
      }
    }
    out.add(TargetBlockModel(require: '${m['require'] ?? ''}', kinds: kinds));
  }
  return out;
}

/// 写成冻结格式：`[{ "require"?: str, "kind": [ {"kind": str, "to": str} ] }]`。
List<Map<String, Object?>> targetBlocksToJson(List<TargetBlockModel> blocks) {
  return <Map<String, Object?>>[
    for (final b in blocks)
      <String, Object?>{
        if (b.requireCtrl.text.trim().isNotEmpty)
          'require': b.requireCtrl.text.trim(),
        'kind': <Map<String, Object?>>[
          for (final k in b.kinds)
            <String, Object?>{'kind': k.kind, 'to': k.to.trim()},
        ],
      },
  ];
}

/// 一个受控变量块：变量 + 它**自己**的判定提示词 + 它**自己**的单次上限 + 无证据策略。
///
/// 结算不再是「一条公共说明 + 一串变量名」：每个变量各写各的判定标准，
/// 例如「好感」看有没有更亲近、「服从」看有没有按指令行动。
class SettlementVarModel {
  SettlementVarModel({
    this.varId = '',
    String prompt = '',
    int maxAbsDelta = 3,
    this.onNoEvidence = 'zero',
  })  : promptCtrl = TextEditingController(text: prompt),
        maxCtrl = TextEditingController(text: '$maxAbsDelta');

  String varId;
  final TextEditingController promptCtrl;
  final TextEditingController maxCtrl;

  /// `zero`（这一个变量保持原值）或 `abort`（拒绝本次离场）。
  String onNoEvidence;

  int get maxAbs => int.tryParse(maxCtrl.text.trim()) ?? 3;

  void dispose() {
    promptCtrl.dispose();
    maxCtrl.dispose();
  }
}

/// 从 JSON 读结算块（宽容：坏结构跳过，不是抛异常）。
List<SettlementVarModel> settlementVarsFromJson(Object? raw) {
  final out = <SettlementVarModel>[];
  if (raw is! List) return out;
  for (final e in raw) {
    if (e is! Map) continue;
    final m = Map<String, Object?>.from(e);
    final id = '${m['var'] ?? ''}'.trim();
    if (id.isEmpty) continue;
    final on = '${m['onNoEvidence'] ?? 'zero'}';
    out.add(SettlementVarModel(
      varId: id,
      prompt: '${m['prompt'] ?? ''}',
      maxAbsDelta: (m['maxAbsDelta'] as num?)?.toInt() ?? 3,
      onNoEvidence: on == 'abort' ? 'abort' : 'zero',
    ));
  }
  return out;
}

/// 写成冻结格式：`[{ "var": id, "prompt": str, "maxAbsDelta": int, "onNoEvidence": str }]`。
List<Map<String, Object?>> settlementVarsToJson(
  List<SettlementVarModel> blocks,
) =>
    <Map<String, Object?>>[
      for (final b in blocks)
        if (b.varId.trim().isNotEmpty)
          <String, Object?>{
            'var': b.varId.trim(),
            'prompt': b.promptCtrl.text.trim(),
            'maxAbsDelta': b.maxAbs,
            'onNoEvidence': b.onNoEvidence,
          },
    ];

/// 保存前的校验：返回第一条人话错误，或 null。
String? settlementVarsError(List<SettlementVarModel> blocks) {
  final seen = <String>{};
  for (final b in blocks) {
    final id = b.varId.trim();
    if (id.isEmpty) return '有一个结算块还没选变量';
    if (!seen.add(id)) {
      return '「$id」有两个结算块：合并成一条，把判定说明写在一起';
    }
    if (b.promptCtrl.text.trim().isEmpty) {
      return '「$id」没写判定提示词：模型不知道该按什么标准给它加减';
    }
    if (b.maxAbs <= 0) return '「$id」的单次上限必须是正整数';
  }
  return null;
}

/// require 文本的实时校验：语法（走引擎自己的解析器）+ 变量是否注册过。
///
/// 引号里的名字直接用正则抽出来比对 manifest 变量 id：
/// `RequireExpr.variablesIn` 在语法错误时会直接抛，这里不能拿它当校验用。
String? requireExprError(String text, Set<String> knownVariables) {
  final t = text.trim();
  if (t.isEmpty) return null;
  final syntax = RequireExpr.check(t);
  if (syntax != null) return '语法错误：$syntax';
  final names = RegExp(r'''["']([^"']*)["']''')
      .allMatches(t)
      .map((m) => m.group(1) ?? '')
      .where((s) => s.isNotEmpty)
      .toSet();
  final unknown = names.where((n) => !knownVariables.contains(n)).toList();
  if (unknown.isNotEmpty) {
    return '引用了未注册的变量：${unknown.join('、')}（去「基础信息」里注册）';
  }
  return null;
}

/// 整组出口块能不能保存：返回第一条人话错误，或 null。
String? targetBlocksError(
  List<TargetBlockModel> blocks, {
  required Set<String> knownVariables,
  required List<String> storyIds,
  required List<String> eventIds,
}) {
  for (var i = 0; i < blocks.length; i++) {
    final b = blocks[i];
    final err = requireExprError(b.requireCtrl.text, knownVariables);
    if (err != null) return '出口块 ${i + 1} 的条件：$err';
    if (b.kinds.isEmpty) return '出口块 ${i + 1} 还没选目的地';
    for (final k in b.kinds) {
      final to = k.to.trim();
      if (to.isEmpty) return '出口块 ${i + 1} 有一个目的地没选';
      if (k.kind == 'story' && !storyIds.contains(to)) {
        return '出口块 ${i + 1} 指向的情景「$to」不存在';
      }
      if (k.kind == 'event' && !eventIds.contains(to)) {
        return '出口块 ${i + 1} 指向的事件「$to」不存在';
      }
      if (k.kind == 'appShell' && to != 'home') {
        return '出口块 ${i + 1} 的 appShell 只能写 home';
      }
    }
  }
  return null;
}

/// 出口块列表编辑器（情景 / 事件共用）。
///
/// [blocks] 由父级持有（父级负责 dispose 被删掉的 controller），
/// 这里只负责渲染 + 通过 [onChanged] 交回新的列表。
class TargetBlocksEditor extends StatelessWidget {
  const TargetBlocksEditor({
    super.key,
    required this.theme,
    required this.blocks,
    required this.onChanged,
    required this.knownVariables,
    required this.storyIds,
    required this.eventIds,
    this.title = '出口 target',
    this.hintKey = 'scene.target',
    this.emptyNote = '还没有出口：玩家点「下一阶段」会停在原地（合法，但剧情走不下去）。',
  });

  final ChatGalTheme theme;
  final List<TargetBlockModel> blocks;
  final ValueChanged<List<TargetBlockModel>> onChanged;
  final Set<String> knownVariables;
  final List<String> storyIds;
  final List<String> eventIds;
  final String title;
  final String hintKey;
  final String emptyNote;

  static const List<(String, String)> _kindOptions = [
    ('story', 'story（情景）'),
    ('event', 'event（事件）'),
    ('appShell', 'appShell（回主页）'),
  ];

  @override
  Widget build(BuildContext context) {
    final t = theme;
    return StudioSection(
      theme: t,
      title: title,
      hintKey: hintKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          StudioNote(
            theme: t,
            text: '自上而下判断：第一个条件成立的块生效（无条件块＝轮到它必定触发）；'
                '同一块里写多个目的地是等概率随机取一个。'
                '最后一块建议不写条件当保底；一块都不成立时玩家会看到「暂时不能进入下一阶段噢」。',
          ),
          if (blocks.isEmpty) StudioNote(theme: t, text: emptyNote, color: t.accent),
          const SizedBox(height: 4),
          for (var i = 0; i < blocks.length; i++) _block(i),
          const SizedBox(height: 2),
          OutlinedButton.icon(
            onPressed: () => onChanged(<TargetBlockModel>[
              ...blocks,
              TargetBlockModel(
                kinds: <TargetKindModel>[
                  TargetKindModel(
                    kind: 'story',
                    to: storyIds.isEmpty ? '' : storyIds.first,
                  ),
                ],
              ),
            ]),
            icon: Icon(Icons.add_rounded, size: 18, color: t.accent),
            label: Text(
              '添加出口块',
              style: TextStyle(color: t.accent, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  void _move(int i, int delta) {
    final next = <TargetBlockModel>[...blocks];
    final j = i + delta;
    if (j < 0 || j >= next.length) return;
    final tmp = next[i];
    next[i] = next[j];
    next[j] = tmp;
    onChanged(next);
  }

  void _remove(int i) {
    final next = <TargetBlockModel>[...blocks]..removeAt(i);
    onChanged(next);
  }

  Widget _block(int i) {
    final t = theme;
    final b = blocks[i];
    final err = requireExprError(b.requireCtrl.text, knownVariables);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
      decoration: BoxDecoration(
        color: t.bg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: t.sub.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '出口块 ${i + 1}',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: t.ink,
                ),
              ),
              const SizedBox(width: 6),
              if (b.isFallback) StudioTag(theme: t, text: '无条件'),
              const Spacer(),
              _iconBtn(
                Icons.arrow_upward_rounded,
                '上移',
                i == 0 ? null : () => _move(i, -1),
              ),
              _iconBtn(
                Icons.arrow_downward_rounded,
                '下移',
                i == blocks.length - 1 ? null : () => _move(i, 1),
              ),
              _iconBtn(
                Icons.delete_outline_rounded,
                '删除这一块',
                () => _remove(i),
              ),
            ],
          ),
          HintLabel(
            theme: t,
            title: '条件 require（留空＝无条件成立）',
            hintKey: 'target.require',
          ),
          RequireEditor(
            key: ValueKey('require_editor_${b.id}'),
            theme: t,
            controller: b.requireCtrl,
            knownVariables: knownVariables,
            errorText: err,
            onChanged: () => onChanged(<TargetBlockModel>[...blocks]),
          ),
          const SizedBox(height: 6),
          HintLabel(
            theme: t,
            title: '目的地（去哪）',
            hintKey: 'target.kind',
          ),
          if (b.kinds.isEmpty)
            StudioNote(
              theme: t,
              text: '这一块没有目的地：体检会报错，加一个或删掉整块。',
              color: Colors.red,
            ),
          for (var k = 0; k < b.kinds.length; k++) _kindRow(i, k),
          TextButton.icon(
            onPressed: () {
              b.kinds.add(
                TargetKindModel(
                  kind: 'story',
                  to: storyIds.isEmpty ? '' : storyIds.first,
                ),
              );
              onChanged(<TargetBlockModel>[...blocks]);
            },
            icon: Icon(Icons.add_rounded, size: 16, color: t.accent),
            label: Text(
              '再加一个目的地（重复选同一个＝它的概率翻倍）',
              style: TextStyle(color: t.accent, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _kindRow(int bi, int ki) {
    final t = theme;
    final b = blocks[bi];
    final k = b.kinds[ki];
    final toOptions = _toOptions(k.kind, k.to);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          StudioDropdown<String>(
            theme: t,
            width: 132,
            value: k.kind,
            options: _kindOptions,
            onChanged: (v) {
              if (v == null) return;
              k.kind = v;
              k.to = v == 'appShell'
                  ? 'home'
                  : (v == 'event'
                      ? (eventIds.isEmpty ? '' : eventIds.first)
                      : (storyIds.isEmpty ? '' : storyIds.first));
              onChanged(<TargetBlockModel>[...blocks]);
            },
          ),
          const SizedBox(width: 6),
          Expanded(
            child: k.kind == 'appShell'
                ? Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 9,
                    ),
                    decoration: BoxDecoration(
                      color: t.bg,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: t.sub.withValues(alpha: 0.25)),
                    ),
                    child: Text(
                      'home（固定：回主页）',
                      style: TextStyle(fontSize: 13, color: t.sub),
                    ),
                  )
                : StudioDropdown<String>(
                    theme: t,
                    value: k.to.isEmpty ? null : k.to,
                    options: toOptions,
                    placeholder: k.kind == 'event' ? '选一个事件' : '选一个情景',
                    onChanged: (v) {
                      k.to = v ?? '';
                      onChanged(<TargetBlockModel>[...blocks]);
                    },
                  ),
          ),
          IconButton(
            tooltip: '删除这个目的地',
            onPressed: () {
              b.kinds.removeAt(ki);
              onChanged(<TargetBlockModel>[...blocks]);
            },
            icon: const Icon(Icons.close_rounded, size: 16),
            color: t.sub,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
          ),
        ],
      ),
    );
  }

  List<(String, String)> _toOptions(String kind, String current) {
    switch (kind) {
      case 'event':
        return <(String, String)>[for (final e in eventIds) (e, e)];
      case 'appShell':
        return const <(String, String)>[('home', 'home')];
      case 'story':
      default:
        final list = <(String, String)>[for (final s in storyIds) (s, s)];
        if (list.isEmpty) {
          return <(String, String)>[
            if (current.isNotEmpty) (current, current),
            ('', '还没有其它情景：先去「情景」页新建'),
          ];
        }
        return list;
    }
  }

  Widget _iconBtn(IconData icon, String tip, VoidCallback? onTap) {
    return IconButton(
      tooltip: tip,
      onPressed: onTap,
      icon: Icon(icon, size: 17),
      color: theme.sub,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
    );
  }
}

// ===========================================================================
//  情景编辑器
// ===========================================================================

/// 出场角色一行。
class _ActorRow {
  _ActorRow({
    required this.charId,
    required this.state,
    required this.emotion,
    required String scenePrompt,
  }) : scenePromptCtrl = TextEditingController(text: scenePrompt);

  String charId;
  String state;
  String emotion;
  final TextEditingController scenePromptCtrl;

  void dispose() => scenePromptCtrl.dispose();
}

/// 入场改值一行：`{ "id": "day", "value": 1 }`。
class _EffectRow {
  _EffectRow({required this.id, required String value})
      : valueCtrl = TextEditingController(text: value);

  String id;
  final TextEditingController valueCtrl;

  void dispose() => valueCtrl.dispose();
}

/// 情景（一幕）编辑器：`stories/<情景id>.json`。
class SceneEditor extends StatefulWidget {
  const SceneEditor({
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

  /// 脏状态上报：编辑器有未保存修改时通知父级，用于跨页签保护。
  final ValueChanged<bool>? onDirtyChanged;

  @override
  State<SceneEditor> createState() => _SceneEditorState();
}

class _SceneEditorState extends State<SceneEditor> {
  ChatGalTheme get _t => widget.theme;

  List<String> _ids = <String>[];
  String? _selected;

  Map<String, Object?> _raw = <String, Object?>{};

  // ---- 本幕表单
  TextEditingController? _displayName;
  TextEditingController? _narration;
  TextEditingController? _atmosphere;

  String _background = '';
  List<String> _backgrounds = <String>[];
  List<_ActorRow> _actors = <_ActorRow>[];
  List<_EffectRow> _effects = <_EffectRow>[];
  List<SettlementVarModel> _settlement = <SettlementVarModel>[];
  List<TargetBlockModel> _targets = <TargetBlockModel>[];

  // ---- 可选项来源
  List<String> _characters = <String>[];
  Map<String, List<String>> _charStates = <String, List<String>>{};
  Map<String, List<String>> _charEmotions = <String, List<String>>{};
  Map<String, Set<String>> _charPortraits = <String, Set<String>>{};
  List<String> _variables = <String>[];
  Map<String, String> _variableTypes = <String, String>{};
  List<String> _eventIds = <String>[];

  bool _busy = false;

  /// 上次加载/保存时的表单快照：用来判断有没有未保存修改。
  String _savedSignature = '';

  Set<String> get _knownVars => _variables.toSet();
  List<String> get _numericVars => <String>[
        for (final v in _variables)
          if (_variableTypes[v] == 'int' || _variableTypes[v] == 'number') v,
      ];

  /// 当前表单状态的签名（用于脏检测）。
  String _formSignature() {
    final parts = <String>[
      _displayName?.text ?? '',
      _narration?.text ?? '',
      _atmosphere?.text ?? '',
      _background,
      for (final a in _actors)
        '${a.charId}|${a.state}|${a.emotion}|${a.scenePromptCtrl.text}',
      for (final e in _effects) '${e.id}|${e.valueCtrl.text}',
      for (final s in _settlement)
        '${s.varId}|${s.promptCtrl.text}|${s.maxCtrl.text}|${s.onNoEvidence}',
      for (final b in _targets) b.signature(),
    ];
    return parts.join(';;');
  }

  bool get _dirty => _formSignature() != _savedSignature;

  bool _lastReportedDirty = false;

  /// 统一脏状态上报：文本变化、结构变化、保存后都走这里。
  void _reportDirty() {
    if (!mounted) return;
    final d = _dirty;
    if (d != _lastReportedDirty) {
      _lastReportedDirty = d;
      widget.onDirtyChanged?.call(d);
    }
  }

  /// 给文本控制器挂监听：任何文字编辑都会触发脏状态上报。
  void _attachDirtyListeners() {
    void listen(TextEditingController? c) {
      c?.removeListener(_reportDirty);
      c?.addListener(_reportDirty);
    }

    listen(_displayName);
    listen(_narration);
    listen(_atmosphere);
    for (final a in _actors) {
      listen(a.scenePromptCtrl);
    }
    for (final e in _effects) {
      listen(e.valueCtrl);
    }
    for (final s in _settlement) {
      listen(s.promptCtrl);
      listen(s.maxCtrl);
    }
    for (final b in _targets) {
      listen(b.requireCtrl);
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _disposeScene();
    for (final b in _targets) {
      b.dispose();
    }
    super.dispose();
  }

  void _disposeScene() {
    _displayName?.dispose();
    _narration?.dispose();
    _atmosphere?.dispose();
    for (final b in _settlement) {
      b.dispose();
    }
    for (final a in _actors) {
      a.dispose();
    }
    for (final e in _effects) {
      e.dispose();
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---------------------------------------------------------------- 读取

  void _load() {
    final store = widget.services.studio;
    final slug = widget.slug;

    _ids = _sceneIds(store, slug);
    if (_ids.isEmpty) {
      _selected = null;
    } else if (_selected == null || !_ids.contains(_selected)) {
      _selected = _ids.contains('start') ? 'start' : _ids.first;
    }

    _characters = store.listDirs(slug, 'characters');
    _charStates = <String, List<String>>{};
    _charEmotions = <String, List<String>>{};
    _charPortraits = <String, Set<String>>{};
    for (final id in _characters) {
      final j = store.readJson(slug, 'characters/$id/character.json');
      _charStates[id] = _dedupe(_strList(j?['states']));
      _charEmotions[id] = _dedupe(_strList(j?['emotions']));
      _charPortraits[id] = <String>{
        for (final f in store.listFiles(slug, 'characters/$id'))
          if (isStudioImage(f)) f.toLowerCase(),
      };
    }

    final manifest = store.readJson(slug, 'manifest.json') ?? <String, Object?>{};
    _variables = <String>[];
    _variableTypes = <String, String>{};
    final rawVars = manifest['variables'];
    if (rawVars is List) {
      for (final v in rawVars) {
        if (v is! Map) continue;
        final m = Map<String, Object?>.from(v);
        final id = '${m['id'] ?? ''}'.trim();
        if (id.isEmpty || _variableTypes.containsKey(id)) continue;
        _variables.add(id);
        _variableTypes[id] = '${m['type'] ?? 'int'}';
      }
    }

    _backgrounds = <String>[
      for (final f in store.listFiles(slug, 'stories'))
        if (isStudioImage(f)) f,
    ];
    _eventIds = store.listDirs(slug, 'events');

    _loadScene();
  }

  void _loadScene() {
    _disposeScene();
    for (final b in _targets) {
      b.dispose();
    }

    final id = _selected;
    _raw = id == null
        ? <String, Object?>{}
        : (widget.services.studio.readJson(widget.slug, 'stories/$id.json') ??
            <String, Object?>{});

    _displayName = TextEditingController(text: '${_raw['displayName'] ?? ''}');
    _narration = TextEditingController(text: '${_raw['narration'] ?? ''}');
    _atmosphere = TextEditingController(text: '${_raw['atmosphere'] ?? ''}');
    _background = '${_raw['background'] ?? ''}';
    _settlement = settlementVarsFromJson(_raw['settlement']);

    _actors = <_ActorRow>[];
    final rawActors = _raw['characters'];
    if (rawActors is List) {
      for (final a in rawActors) {
        if (a is! Map) continue;
        final m = Map<String, Object?>.from(a);
        _actors.add(
          _ActorRow(
            charId: '${m['charId'] ?? ''}',
            state: '${m['state'] ?? ''}',
            emotion: '${m['emotion'] ?? ''}',
            scenePrompt: '${m['scenePrompt'] ?? ''}',
          ),
        );
      }
    }

    _effects = <_EffectRow>[];
    final rawFx = _raw['fixedEffects'];
    if (rawFx is List) {
      for (final f in rawFx) {
        if (f is! Map) continue;
        final m = Map<String, Object?>.from(f);
        _effects.add(
          _EffectRow(id: '${m['id'] ?? ''}', value: '${m['value'] ?? ''}'),
        );
      }
    }

    _targets = targetBlocksFromJson(_raw['target']);
    // 加载完成后记录快照并挂监听：之后任何文字/结构变化都会触发脏状态上报。
    _savedSignature = _formSignature();
    _lastReportedDirty = false;
    _attachDirtyListeners();
    widget.onDirtyChanged?.call(false);
  }

  /// 入口 start 放最前面，其余字母序。
  List<String> _sceneIds(StudioStore store, String slug) {
    final out = sceneIdsOf(store, slug);
    out.sort((a, b) {
      if (a == 'start') return -1;
      if (b == 'start') return 1;
      return a.compareTo(b);
    });
    return out;
  }

  // ---------------------------------------------------------------- 选择

  Future<void> _selectScene(String id) async {
    if (id == _selected) return;
    // 草稿保护：有未保存修改时先问作者，不要静默丢掉。
    if (_dirty) {
      final ok = await confirmDiscardDraft(
        context,
        _t,
        what: '情景「$_selected」',
        onSave: () async {
          await _save();
          return !_dirty;
        },
      );
      if (!ok || !mounted) return;
    }
    setState(() {
      _selected = id;
      _loadScene();
    });
  }

  // ---------------------------------------------------------------- 写盘

  void _setTargets(List<TargetBlockModel> next) {
    for (final b in _targets) {
      if (!next.contains(b)) b.dispose();
    }
    setState(() => _targets = next);
  }

  String? _validate() {
    final dn = _displayName?.text.trim() ?? '';
    if (dn.isEmpty) return '情景展示名不能为空（体检会报错）';
    for (final a in _actors) {
      if (a.charId.trim().isEmpty) return '有一条出场角色没选角色';
      if (a.state.isNotEmpty &&
          !(_charStates[a.charId] ?? const <String>[]).contains(a.state)) {
        return '出场角色的状态「${a.state}」不在 ${a.charId} 声明的状态里';
      }
      if (a.emotion.isNotEmpty &&
          !(_charEmotions[a.charId] ?? const <String>[])
              .contains(a.emotion)) {
        return '出场角色的情绪「${a.emotion}」不在 ${a.charId} 声明的情绪里';
      }
    }
    for (final e in _effects) {
      if (e.id.trim().isEmpty) return '有一条入场改值没选变量';
      final v = num.tryParse(e.valueCtrl.text.trim());
      if (v == null) return '入场改值「${e.id}」的数值不是数字';
      if (v == 0) return '入场改值「${e.id}」的数值是 0：什么也不做，请删掉它';
    }
    final settled = settlementVarsError(_settlement);
    if (settled != null) return settled;
    return targetBlocksError(
      _targets,
      knownVariables: _knownVars,
      storyIds: _ids,
      eventIds: _eventIds,
    );
  }

  Future<void> _save() async {
    if (_busy) return;
    final id = _selected;
    if (id == null) return;
    final err = _validate();
    if (err != null) {
      _toast(err);
      return;
    }
    setState(() => _busy = true);
    try {
      final out = <String, Object?>{..._raw};
      out['displayName'] = _displayName!.text.trim();

      final bg = _background.trim();
      if (bg.isEmpty) {
        out.remove('background');
      } else {
        out['background'] = bg;
      }

      final narration = _narration!.text.trim();
      if (narration.isEmpty) {
        out.remove('narration');
      } else {
        out['narration'] = narration;
      }

      final atmosphere = _atmosphere!.text.trim();
      if (atmosphere.isEmpty) {
        out.remove('atmosphere');
      } else {
        out['atmosphere'] = atmosphere;
      }

      out['characters'] = <Map<String, Object?>>[
        for (final a in _actors)
          <String, Object?>{
            'charId': a.charId.trim(),
            if (a.state.trim().isNotEmpty) 'state': a.state.trim(),
            if (a.emotion.trim().isNotEmpty) 'emotion': a.emotion.trim(),
            'scenePrompt': a.scenePromptCtrl.text.trim(),
          },
      ];

      out['fixedEffects'] = <Map<String, Object?>>[
        for (final e in _effects)
          <String, Object?>{'id': e.id.trim(), 'value': _numOf(e.valueCtrl.text)},
      ];

      final settled = settlementVarsToJson(_settlement);
      if (settled.isEmpty) {
        out.remove('settlement');
      } else {
        out['settlement'] = settled;
      }

      out['target'] = targetBlocksToJson(_targets);

      // 写盘异步：先固定这一份的签名，避免保存期间继续输入被误标成已保存。
      final savedSignature = _formSignature();
      await widget.services.studio
          .writeJson(widget.slug, 'stories/$id.json', out);
      if (!mounted) return;
      _raw = out;
      _savedSignature = savedSignature;
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

  Future<void> _newScene() async {
    final spec = await showDialog<_NewSceneSpec>(
      context: context,
      builder: (_) => _NewSceneDialog(
        theme: _t,
        existingIds: _ids,
        displayNameOf: (id) =>
            '${widget.services.studio.readJson(widget.slug, 'stories/$id.json')?['displayName'] ?? id}',
      ),
    );
    if (spec == null || !mounted) return;
    if (_busy) return;
    final name = spec.name;
    setState(() => _busy = true);
    try {
      // 选「复制自某一幕」时整套内容搬过来（含它的出口）；否则只写最小骨架。
      final copied = spec.sourceId == null
          ? null
          : widget.services.studio.readJson(
              widget.slug,
              'stories/${spec.sourceId}.json',
            );
      await widget.services.studio.writeJson(widget.slug, 'stories/$name.json',
          copied ??
              <String, Object?>{
                'displayName': name,
                'characters': <Object?>[],
                'fixedEffects': <Object?>[],
                'target': <Object?>[],
              });
      if (!mounted) return;
      setState(() {
        _ids = _sceneIds(widget.services.studio, widget.slug);
        _selected = name;
        _loadScene();
      });
      _toast(spec.sourceId == null
          ? '已新建情景「$name」'
          : '已从「${spec.sourceId}」复制出「$name」');
    } catch (e) {
      _toast('新建失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteScene() async {
    final id = _selected;
    if (id == null) return;
    if (id == 'start') {
      _toast('start 是游戏入口，不能删除');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _t.card,
        title: Text('删除情景「$id」？', style: TextStyle(color: _t.ink)),
        content: Text(
          '会删掉 stories/$id.json。指向它的出口会变成「情景不存在」（体检会报 error）。',
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
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.services.studio.deletePath(widget.slug, 'stories/$id.json');
      if (!mounted) return;
      setState(() {
        _selected = null;
        _load();
      });
      widget.onSaved?.call();
      _toast('已删除情景「$id」');
    } catch (e) {
      _toast('删除失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------------------------------------------------------------- 背景图

  Future<void> _importBackground() async {
    if (_busy) return;
    final picked = await pickStudioImages(dialogTitle: '选择背景图');
    if (picked.isEmpty || !mounted) return;
    final file = picked.first;
    final name = sanitizeStudioFileName(file.name);
    final overwrite = _backgrounds.contains(name);
    if (overwrite) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: _t.card,
          title: Text('覆盖同名背景图？', style: TextStyle(color: _t.ink)),
          content: Text(
            'stories/$name 已存在，导入会覆盖它（所有用到这张图的幕都会跟着变）。',
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
      await widget.services.studio.writeBytes(widget.slug, 'stories/$name', bytes);
      if (!mounted) return;
      setState(() {
        _backgrounds = <String>[
          for (final f in widget.services.studio.listFiles(widget.slug, 'stories'))
            if (isStudioImage(f)) f,
        ];
        _background = name;
      });
      // 同路径覆盖后 FileImage 不 evict 会仍旧图
      try {
        await FileImage(
          File(widget.services.studio.absPathOf(widget.slug, 'stories/$name')),
        ).evict();
      } catch (_) {}
      if (!mounted) return;
      setState(() {});
      _toast('已导入背景图 $name，并选中');
    } catch (e) {
      _toast('导入失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------------------------------------------------------------- 生成模板

  /// 一个变量的判定模板：直接写清「可能的方向 + 无证据给 0」。
  /// 占位符 <她> 让作者改成角色名后就是一句能用的判定说明。
  String _judgeTemplateFor(String varId) =>
      '本幕里她是否在「$varId」上有所变化？有明确证据才给正数（+1/+2），'
      '出现反向表现就给负数，看不出来就给 0。只按本幕对话与摘要判断，不要脑补。';

  // ---------------------------------------------------------------- 界面

  @override
  Widget build(BuildContext context) {
    // 任何 setState 引发的重建都会走到这里：帧结束后检查脏状态并上报。
    // 覆盖「加/删条目」「改下拉框」「保存后刷新」等非文本路径。
    WidgetsBinding.instance.addPostFrameCallback((_) => _reportDirty());
    final t = _t;
    if (_ids.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Spacing.lg),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.movie_filter_outlined, size: 40, color: t.sub),
              const SizedBox(height: 12),
              Text(
                '这个工程还没有任何情景',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: t.ink),
              ),
              const SizedBox(height: 6),
              Text(
                '情景 = 一幕：游戏从 start 开始，之后按每幕的出口一幕幕走下去。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, height: 1.6, color: t.sub),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: t.accent,
                  foregroundColor: Colors.white,
                ),
                onPressed: _busy ? null : _newScene,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('新建情景'),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        _sceneBar(),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 28),
            children: [
              _basicSection(),
              _actorsSection(),
              _effectsSection(),
              _settlementSection(),
              TargetBlocksEditor(
                theme: t,
                blocks: _targets,
                onChanged: _setTargets,
                knownVariables: _knownVars,
                storyIds: _ids,
                eventIds: _eventIds,
              ),
              _saveButton(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _sceneBar() {
    final t = _t;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      decoration: BoxDecoration(
        color: t.card,
        border: Border(
          bottom: BorderSide(color: t.sub.withValues(alpha: 0.15)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '情景（共 ${_ids.length} 幕）',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: t.ink),
              ),
              const SizedBox(width: 4),
              HintDot(theme: t, hintKey: 'scene.list'),
              const Spacer(),
              TextButton.icon(
                onPressed: _busy ? null : _newScene,
                icon: Icon(Icons.add_rounded, size: 17, color: t.accent),
                label: Text('新建', style: TextStyle(color: t.accent, fontSize: 12.5)),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                ),
              ),
              TextButton.icon(
                onPressed: _busy ? null : _deleteScene,
                icon: const Icon(Icons.delete_outline_rounded, size: 17, color: Colors.red),
                label: const Text('删除本幕', style: TextStyle(color: Colors.red, fontSize: 12.5)),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                ),
              ),
            ],
          ),
          StudioIdSelector(
            theme: t,
            ids: _ids,
            selected: _selected,
            labelOf: (id) => id == 'start' ? '$id · 入口' : id,
            onSelect: _selectScene,
          ),
        ],
      ),
    );
  }

  Widget _basicSection() {
    final t = _t;
    final id = _selected ?? '';
    return StudioSection(
      theme: t,
      title: '本幕：$id',
      hintKey: 'scene.list',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HintLabel(
            theme: t,
            title: '展示名 displayName',
            hintKey: 'scene.displayName',
            required: true,
          ),
          TextField(
            controller: _displayName,
            style: TextStyle(fontSize: 13.5, color: t.ink),
            decoration: const InputDecoration(hintText: '例：白天·学校'),
          ),
          const SizedBox(height: 12),
          HintLabel(
            theme: t,
            title: '背景图 background',
            hintKey: 'scene.background',
          ),
          StudioImagePicker(
            theme: t,
            names: _backgrounds,
            selected: _background,
            allowEmpty: true,
            emptyLabel: '（留空：显示主题色）',
            // 左候选约三张高，右预览与之等高（previewHeight 传 null 即用默认）
            fileOf: (name) => File(
              widget.services.studio.absPathOf(widget.slug, 'stories/$name'),
            ),
            onSelect: (v) => setState(() => _background = v),
            onImport: _busy ? null : _importBackground,
          ),
          const SizedBox(height: 12),
          HintLabel(
            theme: t,
            title: '入场词 narration',
            hintKey: 'scene.narration',
          ),
          TextField(
            controller: _narration,
            minLines: 4,
            maxLines: 10,
            style: TextStyle(fontSize: 13.5, color: t.ink),
            decoration: const InputDecoration(hintText: '进入这一幕时显示在对话流顶部的场景叙述'),
          ),
          const SizedBox(height: 12),
          HintLabel(
            theme: t,
            title: '转场气氛 atmosphere（可留空）',
            hintKey: 'scene.atmosphere',
          ),
          TextField(
            controller: _atmosphere,
            minLines: 1,
            maxLines: 3,
            style: TextStyle(fontSize: 13.5, color: t.ink),
            decoration: const InputDecoration(hintText: '例：雨点敲打着出租屋的窗户，屋里格外安静。'),
          ),
        ],
      ),
    );
  }

  Widget _actorsSection() {
    final t = _t;
    return StudioSection(
      theme: t,
      title: '出场角色',
      hintKey: 'scene.characters',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          StudioNote(
            theme: t,
            text: _characters.isEmpty
                ? '还没有角色：先去「角色」页新建一个角色，这里才有得选。'
                : '一个情景只放**一位**出场角色（要换人就删掉再加）。'
                    '不写进这里的角色 = 不在场：他看不到这一幕的对话，也不会记住它。',
            color: _characters.isEmpty ? t.accent : null,
            icon: _characters.isEmpty ? Icons.info_outline_rounded : null,
          ),
          const SizedBox(height: 4),
          for (var i = 0; i < _actors.length; i++) _actorCard(i),
          // 一个情景只允许一位出场角色：已经有就不用再给了。
          if (_actors.isEmpty)
            OutlinedButton.icon(
              onPressed: _characters.isEmpty
                  ? null
                  : () {
                      setState(() {
                        final first = _characters.first;
                        _actors.add(
                          _ActorRow(
                            charId: first,
                            state: _charStates[first]?.isNotEmpty == true
                                ? _charStates[first]!.first
                                : '',
                            emotion: _charEmotions[first]?.isNotEmpty == true
                                ? _charEmotions[first]!.first
                                : '',
                            scenePrompt: '',
                          ),
                        );
                      });
                    },
              icon: Icon(Icons.add_rounded, size: 18, color: t.accent),
              label: Text('添加出场角色', style: TextStyle(color: t.accent, fontSize: 13)),
            ),
        ],
      ),
    );
  }

  Widget _actorCard(int i) {
    final t = _t;
    final a = _actors[i];
    final states = _charStates[a.charId] ?? const <String>[];
    final emotions = _charEmotions[a.charId] ?? const <String>[];
    final portraitKey = (a.state.isEmpty || a.emotion.isEmpty)
        ? ''
        : '${a.state}_${a.emotion}.png';
    final missing = portraitKey.isNotEmpty &&
        !(_charPortraits[a.charId] ?? const <String>{})
            .contains(portraitKey.toLowerCase());
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      decoration: BoxDecoration(
        color: t.bg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: t.sub.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              StudioTag(theme: t, text: '角色 ${i + 1}'),
              const Spacer(),
              IconButton(
                tooltip: '移除这个出场角色',
                onPressed: () => setState(() => _actors.removeAt(i).dispose()),
                icon: const Icon(Icons.close_rounded, size: 16),
                color: t.sub,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Text('角色', style: TextStyle(fontSize: 11.5, color: t.sub)),
              const SizedBox(width: 6),
              Expanded(
                child: StudioDropdown<String>(
                  theme: t,
                  value: a.charId.isEmpty ? null : a.charId,
                  options: <(String, String)>[for (final c in _characters) (c, c)],
                  placeholder: '选一个角色',
                  onChanged: (v) => setState(() {
                    a.charId = v ?? '';
                    a.state = _charStates[a.charId]?.isNotEmpty == true
                        ? _charStates[a.charId]!.first
                        : '';
                    a.emotion = _charEmotions[a.charId]?.isNotEmpty == true
                        ? _charEmotions[a.charId]!.first
                        : '';
                  }),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Text('状态', style: TextStyle(fontSize: 11.5, color: t.sub)),
              const SizedBox(width: 6),
              Expanded(
                child: StudioDropdown<String>(
                  theme: t,
                  value: a.state.isEmpty ? null : a.state,
                  options: <(String, String)>[for (final s in states) (s, s)],
                  placeholder: states.isEmpty ? '角色没声明状态' : '选状态',
                  onChanged: (v) => setState(() => a.state = v ?? ''),
                ),
              ),
              const SizedBox(width: 8),
              Text('情绪', style: TextStyle(fontSize: 11.5, color: t.sub)),
              const SizedBox(width: 6),
              Expanded(
                child: StudioDropdown<String>(
                  theme: t,
                  value: a.emotion.isEmpty ? null : a.emotion,
                  options: <(String, String)>[for (final e in emotions) (e, e)],
                  placeholder: emotions.isEmpty ? '角色没声明情绪' : '选情绪',
                  onChanged: (v) => setState(() => a.emotion = v ?? ''),
                ),
              ),
            ],
          ),
          if (missing)
            StudioNote(
              theme: t,
              text: '缺立绘 characters/${a.charId}/$portraitKey：'
                  '去「角色」页的立绘矩阵导入（模型选到这张会落占位图）。',
              color: Colors.red,
              icon: Icons.error_outline_rounded,
            ),
          if (a.charId.isEmpty)
            StudioNote(theme: t, text: '还没选角色（体检会报 charId 为空）', color: Colors.red),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                '本幕提示词 scenePrompt',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: t.ink),
              ),
              const SizedBox(width: 4),
              HintDot(theme: t, hintKey: 'scene.scenePrompt'),
            ],
          ),
          const SizedBox(height: 6),
          TextField(
            controller: a.scenePromptCtrl,
            minLines: 4,
            maxLines: 12,
            style: TextStyle(fontSize: 13, color: t.ink),
            decoration: const InputDecoration(
              hintText: '例：本幕：第 1 天白天，地点：学校。本幕推进【开学首日】：……',
            ),
          ),
        ],
      ),
    );
  }

  /// 这一幕看起来是「新一天的第一幕」：`dayN_1`（N≥2）或无尽头里的 `_day` 那一幕。
  ///
  /// `start`（= 第 1 天）不算：它是游戏的第一幕，day 默认就是 1。
  bool get _looksLikeNewDayFirstScene {
    final id = _selected ?? '';
    if (id.isEmpty || id == 'start') return false;
    final m = RegExp(r'^day(\d+)_1$').firstMatch(id);
    if (m != null) return (int.tryParse(m.group(1)!) ?? 1) >= 2;
    return id.endsWith('_day');
  }

  bool get _hasDayPlusOne => _effects.any(
        (e) => e.id == 'day' && (num.tryParse(e.valueCtrl.text.trim()) ?? 0) == 1,
      );

  Widget _effectsSection() {
    final t = _t;
    final numeric = _numericVars;
    final needsAttention = _looksLikeNewDayFirstScene && !_hasDayPlusOne;
    final section = StudioSection(
      theme: t,
      title: '入场改值 fixedEffects',
      hintKey: 'scene.fixedEffects',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_selected == 'start')
            StudioNote(
              theme: t,
              text: 'start 是第 1 天（游戏从这一幕开始），不要在这里加 day +1。',
              color: t.sub,
              icon: Icons.info_outline_rounded,
            )
          else if (_looksLikeNewDayFirstScene)
            StudioNote(
              theme: t,
              text: _hasDayPlusOne
                  ? '已设置 day +1 ✓ —— 这一幕是新一天的第一幕。'
                  : '这一幕看起来是「新一天的第一幕」：通常要在这里加 day +1，'
                      '否则天数不会往前走（后面按 day 判断的出口会一直命中同一个分支）。',
              color: _hasDayPlusOne ? Colors.green.shade700 : Colors.orange.shade900,
              icon: _hasDayPlusOne
                  ? Icons.check_circle_outline_rounded
                  : Icons.warning_amber_rounded,
            ),
          if (numeric.isEmpty)
            StudioNote(
              theme: t,
              text: '还没有注册数值变量：先去「基础信息」注册（例如 day、戒戒好感）。',
              color: t.accent,
            ),
          for (var i = 0; i < _effects.length; i++) _effectRow(i),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: numeric.isEmpty
                    ? null
                    : () => setState(
                          () => _effects.add(_EffectRow(id: numeric.first, value: '1')),
                        ),
                icon: Icon(Icons.add_rounded, size: 18, color: t.accent),
                label: Text('添加一项', style: TextStyle(color: t.accent, fontSize: 13)),
              ),
              const SizedBox(width: 8),
              if (numeric.contains('day'))
                OutlinedButton.icon(
                  onPressed: _quickDayPlusOne,
                  style: needsAttention
                      ? OutlinedButton.styleFrom(
                          backgroundColor: Colors.orange.withValues(alpha: 0.16),
                          side: BorderSide(
                            color: Colors.orange.withValues(alpha: 0.8),
                          ),
                        )
                      : null,
                  icon: Icon(
                    Icons.fast_forward_rounded,
                    size: 18,
                    color: needsAttention ? Colors.orange.shade900 : t.accent,
                  ),
                  label: Text(
                    'day +1',
                    style: TextStyle(
                      color: needsAttention ? Colors.orange.shade900 : t.accent,
                      fontSize: 13,
                      fontWeight: needsAttention ? FontWeight.w700 : null,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
    if (!needsAttention) return section;
    // 整块标黄：这是最容易漏、后果最直接的一处（漏了天数就不走）。
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: Colors.orange.withValues(alpha: 0.8),
          width: 1.5,
        ),
        color: Colors.orange.withValues(alpha: 0.07),
      ),
      child: section,
    );
  }

  void _quickDayPlusOne() {
    setState(() {
      final existing = _effects
          .where((e) => e.id == 'day')
          .fold<_EffectRow?>(null, (_, e) => e);
      if (existing != null) {
        final cur = num.tryParse(existing.valueCtrl.text.trim()) ?? 0;
        existing.valueCtrl.text = '${cur + 1}';
      } else {
        _effects.add(_EffectRow(id: 'day', value: '1'));
      }
    });
    _toast('已在入场改值里加上 day +1');
  }

  Widget _effectRow(int i) {
    final t = _t;
    final e = _effects[i];
    final options = <(String, String)>[for (final v in _numericVars) (v, v)];
    final value = num.tryParse(e.valueCtrl.text.trim());
    final bad = e.valueCtrl.text.trim().isNotEmpty && value == null;
    final zero = value == 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                flex: 3,
                child: StudioDropdown<String>(
                  theme: t,
                  value: e.id.isEmpty ? null : e.id,
                  options: options,
                  placeholder: '选数值变量',
                  onChanged: (v) => setState(() => e.id = v ?? ''),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 84,
                child: TextField(
                  controller: e.valueCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                    signed: true,
                    decimal: true,
                  ),
                  style: TextStyle(fontSize: 13, color: t.ink),
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: '+1',
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              IconButton(
                tooltip: '删除这一项',
                onPressed: () => setState(() => _effects.removeAt(i).dispose()),
                icon: const Icon(Icons.close_rounded, size: 16),
                color: t.sub,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
              ),
            ],
          ),
          if (bad || zero)
            StudioNote(
              theme: t,
              text: bad
                  ? '这里要填数字（正数为加、负数为减）'
                  : '0 什么也不做：删掉这一项，或者改成别的数',
              color: Colors.red,
            ),
        ],
      ),
    );
  }

  Widget _settlementSection() {
    final t = _t;
    final numeric = _numericVars;
    final used = <String>{for (final b in _settlement) b.varId};
    final free = <String>[for (final v in numeric) if (!used.contains(v)) v];
    return StudioSection(
      theme: t,
      title: '离场结算（每个变量一个块）',
      hintKey: 'scene.settlement',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          StudioNote(
            theme: t,
            text: _settlement.isEmpty
                ? '本幕不结算（大多数日常幕都该这样）。要给某个变量加减，就在下面加一个块。'
                : '本幕会给 ${_settlement.length} 个变量结算：玩家点「下一阶段」时，'
                    '模型按每个块自己的说明给整数增量，并按各自的单次上限收口。',
            color: _settlement.isEmpty ? null : t.accent,
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < _settlement.length; i++) _settlementCard(i),
          const SizedBox(height: 2),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: numeric.isEmpty || free.isEmpty
                    ? null
                    : () => setState(() {
                          _settlement.add(SettlementVarModel(varId: free.first));
                        }),
                icon: Icon(Icons.add_rounded, size: 16, color: t.accent),
                label: Text(
                  '添加受控变量',
                  style: TextStyle(fontSize: 12.5, color: t.accent),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  numeric.isEmpty
                      ? '还没有注册数值变量：先去「基础信息」注册（例如「戒戒好感」）。'
                      : (free.isEmpty ? '所有数值变量都已经在结算里了。' : '没选过的变量：${free.join('、')}'),
                  style: TextStyle(fontSize: 11, height: 1.4, color: t.sub),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 一个受控变量块：变量 + 判定提示词 + 单次上限 + 无证据策略。
  ///
  /// 「单次上限」与「无证据时」**各占整行**：早先并排放在两个半宽列里，
  /// 标签在窄屏上会被挤到溢出。
  Widget _settlementCard(int i) {
    final t = _t;
    final b = _settlement[i];
    final numeric = _numericVars;
    final options = <(String, String)>[
      for (final v in numeric) (v, v),
      if (b.varId.isNotEmpty && !numeric.contains(b.varId))
        (b.varId, '${b.varId}（未注册或非数值）'),
    ];
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
      decoration: BoxDecoration(
        color: t.bg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: b.varId.isEmpty
              ? Colors.red.withValues(alpha: 0.5)
              : t.sub.withValues(alpha: 0.18),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              StudioTag(theme: t, text: '受控变量 ${i + 1}'),
              const Spacer(),
              IconButton(
                tooltip: '删掉这个结算块',
                onPressed: () => setState(() => _settlement.removeAt(i).dispose()),
                icon: const Icon(Icons.delete_outline_rounded, size: 17),
                color: t.sub,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              ),
            ],
          ),
          SizedBox(
            width: 168,
            child: StudioDropdown<String>(
              theme: t,
              value: b.varId.isEmpty ? null : b.varId,
              options: options,
              placeholder: '选一个变量',
              onChanged: (v) => setState(() => b.varId = v ?? ''),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: HintLabel(
                  theme: t,
                  title: '判定提示词（这个变量单独怎么判）',
                  hintKey: 'settlement.prompt',
                ),
              ),
              TextButton.icon(
                onPressed: b.varId.isEmpty
                    ? null
                    : () => setState(() {
                          b.promptCtrl.text = _judgeTemplateFor(b.varId);
                        }),
                icon: Icon(Icons.auto_fix_high_rounded, size: 16, color: t.accent),
                label: Text(
                  '生成模板',
                  style: TextStyle(color: t.accent, fontSize: 12.5),
                ),
              ),
            ],
          ),
          TextField(
            controller: b.promptCtrl,
            minLines: 2,
            maxLines: 8,
            style: TextStyle(fontSize: 12.5, color: t.ink, height: 1.5),
            decoration: InputDecoration(
              isDense: true,
              hintText: '例：她有没有表现出更亲近的举动？有证据给 +1；明显疏远给 -1；看不出来 0。',
              hintStyle: TextStyle(fontSize: 12, color: t.sub),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Text(
                '单次上限',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: t.ink,
                ),
              ),
              const SizedBox(width: 6),
              HintDot(theme: t, hintKey: 'settlement.max'),
              const SizedBox(width: 10),
              SizedBox(
                width: 72,
                child: TextField(
                  controller: b.maxCtrl,
                  keyboardType: TextInputType.number,
                  style: TextStyle(fontSize: 13, color: t.ink),
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: '3',
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '这一个变量单次最多加减多少',
                  style: TextStyle(fontSize: 11, color: t.sub),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Text(
                '无证据时',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: t.ink,
                ),
              ),
              const SizedBox(width: 6),
              HintDot(theme: t, hintKey: 'scene.onNoEvidence'),
              const SizedBox(width: 10),
              SegmentedButton<String>(
                showSelectedIcon: false,
                style: ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  textStyle: WidgetStatePropertyAll(
                    TextStyle(fontSize: 12, color: t.ink),
                  ),
                ),
                segments: const <ButtonSegment<String>>[
                  ButtonSegment<String>(value: 'zero', label: Text('zero')),
                  ButtonSegment<String>(value: 'abort', label: Text('abort')),
                ],
                selected: <String>{b.onNoEvidence},
                onSelectionChanged: (s) =>
                    setState(() => b.onNoEvidence = s.first),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'zero＝这个变量保持原值，照常进入下一幕；'
            'abort＝拿不到证据就拒绝本次离场（谨慎用，容易卡住玩家）。',
            style: TextStyle(fontSize: 10.5, height: 1.5, color: t.sub),
          ),
        ],
      ),
    );
  }

  Widget _saveButton() {
    final t = _t;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: FilledButton.icon(
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
        label: const Text('保存本幕'),
      ),
    );
  }
}

// ===========================================================================
//  小工具
// ===========================================================================

/// `stories/` 下 `.json` 的文件名 → 情景 id（不含 .json）。
List<String> sceneIdsOf(StudioStore store, String slug) {
  final out = <String>[
    for (final f in store.listFiles(slug, 'stories'))
      if (f.toLowerCase().endsWith('.json'))
        f.substring(0, f.length - '.json'.length),
  ];
  out.sort();
  return out;
}

/// 通用「输入一个名字」弹窗：非空 + 不重名 + 额外的字符校验。
/// 「新建情景」的返回值：文件名 + 可选来源（复制自哪一幕）。
class _NewSceneSpec {
  const _NewSceneSpec({required this.name, this.sourceId});
  final String name;
  final String? sourceId;
}

/// 新建情景的弹窗：输名字 + 选来源（空白 / 复制自某一幕）。
///
/// 复制这条路是给「和上一幕差不多，只想改几句」用的：整套内容原样搬过去，
/// 包括它的出口 —— 作者只需改展示名与需要变的地方。
class _NewSceneDialog extends StatefulWidget {
  const _NewSceneDialog({
    required this.theme,
    required this.existingIds,
    required this.displayNameOf,
  });

  final ChatGalTheme theme;
  final List<String> existingIds;
  final String Function(String id) displayNameOf;

  @override
  State<_NewSceneDialog> createState() => _NewSceneDialogState();
}

class _NewSceneDialogState extends State<_NewSceneDialog> {
  final _name = TextEditingController();
  String? _source;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  String? _validate(String value) {
    final v = value.trim();
    if (v.isEmpty) return '给它起个名字（就是文件名）';
    if (v.contains('/') || v.contains(r'\')) return '不能包含路径分隔符';
    if (v.toLowerCase().endsWith('.json')) return '不要带 .json 后缀';
    if (widget.existingIds.contains(v)) return '已经有一幕叫这个名字了';
    return null;
  }

  /// 下拉里的「复制自 · 展示名（id）」：展示名可能没写，用 id 兜底，
  /// 好歹每条都不一样、能选中想要的那一幕。
  String _copyLabel(String id) {
    final name = widget.displayNameOf(id).trim();
    final label = (name.isEmpty || name == id) ? id : '$name（$id）';
    return '复制自 · $label';
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    final options = <(String, String)>[
      ('', '空白情景（只有骨架）'),
      for (final id in widget.existingIds)
        // 旧版这里把名字写成了空的（`'复制自  · '`），于是每一条都长得一模一样、
        // 根本认不出要复制哪一幕。展示名可能为空，补 id 兜底。
        (id, _copyLabel(id)),
    ];
    return AlertDialog(
      backgroundColor: t.card,
      title: Text('新建情景', style: TextStyle(fontSize: 16, color: t.ink)),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '名字就是文件名（stories/<名字>.json），也是它的 id；不要带 / 和 .json，'
              '游戏入口固定叫 start。',
              style: TextStyle(fontSize: 11.5, height: 1.5, color: t.sub),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _name,
              autofocus: true,
              style: TextStyle(fontSize: 13, color: t.ink),
              decoration: InputDecoration(
                isDense: true,
                labelText: '情景 id',
                hintText: '例如 day1_2',
                errorText: _error,
              ),
              onChanged: (_) => setState(() => _error = null),
            ),
            const SizedBox(height: 12),
            Text(
              '来源',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: t.ink),
            ),
            const SizedBox(height: 4),
            StudioDropdown<String>(
              theme: t,
              value: _source ?? '',
              options: options,
              onChanged: (v) => setState(() => _source = (v == null || v.isEmpty) ? null : v),
            ),
            const SizedBox(height: 6),
            Text(
              _source == null
                  ? '从零开始：只写一个空骨架，出场角色 / 改值 / 出口都留空。'
                  : '会把这些内容整套复制过去（出场角色、入场改值、结算、出口都在内），'
                      '记得改展示名与需要变的地方。',
              style: TextStyle(fontSize: 11, height: 1.5, color: t.sub),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('取消', style: TextStyle(color: t.sub)),
        ),
        FilledButton(
          onPressed: () {
            final err = _validate(_name.text);
            if (err != null) {
              setState(() => _error = err);
              return;
            }
            Navigator.pop(context, _NewSceneSpec(
              name: _name.text.trim(),
              sourceId: _source,
            ));
          },
          child: const Text('新建'),
        ),
      ],
    );
  }
}

Future<String?> askStudioName(
  BuildContext context,
  ChatGalTheme theme, {
  required String title,
  required String hint,
  required String note,
  required bool Function(String value) exists,
  String? Function(String value)? extraCheck,
  String confirmLabel = '创建',
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _NameDialog(
      theme: theme,
      title: title,
      hint: hint,
      note: note,
      exists: exists,
      extraCheck: extraCheck,
      confirmLabel: confirmLabel,
    ),
  );
}

/// 切换对象前的草稿保护：有未保存修改时弹「保存 / 放弃 / 取消」。
///
/// 返回 `true` = 可以安全切换（已保存或作者明确放弃）；`false` = 取消切换。
/// 以前切换情景/事件直接重载表单，未保存文字静默丢失。
Future<bool> confirmDiscardDraft(
  BuildContext context,
  ChatGalTheme theme, {
  required String what,
  Future<bool> Function()? onSave,
}) async {
  final action = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: theme.card,
      title: Text('有未保存的修改', style: TextStyle(color: theme.ink, fontSize: 16)),
      content: Text(
        '「$what」有还没保存的修改。切换后会丢掉这些修改。',
        style: TextStyle(color: theme.sub, fontSize: 13),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop('cancel'),
          child: Text('取消', style: TextStyle(color: theme.sub)),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop('discard'),
          child: Text('放弃修改', style: TextStyle(color: Colors.orange.shade800)),
        ),
        if (onSave != null)
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('save'),
            child: Text('保存', style: TextStyle(color: theme.accent)),
          ),
      ],
    ),
  );
  if (action == 'cancel' || action == null) return false;
  if (action == 'save' && onSave != null) {
    return onSave();
  }
  return true;
}

/// 弹窗本体：controller 由它自己 dispose（在外面 dispose 会和退场动画抢）。
class _NameDialog extends StatefulWidget {
  const _NameDialog({
    required this.theme,
    required this.title,
    required this.hint,
    required this.note,
    required this.exists,
    required this.confirmLabel,
    this.extraCheck,
  });

  final ChatGalTheme theme;
  final String title;
  final String hint;
  final String note;
  final bool Function(String value) exists;
  final String? Function(String value)? extraCheck;
  final String confirmLabel;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  final TextEditingController _ctrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final v = _ctrl.text.trim();
    if (v.isEmpty) {
      setState(() => _error = '名字不能为空');
      return;
    }
    final extra = widget.extraCheck?.call(v);
    if (extra != null) {
      setState(() => _error = extra);
      return;
    }
    if (widget.exists(v)) {
      setState(() => _error = '「$v」已经存在了，换一个名字');
      return;
    }
    Navigator.of(context).pop(v);
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    return AlertDialog(
      backgroundColor: t.card,
      title: Text(widget.title, style: TextStyle(color: t.ink)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.note,
            style: TextStyle(fontSize: 11.5, height: 1.5, color: t.sub),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _ctrl,
            autofocus: true,
            style: TextStyle(fontSize: 14, color: t.ink),
            decoration: InputDecoration(hintText: widget.hint, errorText: _error),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('取消', style: TextStyle(color: t.sub)),
        ),
        TextButton(
          onPressed: _submit,
          child: Text(widget.confirmLabel, style: TextStyle(color: t.accent)),
        ),
      ],
    );
  }
}

List<String> _strList(Object? raw) {
  if (raw is! List) return <String>[];
  return <String>[for (final e in raw) '$e'];
}

List<String> _dedupe(List<String> raw) {
  final out = <String>[];
  for (final s in raw) {
    if (s.trim().isEmpty) continue;
    if (out.contains(s)) continue;
    out.add(s);
  }
  return out;
}

num _numOf(String text) {
  final v = num.tryParse(text.trim());
  return v ?? 0;
}
