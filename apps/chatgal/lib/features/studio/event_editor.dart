import 'dart:io';

import 'package:flutter/material.dart';
import 'package:gal_protocol/gal_protocol.dart';
import 'package:gal_storage/gal_storage.dart';

import '../../app/app_services.dart';
import '../../design_system/tokens.dart';
import 'hints.dart';
import 'scene_editor.dart';

/// 事件里一块 slides：一张图 + 若干句（`image` 为 '' 表示沿用上一张）。
class _SlideRow {
  _SlideRow({required this.image, required String text})
      : textCtrl = TextEditingController(text: text);

  String image;
  final TextEditingController textCtrl;

  void dispose() => textCtrl.dispose();
}

/// 选择题里的一个选项：按钮上的字 + 去哪。
class _ChoiceOptionRow {
  _ChoiceOptionRow({String text = '', this.kind = 'story', this.to = ''})
      : textCtrl = TextEditingController(text: text);

  final TextEditingController textCtrl;
  String kind;
  String to;

  void dispose() => textCtrl.dispose();
}

/// 选择题出口（事件专有）：标题 + 最多 [EventChoice.maxOptions] 个选项。
/// 选项上限直接用协议里的常量（格式的上限只有一处，别在界面里再写一个 5）。
class _ChoiceModel {
  _ChoiceModel({String title = '', List<_ChoiceOptionRow>? options})
      : titleCtrl = TextEditingController(text: title),
        options = options ?? <_ChoiceOptionRow>[];

  final TextEditingController titleCtrl;
  final List<_ChoiceOptionRow> options;

  String signature() => '${titleCtrl.text}||'
      '${options.map((o) => '${o.textCtrl.text}:${o.kind}:${o.to}').join(',')}';

  void dispose() {
    titleCtrl.dispose();
    for (final o in options) {
      o.dispose();
    }
  }
}

/// 事件编辑器：`events/<事件id>/event.json`（全屏演出：一块一屏，点一下翻下一块）。
///
/// 没有 id / name：文件夹名就是 id，也是世界控制台里显示的名字。
class EventEditor extends StatefulWidget {
  const EventEditor({
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
  State<EventEditor> createState() => _EventEditorState();
}

class _EventEditorState extends State<EventEditor> {
  ChatGalTheme get _t => widget.theme;
  StudioStore get _store => widget.services.studio;

  List<String> _ids = <String>[];
  String? _selected;

  Map<String, Object?> _raw = <String, Object?>{};
  List<_SlideRow> _slides = <_SlideRow>[];
  List<TargetBlockModel> _targets = <TargetBlockModel>[];

  /// 出口二选一：`true` = 选择题（choice），`false` = 出口块（target）。
  bool _useChoice = false;
  _ChoiceModel _choice = _ChoiceModel();

  List<String> _images = <String>[];
  List<String> _storyIds = <String>[];
  Set<String> _knownVars = <String>{};

  bool _busy = false;

  /// 上次加载/保存时的表单快照：用来判断有没有未保存修改。
  String _savedSignature = '';

  /// 当前表单状态的签名（用于脏检测）。
  String _formSignature() {
    final parts = <String>[
      for (final s in _slides) '${s.image}|${s.textCtrl.text}',
      'exit:${_useChoice ? 'choice' : 'target'}',
      if (_useChoice) 'c:${_choice.signature()}',
      for (final b in _targets) b.signature(),
    ];
    return parts.join(';;');
  }

  bool get _dirty => _formSignature() != _savedSignature;

  bool _lastReportedDirty = false;

  /// 统一脏状态上报。
  void _reportDirty() {
    if (!mounted) return;
    final d = _dirty;
    if (d != _lastReportedDirty) {
      _lastReportedDirty = d;
      widget.onDirtyChanged?.call(d);
    }
  }

  /// 给文本控制器挂监听。
  void _attachDirtyListeners() {
    void listen(TextEditingController? c) {
      c?.removeListener(_reportDirty);
      c?.addListener(_reportDirty);
    }

    for (final s in _slides) {
      listen(s.textCtrl);
    }
    for (final b in _targets) {
      listen(b.requireCtrl);
    }
    listen(_choice.titleCtrl);
    for (final o in _choice.options) {
      listen(o.textCtrl);
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final s in _slides) {
      s.dispose();
    }
    for (final b in _targets) {
      b.dispose();
    }
    _choice.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

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

  // ---------------------------------------------------------------- 读取

  void _load() {
    _ids = _store.listDirs(widget.slug, 'events');
    if (_ids.isEmpty) {
      _selected = null;
    } else if (_selected == null || !_ids.contains(_selected)) {
      _selected = _ids.first;
    }
    _storyIds = sceneIdsOf(_store, widget.slug);
    final manifest =
        _store.readJson(widget.slug, 'manifest.json') ?? <String, Object?>{};
    _knownVars = <String>{};
    final rawVars = manifest['variables'];
    if (rawVars is List) {
      for (final v in rawVars) {
        if (v is! Map) continue;
        final id = '${Map<String, Object?>.from(v)['id'] ?? ''}'.trim();
        if (id.isNotEmpty) _knownVars.add(id);
      }
    }
    _loadEvent();
  }

  void _loadEvent() {
    for (final s in _slides) {
      s.dispose();
    }
    for (final b in _targets) {
      b.dispose();
    }
    _choice.dispose();

    final id = _selected;
    _raw = id == null
        ? <String, Object?>{}
        : (_store.readJson(widget.slug, 'events/$id/event.json') ??
            <String, Object?>{});

    _slides = <_SlideRow>[];
    final rawSlides = _raw['slides'];
    if (rawSlides is List) {
      for (final s in rawSlides) {
        if (s is! Map) continue;
        final m = Map<String, Object?>.from(s);
        final lines = <String>[];
        final rawText = m['text'];
        if (rawText is List) {
          lines.addAll(<String>[for (final t in rawText) '$t']);
        } else if (rawText is String && rawText.isNotEmpty) {
          lines.add(rawText);
        }
        _slides.add(
          _SlideRow(image: '${m['image'] ?? ''}', text: lines.join('\n')),
        );
      }
    }

    _targets = targetBlocksFromJson(_raw['target']);

    // 出口二选一：磁盘上写了 choice 就是选择题模式（哪怕 options 是空的，
    // 也要把作者带回这个模式让他补完，而不是悄悄切回 target）。
    final rawChoice = _raw['choice'];
    if (rawChoice is Map) {
      final cm = Map<String, Object?>.from(rawChoice);
      final opts = <_ChoiceOptionRow>[];
      final rawOpts = cm['options'];
      if (rawOpts is List) {
        for (final o in rawOpts) {
          if (o is! Map) continue;
          final om = Map<String, Object?>.from(o);
          final kind = '${om['kind'] ?? ''}'.trim();
          opts.add(
            _ChoiceOptionRow(
              text: '${om['text'] ?? ''}',
              kind: kind.isEmpty ? 'story' : kind,
              to: '${om['to'] ?? ''}'.trim(),
            ),
          );
        }
      }
      _choice = _ChoiceModel(title: '${cm['title'] ?? ''}', options: opts);
      _useChoice = true;
    } else {
      _choice = _ChoiceModel();
      _useChoice = false;
    }

    _images = <String>[
      if (id != null)
        for (final f in _store.listFiles(widget.slug, 'events/$id'))
          if (isStudioImage(f)) f,
    ];
    _savedSignature = _formSignature();
    _lastReportedDirty = false;
    _attachDirtyListeners();
    widget.onDirtyChanged?.call(false);
  }

  Future<void> _select(String id) async {
    if (id == _selected) return;
    // 草稿保护：有未保存修改时先问作者，不要静默丢掉。
    if (_dirty) {
      final ok = await confirmDiscardDraft(
        context,
        _t,
        what: '事件「$_selected」',
        onSave: () async {
          await _save();
          return !_dirty;
        },
      );
      if (!ok || !mounted) return;
    }
    setState(() {
      _selected = id;
      _loadEvent();
    });
  }

  void _setTargets(List<TargetBlockModel> next) {
    for (final b in _targets) {
      if (!next.contains(b)) b.dispose();
    }
    setState(() => _targets = next);
  }

  // ---------------------------------------------------------------- 选择题

  /// 出口方式二选一。切换本身只是改内存标记，但**保存时**会把另一侧从文件里清掉：
  /// 误点一下「出口块 target」再随手保存，就能把已经写好的选择题出口删掉。
  /// 所以另一侧有内容时先问一句。
  Future<void> _setUseChoice(bool v) async {
    if (v == _useChoice) return;
    final otherHasContent = v
        ? _targets.isNotEmpty
        : _choice.options.isNotEmpty || _choice.titleCtrl.text.trim().isNotEmpty;
    if (otherHasContent) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: _t.card,
          title: Text('切换出口方式？', style: TextStyle(color: _t.ink)),
          content: Text(
            v
                ? '出口块（target）与选择题（choice）二选一：切过去之后保存，'
                    '会把现在写的出口块从文件里清掉。确定切换吗？'
                : '选择题（choice）与出口块（target）二选一：切过去之后保存，'
                    '会把现在写的选项从文件里清掉。确定切换吗？',
            style: TextStyle(color: _t.sub, fontSize: 13, height: 1.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text('取消', style: TextStyle(color: _t.sub)),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('切换',
                  style: TextStyle(color: Colors.orange)),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    setState(() {
      _useChoice = v;
      // 切到选择题而一个选项都没有时，先给一个空选项，省得对着「添加选项」发呆。
      if (v && _choice.options.isEmpty) {
        _choice.options.add(_ChoiceOptionRow(kind: 'appShell', to: 'home'));
      }
    });
  }

  /// 选择题能不能保存：返回第一条人话错误，或 null。
  String? _choiceError() {
    if (_choice.options.isEmpty) {
      return '选择题至少要有一个选项（不然玩家点到最后一屏就没得选）';
    }
    if (_choice.options.length > EventChoice.maxOptions) {
      return '选择题最多 ${EventChoice.maxOptions} 个选项';
    }
    for (var i = 0; i < _choice.options.length; i++) {
      final o = _choice.options[i];
      final no = i + 1;
      if (o.textCtrl.text.trim().isEmpty) {
        return '第 $no 个选项还没写字：玩家会看到一个空按钮';
      }
      final to = o.to.trim();
      if (to.isEmpty) return '第 $no 个选项还没选目的地';
      if (o.kind == 'story' && !_storyIds.contains(to)) {
        return '第 $no 个选项指向的情景「$to」不存在';
      }
      if (o.kind == 'event' && !_ids.contains(to)) {
        return '第 $no 个选项指向的事件「$to」不存在';
      }
      if (o.kind == 'appShell' && to != 'home') {
        return '第 $no 个选项的 appShell 只能写 home';
      }
    }
    return null;
  }

  /// 目的地下拉的选项表：story / event / appShell 三种。
  List<(String, String)> _kindOptions() => const [
        ('story', '去某情景 story'),
        ('event', '去某事件 event'),
        ('appShell', '回主页 appShell'),
      ];

  /// `to` 的可选值：按 kind 给对应的 id 列表（appShell 固定只有 home）。
  List<(String, String)> _toOptionsFor(String kind) {
    switch (kind) {
      case 'event':
        return [for (final id in _ids) (id, id)];
      case 'appShell':
        return const [('home', 'home（回主页）')];
      default:
        return [for (final id in _storyIds) (id, id)];
    }
  }

  // ---------------------------------------------------------------- 写盘

  List<String> _linesOf(_SlideRow row) => <String>[
        for (final line in row.textCtrl.text.split('\n'))
          if (line.trim().isNotEmpty) line.trim(),
      ];

  Future<void> _save() => _run(() async {
        final id = _selected;
        if (id == null) return;
        if (_slides.isEmpty) {
          _toast('事件至少要有一块 slides：点「添加一块」写第一张图');
          return;
        }
        final err = _useChoice
            ? _choiceError()
            : targetBlocksError(
                _targets,
                knownVariables: _knownVars,
                storyIds: _storyIds,
                eventIds: _ids,
              );
        if (err != null) {
          _toast(err);
          return;
        }
        if (!_useChoice && _targets.isEmpty) {
          // 不是错误（体检只给 warning）：提前说一声，免得玩家播完卡住。
          _toast('提示：这个事件没有出口，播完会显示「暂时不能进入下一阶段」');
        }
        final out = <String, Object?>{..._raw};
        out['slides'] = <Map<String, Object?>>[
          for (final s in _slides)
            <String, Object?>{
              'image': s.image.trim().isEmpty ? null : s.image.trim(),
              'text': _linesOf(s),
            },
        ];
        // 出口二选一：写哪个就把另一个键删掉（两个都留在文件里只会让体检报错）。
        if (_useChoice) {
          out.remove('target');
          out['choice'] = <String, Object?>{
            if (_choice.titleCtrl.text.trim().isNotEmpty)
              'title': _choice.titleCtrl.text.trim(),
            'options': <Map<String, Object?>>[
              for (final o in _choice.options)
                <String, Object?>{
                  'text': o.textCtrl.text.trim(),
                  'kind': o.kind,
                  'to': o.to.trim(),
                },
            ],
          };
        } else {
          out.remove('choice');
          out['target'] = targetBlocksToJson(_targets);
        }
        // 写盘异步：先固定这一份的签名，避免保存期间继续输入被误标成已保存。
        final savedSignature = _formSignature();
        await _store.writeJson(widget.slug, 'events/$id/event.json', out);
        if (!mounted) return;
        _raw = out;
        _savedSignature = savedSignature;
        final stillDirty = _formSignature() != _savedSignature;
        _lastReportedDirty = stillDirty;
        widget.onDirtyChanged?.call(stillDirty);
        widget.onSaved?.call();
      });

  Future<void> _newEvent() async {
    final id = await askStudioName(
      context,
      _t,
      title: '新建事件',
      hint: 'end_csrj / badend_1',
      note: '文件夹名就是事件 id，也是世界控制台里显示的名字。'
          '事件里不能和角色对话，只能一句句点过去（常用来做结局）。',
      exists: (v) => _ids.contains(v),
      extraCheck: (v) {
        if (v.contains('/') || v.contains(r'\')) return '不能包含路径分隔符';
        return null;
      },
    );
    if (id == null || !mounted) return;
    await _run(() async {
      await _store.writeJson(
        widget.slug,
        'events/$id/event.json',
        <String, Object?>{
          'slides': <Map<String, Object?>>[
            <String, Object?>{'image': null, 'text': <String>[]},
          ],
          'target': <Object?>[],
        },
      );
      if (!mounted) return;
      setState(() {
        _selected = id;
        _load();
      });
      widget.onSaved?.call();
      _toast('已新建事件「$id」：给它导入一张图并写上句子');
    });
  }

  Future<void> _deleteEvent() async {
    final id = _selected;
    if (id == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _t.card,
        title: Text('删除事件「$id」？', style: TextStyle(color: _t.ink)),
        content: Text(
          '会删掉整个 events/$id/ 目录（event.json 与里面的图）。'
          '指向它的事件出口会变成「事件不存在」。删除不可撤销。',
          style: TextStyle(color: _t.sub, fontSize: 12.5, height: 1.6),
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
    await _run(() async {
      await _store.deletePath(widget.slug, 'events/$id');
      if (!mounted) return;
      setState(() {
        _selected = null;
        _load();
      });
      widget.onSaved?.call();
      _toast('已删除事件「$id」');
    });
  }

  /// 把一张图导入事件目录并选中。
  Future<void> _importImage(int slideIndex) async {
    final id = _selected;
    if (id == null) return;
    final picked = await pickStudioImages(dialogTitle: '选择事件插图');
    if (picked.isEmpty || !mounted) return;
    final file = picked.first;
    final name = sanitizeStudioFileName(file.name);
    if (_images.contains(name)) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: _t.card,
          title: Text('覆盖同名图片？', style: TextStyle(color: _t.ink)),
          content: Text(
            'events/$id/$name 已存在，导入会覆盖它。',
            style: TextStyle(color: _t.sub, fontSize: 12.5, height: 1.6),
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
    await _run(() async {
      final bytes = await readStudioImageBytes(file);
      if (!mounted) return;
      await _store.writeBytes(widget.slug, 'events/$id/$name', bytes);
      if (!mounted) return;
      setState(() {
        _images = <String>[
          for (final f in _store.listFiles(widget.slug, 'events/$id'))
            if (isStudioImage(f)) f,
        ];
        if (slideIndex >= 0 && slideIndex < _slides.length) {
          _slides[slideIndex].image = name;
        }
      });
      widget.onSaved?.call();
      _toast('已导入 events/$id/$name');
    });
  }

  // ---------------------------------------------------------------- 界面

  @override
  Widget build(BuildContext context) {
    // 任何 setState 引发的重建都会走到这里：帧结束后检查脏状态并上报。
    WidgetsBinding.instance.addPostFrameCallback((_) => _reportDirty());
    final t = _t;
    if (_ids.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Spacing.lg),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.auto_stories_outlined, size: 40, color: t.sub),
              const SizedBox(height: 12),
              Text(
                '这个工程还没有事件',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: t.ink,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '事件 = 一段不能对话的演出（全屏插图，一块一屏：点一下翻下一块），常用来做结局。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, height: 1.7, color: t.sub),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: t.accent,
                  foregroundColor: Colors.white,
                ),
                onPressed: _busy ? null : _newEvent,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('新建事件'),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        _eventBar(),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 28),
            children: [
              StudioSection(
                theme: t,
                title: '演出分块 slides',
                hintKey: 'event.slides',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    StudioNote(
                      theme: t,
                      text: '一块 = 一屏：一张图 + 这一屏的全部文字，点一下翻下一块。'
                          '块里写多句会**换行显示在同一屏**，所以一句话一行、别写太长。',
                    ),
                    for (var i = 0; i < _slides.length; i++) _slideCard(i),
                    OutlinedButton.icon(
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                                _slides = <_SlideRow>[
                                  ..._slides,
                                  _SlideRow(image: '', text: ''),
                                ];
                              }),
                      icon: Icon(Icons.add_rounded, size: 18, color: t.accent),
                      label: Text(
                        '添加一块',
                        style: TextStyle(color: t.accent, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
              _exitModeSection(t),
              if (_useChoice)
                _choiceSection(t)
              else
                TargetBlocksEditor(
                  theme: t,
                  blocks: _targets,
                  onChanged: _setTargets,
                  knownVariables: _knownVars,
                  storyIds: _storyIds,
                  eventIds: _ids,
                  title: '演出结束后的出口 target',
                  emptyNote: '没有出口：整段演出播完会提示「暂时不能进入下一阶段」。',
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
                label: Text('保存事件「${_selected ?? ''}」'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 出口方式二选一：条件出口块 target / 玩家自选的选择题 choice。
  Widget _exitModeSection(ChatGalTheme t) {
    return StudioSection(
      theme: t,
      title: '演出结束后的出口（二选一）',
      hintKey: 'event.choice',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              ChoiceChip(
                label: const Text('出口块 target'),
                selected: !_useChoice,
                showCheckmark: false,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                backgroundColor: t.bg,
                selectedColor: t.accent.withValues(alpha: 0.18),
                side: BorderSide(
                  color: !_useChoice ? t.accent : t.sub.withValues(alpha: 0.25),
                ),
                labelStyle: TextStyle(
                  fontSize: 12.5,
                  color: !_useChoice ? t.ink : t.sub,
                  fontWeight: !_useChoice ? FontWeight.w700 : FontWeight.w500,
                ),
                onSelected: (_) => _setUseChoice(false),
              ),
              ChoiceChip(
                label: const Text('选择题 choice'),
                selected: _useChoice,
                showCheckmark: false,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                backgroundColor: t.bg,
                selectedColor: t.accent.withValues(alpha: 0.18),
                side: BorderSide(
                  color: _useChoice ? t.accent : t.sub.withValues(alpha: 0.25),
                ),
                labelStyle: TextStyle(
                  fontSize: 12.5,
                  color: _useChoice ? t.ink : t.sub,
                  fontWeight: _useChoice ? FontWeight.w700 : FontWeight.w500,
                ),
                onSelected: (_) => _setUseChoice(true),
              ),
            ],
          ),
          const SizedBox(height: 8),
          StudioNote(
            theme: t,
            text: _useChoice
                ? '选择题：播完最后一屏后，玩家在这几个选项里点一个 —— '
                    '选项直接写去哪，不判数值、也不随机（所以选项里没有条件与权重）。'
                    '保存时会写 choice，并清掉 target。'
                : '出口块：与情景完全同一套写法（条件 + 块内等概率随机）；'
                    '一个都不成立时播完提示「暂时不能进入下一阶段」。'
                    '保存时会写 target，并清掉 choice。',
          ),
        ],
      ),
    );
  }

  /// 选择题编辑：标题（可空）+ 选项列表（1~5 个）。
  Widget _choiceSection(ChatGalTheme t) {
    return StudioSection(
      theme: t,
      title: '选择题选项（${_choice.options.length}/${EventChoice.maxOptions}）',
      hintKey: 'event.choiceOptions',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HintLabel(theme: t, title: '标题 title（可留空）', hintKey: 'event.choiceOptions'),
          TextField(
            controller: _choice.titleCtrl,
            style: TextStyle(fontSize: 13.5, color: t.ink),
            decoration: const InputDecoration(
              hintText: '例：要继续留在这里吗？',
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 10),
          for (var i = 0; i < _choice.options.length; i++) _choiceOptionCard(i),
          OutlinedButton.icon(
            onPressed: _busy || _choice.options.length >= EventChoice.maxOptions
                ? null
                : () => setState(() {
                      _choice.options.add(_ChoiceOptionRow());
                    }),
            icon: Icon(Icons.add_rounded, size: 18, color: t.accent),
            label: Text(
              _choice.options.length >= EventChoice.maxOptions
                  ? '最多 ${EventChoice.maxOptions} 个选项'
                  : '添加选项',
              style: TextStyle(color: t.accent, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _choiceOptionCard(int i) {
    final t = _t;
    final o = _choice.options[i];
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
              StudioTag(theme: t, text: '选项 ${i + 1}'),
              const Spacer(),
              IconButton(
                tooltip: '上移',
                onPressed: i == 0
                    ? null
                    : () => setState(() {
                          final next = <_ChoiceOptionRow>[..._choice.options];
                          final tmp = next[i - 1];
                          next[i - 1] = next[i];
                          next[i] = tmp;
                          _choice.options
                            ..clear()
                            ..addAll(next);
                        }),
                icon: const Icon(Icons.arrow_upward_rounded, size: 17),
                color: t.sub,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
              ),
              IconButton(
                tooltip: '下移',
                onPressed: i == _choice.options.length - 1
                    ? null
                    : () => setState(() {
                          final next = <_ChoiceOptionRow>[..._choice.options];
                          final tmp = next[i + 1];
                          next[i + 1] = next[i];
                          next[i] = tmp;
                          _choice.options
                            ..clear()
                            ..addAll(next);
                        }),
                icon: const Icon(Icons.arrow_downward_rounded, size: 17),
                color: t.sub,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
              ),
              IconButton(
                tooltip: '删除这个选项',
                onPressed: () => setState(() {
                  _choice.options.removeAt(i).dispose();
                }),
                icon: const Icon(Icons.delete_outline_rounded, size: 17),
                color: t.sub,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
              ),
            ],
          ),
          const SizedBox(height: 2),
          HintLabel(theme: t, title: '按钮上的字', hintKey: 'event.choiceOptions'),
          TextField(
            controller: o.textCtrl,
            style: TextStyle(fontSize: 13, color: t.ink),
            decoration: const InputDecoration(hintText: '例：回到主页'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('去哪（类型）', style: TextStyle(fontSize: 11, color: t.sub)),
                    const SizedBox(height: 2),
                    StudioDropdown<String>(
                      theme: t,
                      value: o.kind,
                      options: _kindOptions(),
                      onChanged: (v) => setState(() {
                        o.kind = v ?? 'story';
                        // 换类型时旧目标多半不再合法（story id 不是 event id），
                        // 直接清空让作者重新选，比留一个对不上的值好。
                        o.to = o.kind == 'appShell' ? 'home' : '';
                      }),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('去哪（哪个）', style: TextStyle(fontSize: 11, color: t.sub)),
                    const SizedBox(height: 2),
                    StudioDropdown<String>(
                      theme: t,
                      value: o.to,
                      options: _toOptionsFor(o.kind),
                      placeholder: '（选一个）',
                      onChanged: (v) => setState(() => o.to = v ?? ''),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _eventBar() {
    final t = _t;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      decoration: BoxDecoration(
        color: t.card,
        border: Border(bottom: BorderSide(color: t.sub.withValues(alpha: 0.15))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '事件（共 ${_ids.length} 个）',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: t.ink,
                ),
              ),
              const SizedBox(width: 4),
              HintDot(theme: t, hintKey: 'event.list'),
              const Spacer(),
              TextButton.icon(
                onPressed: _busy ? null : _newEvent,
                icon: Icon(Icons.add_rounded, size: 17, color: t.accent),
                label: Text(
                  '新建',
                  style: TextStyle(color: t.accent, fontSize: 12.5),
                ),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                ),
              ),
              TextButton.icon(
                onPressed: _busy ? null : _deleteEvent,
                icon: const Icon(
                  Icons.delete_outline_rounded,
                  size: 17,
                  color: Colors.red,
                ),
                label: const Text(
                  '删除本事件',
                  style: TextStyle(color: Colors.red, fontSize: 12.5),
                ),
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
            onSelect: _select,
          ),
        ],
      ),
    );
  }

  Widget _slideCard(int i) {
    final t = _t;
    final s = _slides[i];
    final lines = _linesOf(s);
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
              StudioTag(theme: t, text: '第 ${i + 1} 块'),
              const SizedBox(width: 6),
              if (lines.isEmpty)
                StudioTag(theme: t, text: '没有句子', color: Colors.red),
              const Spacer(),
              IconButton(
                tooltip: '上移',
                onPressed: i == 0
                    ? null
                    : () => setState(() {
                          final next = <_SlideRow>[..._slides];
                          final tmp = next[i - 1];
                          next[i - 1] = next[i];
                          next[i] = tmp;
                          _slides = next;
                        }),
                icon: const Icon(Icons.arrow_upward_rounded, size: 17),
                color: t.sub,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
              ),
              IconButton(
                tooltip: '下移',
                onPressed: i == _slides.length - 1
                    ? null
                    : () => setState(() {
                          final next = <_SlideRow>[..._slides];
                          final tmp = next[i + 1];
                          next[i + 1] = next[i];
                          next[i] = tmp;
                          _slides = next;
                        }),
                icon: const Icon(Icons.arrow_downward_rounded, size: 17),
                color: t.sub,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
              ),
              IconButton(
                tooltip: '删除这一块',
                onPressed: () => setState(() {
                  _slides = <_SlideRow>[..._slides]..removeAt(i);
                }),
                icon: const Icon(Icons.delete_outline_rounded, size: 17),
                color: t.sub,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
              ),
            ],
          ),
          Row(
            children: [
              Text(
                '这一块的图',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: t.ink,
                ),
              ),
              const SizedBox(width: 4),
              HintDot(theme: t, hintKey: 'slide.image'),
            ],
          ),
          const SizedBox(height: 5),
          StudioImagePicker(
            theme: t,
            names: _images,
            selected: s.image,
            allowEmpty: true,
            emptyLabel: '（沿用上一张）',
            fileOf: (name) => File(
              widget.services.studio.absPathOf(
                widget.slug,
                'events/${_selected ?? ''}/$name',
              ),
            ),
            onSelect: (v) => setState(() => s.image = v),
            onImport: _busy ? null : () => _importImage(i),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Text(
                '这一块的句子（一行一句）',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: t.ink,
                ),
              ),
              const SizedBox(width: 4),
              HintDot(theme: t, hintKey: 'slide.text'),
            ],
          ),
          const SizedBox(height: 5),
          TextField(
            controller: s.textCtrl,
            minLines: 3,
            maxLines: null,
            keyboardType: TextInputType.multiline,
            style: TextStyle(fontSize: 13, height: 1.6, color: t.ink),
            decoration: const InputDecoration(
              hintText: '例：她选择了毛至试剂。\n冰蓝色的液体注入血管……\n（一行一句，都会显示在同一屏里）',
            ),
            onChanged: (_) => setState(() {}),
          ),
          if (lines.isEmpty)
            StudioNote(
              theme: t,
              text: '这一块没有任何文字：点到这里会是空屏（体检会给 warning）。',
              color: Colors.red,
              icon: Icons.error_outline_rounded,
            ),
        ],
      ),
    );
  }
}
