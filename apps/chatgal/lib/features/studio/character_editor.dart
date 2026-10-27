import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:gal_storage/gal_storage.dart';
import 'package:path/path.dart' as p;

import '../../app/app_services.dart';
import '../../design_system/tokens.dart';
import 'hints.dart';
import 'scene_editor.dart';

/// 角色编辑器：`characters/<角色id>/character.json` + 立绘矩阵。
///
/// 立绘没有映射表：文件名就是约定 `characters/<id>/<状态>_<情绪>.png`。
/// 所以这个页面的核心是「名字」：状态 / 情绪的增删改会**连带改名立绘文件**，
/// 矩阵的每一格下面都写着它对应的文件名。
class CharacterEditor extends StatefulWidget {
  const CharacterEditor({
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
  State<CharacterEditor> createState() => _CharacterEditorState();
}

class _CharacterEditorState extends State<CharacterEditor> {
  ChatGalTheme get _t => widget.theme;
  StudioStore get _store => widget.services.studio;

  List<String> _ids = <String>[];
  String? _selected;

  Map<String, Object?> _raw = <String, Object?>{};
  TextEditingController? _prompt;
  List<String> _states = <String>[];
  List<String> _emotions = <String>[];
  String _defaultState = '';
  String _defaultEmotion = '';

  /// 角色目录下的全部文件名（原始大小写）与它们的小写集合（查存在用）。
  List<String> _allFiles = <String>[];
  Set<String> _lowerFiles = <String>{};

  /// 每次落盘/改名后 +1：给缩略图当 key，避免 Image 缓存显示旧图。
  int _stamp = 0;

  bool _busy = false;

  String _savedSignature = '';
  bool _lastReportedDirty = false;

  String _formSignature() {
    return [
      _prompt?.text ?? '',
      _states.join(','),
      _emotions.join(','),
      _defaultState,
      _defaultEmotion,
    ].join(';;');
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

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _prompt?.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 所有异步动作统一挡重入。
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
    _prompt?.dispose();
    _prompt = null;
    _ids = _store.listDirs(widget.slug, 'characters');
    if (_ids.isEmpty) {
      _selected = null;
    } else if (_selected == null || !_ids.contains(_selected)) {
      _selected = _ids.first;
    }
    _loadCharacter();
  }

  void _loadCharacter() {
    _prompt?.dispose();
    final id = _selected;
    _raw = id == null
        ? <String, Object?>{}
        : (_store.readJson(widget.slug, 'characters/$id/character.json') ??
            <String, Object?>{});
    _prompt = TextEditingController(text: '${_raw['prompt'] ?? ''}');
    _states = _dedupe(_strList(_raw['states']));
    _emotions = _dedupe(_strList(_raw['emotions']));
    _defaultState = '${_raw['defaultState'] ?? ''}';
    _defaultEmotion = '${_raw['defaultEmotion'] ?? ''}';
    if (_defaultState.isEmpty && _states.isNotEmpty) {
      _defaultState = _states.first;
    }
    if (_defaultEmotion.isEmpty && _emotions.isNotEmpty) {
      _defaultEmotion = _emotions.first;
    }
    _refreshFiles();
    _savedSignature = _formSignature();
    _lastReportedDirty = false;
    _prompt?.removeListener(_reportDirty);
    _prompt?.addListener(_reportDirty);
    widget.onDirtyChanged?.call(false);
  }

  void _refreshFiles() {
    final id = _selected;
    _allFiles =
        id == null ? <String>[] : _store.listFiles(widget.slug, 'characters/$id');
    _lowerFiles = <String>{for (final f in _allFiles) f.toLowerCase()};
    _stamp++;
  }

  // ---------------------------------------------------------------- 小工具

  String _portraitName(String state, String emotion) => '${state}_$emotion.png';

  bool _hasPortrait(String state, String emotion) =>
      _lowerFiles.contains(_portraitName(state, emotion).toLowerCase());

  String _absPath(String fileName) => p.join(
        _store.dirOf(widget.slug),
        'characters',
        _selected ?? '',
        fileName,
      );

  String _stem(String fileName) {
    final i = fileName.lastIndexOf('.');
    return i <= 0 ? fileName : fileName.substring(0, i);
  }

  bool get _dirtyPrompt =>
      _prompt != null && _prompt!.text != '${_raw['prompt'] ?? ''}';

  int get _missingCount {
    var n = 0;
    for (final s in _states) {
      for (final e in _emotions) {
        if (!_hasPortrait(s, e)) n++;
      }
    }
    return n;
  }

  /// 状态/情绪名不能含下划线或路径分隔符（文件名是「状态_情绪.png」）。
  String? _nameCheck(String v) {
    if (v.contains('_')) return '不要用下划线：文件名是「状态_情绪.png」，用它会把名字切错';
    if (v.contains('/') || v.contains(r'\')) return '不能包含路径分隔符';
    if (v.length > 24) return '太长了（24 个字符以内）';
    return null;
  }

  // ---------------------------------------------------------------- 写盘

  /// 把当前表单写回 character.json（未知字段原样保留）。
  /// 返回是否成功；失败时保留草稿状态（不更新签名）。
  Future<bool> _persist({bool notify = true}) async {
    final id = _selected;
    if (id == null) return false;
    try {
      final out = <String, Object?>{..._raw};
      out['id'] = id;
      out['prompt'] = _prompt?.text ?? '';
      out['defaultState'] = _defaultState;
      out['defaultEmotion'] = _defaultEmotion;
      out['states'] = <String>[..._states];
      out['emotions'] = <String>[..._emotions];
      // 写盘是异步的，期间用户还能继续输入：先把「这一份内容」的签名固定下来。
      // 写完再拿当时的表单去算签名，就会出现「磁盘存的是 A、界面以为 B 已保存」。
      final savedSignature = _formSignature();
      await _store.writeJson(
          widget.slug, 'characters/$id/character.json', out);
      if (!mounted) return false;
      _raw = out;
      _savedSignature = savedSignature;
      // 与「当前表单」重新比对：保存期间又改了 → 立刻继续算脏。
      final stillDirty = _formSignature() != _savedSignature;
      _lastReportedDirty = stillDirty;
      widget.onDirtyChanged?.call(stillDirty);
      if (notify) widget.onSaved?.call();
      return true;
    } catch (e) {
      _toast('保存失败：$e');
      return false;
    }
  }

  Future<void> _saveBasic() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _persist();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _select(String id) async {
    if (id == _selected) return;
    // 用全表单脏检测（不只 prompt）：改了默认状态/情绪没保存也要保护。
    if (_dirty) {
      if (_busy) return; // 正在保存：不让切换打断
      setState(() => _busy = true);
      bool ok;
      try {
        ok = await _persist();
      } catch (_) {
        ok = false;
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      // 保存失败：留在当前角色，草稿还在，不切换。
      if (!ok || !mounted) return;
    }
    setState(() {
      _selected = id;
      _loadCharacter();
    });
  }

  // ------------------------------------------------------------ 新建 / 删除

  Future<void> _newCharacter() async {
    final id = await askStudioName(
      context,
      _t,
      title: '新建角色',
      hint: '戒戒',
      note: '角色 id 同时是目录名（characters/<id>/）与游戏内显示的名字。'
          '默认建好一状态一情绪（便服 × 平常），你可以随时增删。',
      exists: (v) => _ids.contains(v),
      extraCheck: _nameCheck,
    );
    if (id == null || !mounted) return;
    await _run(() async {
      await _store.writeJson(
        widget.slug,
        'characters/$id/character.json',
        <String, Object?>{
          'id': id,
          'prompt': _starterPrompt(id),
          'defaultState': '便服',
          'defaultEmotion': '平常',
          'states': <String>['便服'],
          'emotions': <String>['平常'],
        },
      );
      if (!mounted) return;
      setState(() {
        _selected = id;
        _load();
      });
      widget.onSaved?.call();
      _toast('已新建角色「$id」：去立绘矩阵导入图片吧');
    });
  }

  Future<void> _deleteCharacter() async {
    final id = _selected;
    if (id == null) return;
    final ok = await _confirm(
      title: '删除角色「$id」？',
      body: '会删掉整个 characters/$id/ 目录：character.json 与里面全部立绘。'
          '指向它的出场角色会变成「角色不存在」（体检报 error）。删除不可撤销。',
      confirmText: '删除角色',
    );
    if (ok != true || !mounted) return;
    await _run(() async {
      await _store.deletePath(widget.slug, 'characters/$id');
      if (!mounted) return;
      setState(() {
        _selected = null;
        _load();
      });
      widget.onSaved?.call();
      _toast('已删除角色「$id」');
    });
  }

  // ------------------------------------------------------------ 状态 / 情绪

  Future<void> _addState() async {
    final name = await askStudioName(
      context,
      _t,
      title: '添加状态',
      hint: '便服 / 校服猫化',
      note: '状态 = 服装 × 形态。同一幕里只能在这一个状态内换表情，不跨状态。',
      exists: (v) => _states.contains(v),
      extraCheck: _nameCheck,
      confirmLabel: '添加',
    );
    if (name == null || !mounted) return;
    await _run(() async {
      setState(() {
        _states = <String>[..._states, name];
        if (_defaultState.isEmpty) _defaultState = name;
      });
      await _persist();
      if (!mounted) return;
      setState(() {});
      _toast('已添加状态「$name」：现在给这一行导入立绘');
    });
  }

  Future<void> _renameState(String old) async {
    final name = await askStudioName(
      context,
      _t,
      title: '重命名状态「$old」',
      hint: old,
      note: '会把该状态下已有的立绘一起改名（情绪部分不变）：'
          '「${old}_平常.png」→「新名字_平常.png」。不会丢图。'
          '引用这个状态的情景也会同步更新。',
      exists: (v) => _states.contains(v) && v != old,
      extraCheck: _nameCheck,
      confirmLabel: '改名',
    );
    if (name == null || !mounted) return;
    final id = _selected!;
    await _run(() async {
      var renamed = 0;
      for (final f in <String>[..._allFiles]) {
        final low = f.toLowerCase();
        if (!isStudioImage(low)) continue;
        if (!low.startsWith('${old.toLowerCase()}_')) continue;
        final to = '$name${f.substring(old.length)}';
        final ok = await _store.renamePath(
          widget.slug,
          'characters/$id/$f',
          'characters/$id/$to',
        );
        if (ok) renamed++;
      }
      // 同步引用这个状态的情景：否则改名后情景里的 state 还是旧值，
      // 立绘表会解析不到图（表情永远不动）。
      final scenesUpdated =
          await _syncSceneRefs(charId: id, stateFrom: old, stateTo: name);
      if (!mounted) return;
      setState(() {
        _states = <String>[for (final s in _states) s == old ? name : s];
        if (_defaultState == old) _defaultState = name;
        _refreshFiles();
      });
      await _persist();
      if (!mounted) return;
      _toast(renamed == 0
          ? '已改名状态「$old」→「$name」（这个状态还没有立绘）'
              '${scenesUpdated > 0 ? '；同步更新了 $scenesUpdated 幕情景' : ''}'
          : '已改名状态，把 $renamed 张立绘改成新名字'
              '${scenesUpdated > 0 ? '，并同步更新了 $scenesUpdated 幕情景' : ''}');
    });
  }

  Future<void> _deleteState(String state) async {
    final id = _selected!;
    final victims = <String>[
      for (final f in _allFiles)
        if (isStudioImage(f) &&
            f.toLowerCase().startsWith('${state.toLowerCase()}_'))
          f,
    ];
    final ok = await _confirm(
      title: '删除状态「$state」？',
      body: victims.isEmpty
          ? '这个状态还没有导入立绘。删掉后它不再出现在状态列表里。'
          : '会同时删掉这个状态下的 ${victims.length} 张立绘：${victims.join('、')}。'
              '删除不可撤销（其它状态的图不受影响）。',
      confirmText: '删除状态',
    );
    if (ok != true || !mounted) return;
    await _run(() async {
      for (final f in victims) {
        await _store.deletePath(widget.slug, 'characters/$id/$f');
      }
      if (!mounted) return;
      setState(() {
        _states = <String>[..._states.where((s) => s != state)];
        if (_defaultState == state) {
          _defaultState = _states.isNotEmpty ? _states.first : '';
        }
        _refreshFiles();
      });
      await _persist();
      if (!mounted) return;
      _toast('已删除状态「$state」');
    });
  }

  Future<void> _addEmotion() async {
    final name = await askStudioName(
      context,
      _t,
      title: '添加情绪',
      hint: '开心 / 害羞',
      note: '情绪词会作为「可用情绪」提交给模型，模型每一段都要从里面选一个。'
          '名字要短、彼此区别明显。',
      exists: (v) => _emotions.contains(v),
      extraCheck: _nameCheck,
      confirmLabel: '添加',
    );
    if (name == null || !mounted) return;
    await _run(() async {
      setState(() {
        _emotions = <String>[..._emotions, name];
        if (_defaultEmotion.isEmpty) _defaultEmotion = name;
      });
      await _persist();
      if (!mounted) return;
      setState(() {});
      _toast('已添加情绪「$name」：这一列每个状态都要补一张图');
    });
  }

  Future<void> _renameEmotion(String old) async {
    final name = await askStudioName(
      context,
      _t,
      title: '重命名情绪「$old」',
      hint: old,
      note: '会把每个状态里这一列立绘一起改名（状态部分不变）：'
          '「便服_$old.png」→「便服_新名字.png」。'
          '引用这个情绪的情景也会同步更新。',
      exists: (v) => _emotions.contains(v) && v != old,
      extraCheck: _nameCheck,
      confirmLabel: '改名',
    );
    if (name == null || !mounted) return;
    final id = _selected!;
    await _run(() async {
      var renamed = 0;
      for (final f in <String>[..._allFiles]) {
        final low = f.toLowerCase();
        if (!isStudioImage(low)) continue;
        final stem = _stem(f);
        if (!stem.toLowerCase().endsWith('_${old.toLowerCase()}')) continue;
        if (stem.length <= old.length) continue;
        // 砍掉末尾的情绪部分（含下划线），换成新名字，扩展名原样保留。
        final to = '${stem.substring(0, stem.length - old.length)}$name'
            '${f.substring(stem.length)}';
        final ok = await _store.renamePath(
          widget.slug,
          'characters/$id/$f',
          'characters/$id/$to',
        );
        if (ok) renamed++;
      }
      // 同步引用这个情绪的情景。
      final scenesUpdated =
          await _syncSceneRefs(charId: id, emotionFrom: old, emotionTo: name);
      if (!mounted) return;
      setState(() {
        _emotions = <String>[for (final e in _emotions) e == old ? name : e];
        if (_defaultEmotion == old) _defaultEmotion = name;
        _refreshFiles();
      });
      await _persist();
      if (!mounted) return;
      _toast(renamed == 0
          ? '已改名情绪「$old」→「$name」'
              '${scenesUpdated > 0 ? '；同步更新了 $scenesUpdated 幕情景' : ''}'
          : '已改名情绪，改了 $renamed 张立绘的文件名'
              '${scenesUpdated > 0 ? '，并同步更新了 $scenesUpdated 幕情景' : ''}');
    });
  }

  /// 把引用了某个角色 state/emotion 的情景同步改成新名字。
  /// 返回更新的幕数。改名只更新 characters[].state / emotion 字段。
  Future<int> _syncSceneRefs({
    required String charId,
    String? stateFrom,
    String? stateTo,
    String? emotionFrom,
    String? emotionTo,
  }) async {
    var updated = 0;
    final storyIds = sceneIdsOf(_store, widget.slug);
    for (final sid in storyIds) {
      final raw = _store.readJson(widget.slug, 'stories/$sid.json');
      if (raw == null) continue;
      final chars = raw['characters'];
      if (chars is! List) continue;
      var changed = false;
      final newChars = <Object?>[];
      for (final c in chars) {
        if (c is! Map) {
          newChars.add(c);
          continue;
        }
        final m = Map<String, Object?>.from(c);
        if ('${m['charId'] ?? ''}' != charId) {
          newChars.add(c);
          continue;
        }
        if (stateFrom != null &&
            stateTo != null &&
            '${m['state'] ?? ''}' == stateFrom) {
          m['state'] = stateTo;
          changed = true;
        }
        if (emotionFrom != null &&
            emotionTo != null &&
            '${m['emotion'] ?? ''}' == emotionFrom) {
          m['emotion'] = emotionTo;
          changed = true;
        }
        newChars.add(m);
      }
      if (changed) {
        raw['characters'] = newChars;
        await _store.writeJson(widget.slug, 'stories/$sid.json', raw);
        updated++;
      }
    }
    return updated;
  }

  Future<void> _deleteEmotion(String emotion) async {
    final id = _selected!;
    final victims = <String>[
      for (final f in _allFiles)
        if (isStudioImage(f) &&
            _stem(f).toLowerCase().endsWith('_${emotion.toLowerCase()}') &&
            _stem(f).length > emotion.length)
          f,
    ];
    final ok = await _confirm(
      title: '删除情绪「$emotion」？',
      body: victims.isEmpty
          ? '所有状态里这一列都还没有图。删掉后它不再出现在情绪列表里。'
          : '会同时删掉这一列 ${victims.length} 张立绘：${victims.join('、')}。'
              '删除不可撤销。',
      confirmText: '删除情绪',
    );
    if (ok != true || !mounted) return;
    await _run(() async {
      for (final f in victims) {
        await _store.deletePath(widget.slug, 'characters/$id/$f');
      }
      if (!mounted) return;
      setState(() {
        _emotions = <String>[..._emotions.where((e) => e != emotion)];
        if (_defaultEmotion == emotion) {
          _defaultEmotion = _emotions.isNotEmpty ? _emotions.first : '';
        }
        _refreshFiles();
      });
      await _persist();
      if (!mounted) return;
      _toast('已删除情绪「$emotion」');
    });
  }

  // ------------------------------------------------------------ 立绘

  Future<void> _importPortrait(String state, String emotion) async {
    final name = _portraitName(state, emotion);
    // 标题里直接写出**目标文件名**：选的时候就知道它会被改名成什么。
    final picked = await pickStudioImages(dialogTitle: '选择立绘 → 存为 $name');
    if (picked.isEmpty || !mounted) return;
    await _importPortraitFile(state, emotion, picked.first);
  }

  /// 单张立绘落盘（目标格子已有图时先确认覆盖）。
  ///
  /// 矩阵格子点导入、「批量」里只选了一张，都走这一条路。
  /// [note] 是给用户的一句额外说明（例如「情绪是按文件名猜的」）。
  Future<void> _importPortraitFile(
    String state,
    String emotion,
    PlatformFile file, {
    String? note,
  }) async {
    if (!mounted) return;
    final name = _portraitName(state, emotion);
    final tail = note == null ? '' : '（$note）';
    // 选中的文件叫什么不重要：落盘一律按矩阵格子命名（状态_情绪.png），
    // 这里把「原名 → 新名」写清楚，免得作者以为自己导入时改错了名。
    final renamed = file.name == name ? '' : '（原文件 ${file.name}）';
    if (_hasPortrait(state, emotion)) {
      final ok = await _confirm(
        title: '覆盖 $name？',
        body: '这个格子已经有图了，导入会覆盖它$tail。',
        confirmText: '覆盖',
      );
      if (ok != true || !mounted) return;
    }
    await _run(() async {
      final bytes = await readStudioImageBytes(file);
      if (!mounted) return;
      await _store.writeBytes(
        widget.slug,
        'characters/${_selected!}/$name',
        bytes,
      );
      if (!mounted) return;
      setState(_refreshFiles);
      widget.onSaved?.call();
      _toast('已导入 → $name$renamed$tail');
    });
  }

  Future<void> _deletePortrait(String state, String emotion) async {
    final name = _portraitName(state, emotion);
    final ok = await _confirm(
      title: '删除 $name？',
      body: '只删这一张图（格子会变回空的，体检会报缺立绘）。',
      confirmText: '删除',
    );
    if (ok != true || !mounted) return;
    await _run(() async {
      await _store.deletePath(
        widget.slug,
        'characters/${_selected!}/$name',
      );
      if (!mounted) return;
      setState(_refreshFiles);
      widget.onSaved?.call();
      _toast('已删除 $name');
    });
  }

  /// 一次性把一个状态的若干张图按情绪落盘。
  ///
  /// 选多张时先弹窗（缩略图 + 文件名 + 情绪 + 跳过）：情绪按文件名猜着预选，
  /// 猜不出的按情绪列表顺序补一个这次还没选过的，多数情况不用手改；
  /// 只选了一张则**不弹窗**，直接按猜到的情绪导入。
  Future<void> _batchImport(String state) async {
    final files = await pickStudioImages(
      multiple: true,
      dialogTitle: '给「$state」选多张立绘（可多选）',
    );
    if (files.isEmpty || !mounted) return;
    if (_emotions.isEmpty) {
      _toast('这个角色还没有声明任何情绪：先加几个情绪，再批量导入');
      return;
    }

    // 只有一张：等同矩阵格子点导入（猜不出情绪就取情绪列表第一个）。
    if (files.length == 1) {
      final file = files.first;
      final emotion =
          guessEmotionFromFileName(file.name, _emotions) ?? _emotions.first;
      await _importPortraitFile(
        state,
        emotion,
        file,
        note: '「${file.name}」猜成「$emotion」，不对就点格子换图',
      );
      return;
    }

    final picks = await showDialog<List<(int, String)>>(
      context: context,
      builder: (_) => _BatchEmotionDialog(
        theme: _t,
        state: state,
        characterId: _selected ?? '',
        fileNames: <String>[for (final f in files) f.name],
        paths: <String?>[for (final f in files) f.path],
        emotions: _emotions,
        targetName: (emotion) => _portraitName(state, emotion),
        exists: (emotion) => _hasPortrait(state, emotion),
      ),
    );
    if (picks == null || picks.isEmpty || !mounted) return;

    await _run(() async {
      final written = <String>[];
      var overwritten = 0;
      for (final (index, emotion) in picks) {
        if (index < 0 || index >= files.length) continue;
        final name = _portraitName(state, emotion);
        // 覆盖与否要在写之前取：写完 _refreshFiles 就看不出来了。
        final had = _hasPortrait(state, emotion);
        final bytes = await readStudioImageBytes(files[index]);
        if (!mounted) return;
        await _store.writeBytes(
          widget.slug,
          'characters/${_selected!}/$name',
          bytes,
        );
        written.add(name);
        if (had) overwritten++;
      }
      if (!mounted) return;
      setState(_refreshFiles);
      widget.onSaved?.call();
      _toast(
        '已写 ${written.length} 张（覆盖 $overwritten 张）：${written.join('、')}',
      );
    });
  }

  // ---------------------------------------------------------------- 弹窗

  Future<bool?> _confirm({
    required String title,
    required String body,
    required String confirmText,
  }) {
    final t = _t;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: t.card,
        title: Text(title, style: TextStyle(color: t.ink, fontSize: 16)),
        content: Text(
          body,
          style: TextStyle(color: t.sub, fontSize: 12.5, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消', style: TextStyle(color: t.sub)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(confirmText, style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 界面

  @override
  Widget build(BuildContext context) {
    // 帧结束后检查脏状态并上报（覆盖状态/情绪列表变化等非文本路径）。
    WidgetsBinding.instance.addPostFrameCallback((_) => _reportDirty());
    if (_ids.isEmpty) return _emptyGuide();
    return Column(
      children: [
        _selectorBar(),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 28),
            children: [
              _basicSection(),
              _saveButton(),
              _nameListSection(
                title: '状态（服装 × 形态）',
                hintKey: 'char.states',
                note: '一个状态 = 一套外观；同一幕只在这个状态内换表情。'
                    '改名会把已有立绘一起改名，不会丢图。名字里不要用下划线。',
                names: _states,
                defaultName: _defaultState,
                onAdd: _busy ? null : _addState,
                onRename: _busy ? null : _renameState,
                onDelete: _busy ? null : _deleteState,
                emptyNote: '还没有状态：加一个（例如「便服」），立绘矩阵才有行。',
              ),
              _nameListSection(
                title: '情绪（表情词）',
                hintKey: 'char.emotions',
                note: '这些词会作为「可用情绪」提交给模型，模型每段都要选一个；'
                    '名字要短、彼此区别明显。改名会同步重命名立绘文件。',
                names: _emotions,
                defaultName: _defaultEmotion,
                onAdd: _busy ? null : _addEmotion,
                onRename: _busy ? null : _renameEmotion,
                onDelete: _busy ? null : _deleteEmotion,
                emptyNote: '还没有情绪：加几个（例如「平常 / 开心 / 害羞」），矩阵才有列。',
              ),
              _matrixSection(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _emptyGuide() {
    final t = _t;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.lg),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.face_retouching_natural_outlined, size: 42, color: t.sub),
            const SizedBox(height: 12),
            Text(
              '这个工程还没有角色',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: t.ink,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '一个角色 = characters/<角色id>/ 一个目录：'
              '里面放 character.json 与「状态_情绪.png」立绘。\n'
              '新建之后：① 加状态与情绪 ② 导入立绘 ③ 写基础提示词。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, height: 1.7, color: t.sub),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: t.accent,
                foregroundColor: Colors.white,
              ),
              onPressed: _busy ? null : _newCharacter,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('新建角色'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _selectorBar() {
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
                '角色（共 ${_ids.length} 个）',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: t.ink,
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: _busy ? null : _newCharacter,
                icon: Icon(Icons.add_rounded, size: 17, color: t.accent),
                label: Text(
                  '新建角色',
                  style: TextStyle(color: t.accent, fontSize: 12.5),
                ),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                ),
              ),
              TextButton.icon(
                onPressed: _busy ? null : _deleteCharacter,
                icon: const Icon(
                  Icons.delete_outline_rounded,
                  size: 17,
                  color: Colors.red,
                ),
                label: const Text(
                  '删除角色',
                  style: TextStyle(color: Colors.red, fontSize: 12.5),
                ),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                ),
              ),
            ],
          ),
          SizedBox(
            height: 40,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _ids.length,
              separatorBuilder: (context, index) => const SizedBox(width: 6),
              itemBuilder: (context, i) {
                final id = _ids[i];
                final sel = id == _selected;
                return ChoiceChip(
                  label: Text(id),
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
                  onSelected: (_) => _select(id),
                );
              },
            ),
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
      title: '角色基本信息',
      hintKey: 'char.id',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HintLabel(
            theme: t,
            title: '角色 id（目录名 + 游戏内显示名）',
            hintKey: 'char.id',
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            decoration: BoxDecoration(
              color: t.bg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: t.sub.withValues(alpha: 0.25)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    id,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: t.ink,
                    ),
                  ),
                ),
                Text(
                  '改名要做删除重建',
                  style: TextStyle(fontSize: 10.5, color: t.sub),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          HintLabel(
            theme: t,
            title: '基础提示词 prompt',
            hintKey: 'char.prompt',
            required: true,
          ),
          TextField(
            controller: _prompt,
            minLines: 8,
            maxLines: 24,
            style: TextStyle(fontSize: 13, height: 1.5, color: t.ink),
            decoration: const InputDecoration(
              hintText: '例：你是「……」。\n\n身份：\n性格：\n说话：\n动作：一律用全角括号（）写动作与心理。\n边界：不承认自己是 AI；不替玩家决定行动。',
            ),
          ),
          if ((_prompt?.text.trim() ?? '').isEmpty)
            StudioNote(
              theme: t,
              text: '提示词是空的：模型只能靠每幕的情境提示词猜人设（体检会给 warning）。',
              color: Colors.orange,
              icon: Icons.warning_amber_rounded,
            ),
          const SizedBox(height: 12),
          HintLabel(
            theme: t,
            title: '默认状态 / 默认情绪',
            hintKey: 'char.defaults',
          ),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('默认状态', style: TextStyle(fontSize: 11, color: t.sub)),
                    const SizedBox(height: 3),
                    StudioDropdown<String>(
                      theme: t,
                      value: _defaultState.isEmpty ? null : _defaultState,
                      options: <(String, String)>[
                        for (final s in _states) (s, s),
                      ],
                      placeholder: _states.isEmpty ? '还没声明状态' : '选一个状态',
                      onChanged: (v) => setState(() => _defaultState = v ?? ''),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('默认情绪', style: TextStyle(fontSize: 11, color: t.sub)),
                    const SizedBox(height: 3),
                    StudioDropdown<String>(
                      theme: t,
                      value: _defaultEmotion.isEmpty ? null : _defaultEmotion,
                      options: <(String, String)>[
                        for (final e in _emotions) (e, e),
                      ],
                      placeholder: _emotions.isEmpty ? '还没声明情绪' : '选一个情绪',
                      onChanged: (v) => setState(() => _defaultEmotion = v ?? ''),
                    ),
                  ],
                ),
              ),
            ],
          ),
          StudioNote(
            theme: t,
            text: '「${_defaultState}_$_defaultEmotion」这一张立绘建议一定要有：'
                '模型答了表外的词时会兜底到它。改完记得点下面的保存。',          ),
        ],
      ),
    );
  }

  Widget _saveButton() {
    final t = _t;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: t.accent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              minimumSize: const Size(double.infinity, 0),
            ),
            onPressed: _busy ? null : _saveBasic,
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined, size: 18),
            label: Text(_dirtyPrompt ? '保存角色（有未保存的提示词）' : '保存角色'),
          ),
          const SizedBox(height: 4),
          StudioNote(
            theme: t,
            text: '这里保存的是提示词与默认项；状态 / 情绪 / 立绘的增删改会立刻写入工程。',
          ),
        ],
      ),
    );
  }

  Widget _nameListSection({
    required String title,
    required String hintKey,
    required String note,
    required List<String> names,
    required String defaultName,
    required VoidCallback? onAdd,
    required ValueChanged<String>? onRename,
    required ValueChanged<String>? onDelete,
    required String emptyNote,
  }) {
    final t = _t;
    return StudioSection(
      theme: t,
      title: title,
      hintKey: hintKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          StudioNote(theme: t, text: note),
          if (names.isEmpty)
            StudioNote(theme: t, text: emptyNote, color: t.accent)
          else
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final n in names)
                  Container(
                    padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
                    decoration: BoxDecoration(
                      color: t.bg,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: n == defaultName
                            ? t.accent
                            : t.sub.withValues(alpha: 0.25),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          n,
                          style: TextStyle(
                            fontSize: 12.5,
                            color: t.ink,
                            fontWeight: n == defaultName
                                ? FontWeight.w700
                                : FontWeight.w400,
                          ),
                        ),
                        if (n == defaultName) ...[
                          const SizedBox(width: 4),
                          StudioTag(theme: t, text: '默认'),
                        ],
                        const SizedBox(width: 2),
                        InkWell(
                          onTap: onRename == null ? null : () => onRename(n),
                          borderRadius: BorderRadius.circular(10),
                          child: Padding(
                            padding: const EdgeInsets.all(3),
                            child: Icon(
                              Icons.drive_file_rename_outline_rounded,
                              size: 15,
                              color: t.accent,
                            ),
                          ),
                        ),
                        InkWell(
                          onTap: onDelete == null ? null : () => onDelete(n),
                          borderRadius: BorderRadius.circular(10),
                          child: const Padding(
                            padding: EdgeInsets.all(3),
                            child: Icon(
                              Icons.close_rounded,
                              size: 15,
                              color: Colors.red,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          if (names.any((n) => n.contains('_')))
            StudioNote(
              theme: t,
              text: '有名字里带下划线：文件名是「状态_情绪.png」，下划线会被切错，建议改名。',
              color: Colors.red,
              icon: Icons.error_outline_rounded,
            ),
          const SizedBox(height: 6),
          OutlinedButton.icon(
            onPressed: onAdd,
            icon: Icon(Icons.add_rounded, size: 18, color: t.accent),
            label: Text(
              names.isEmpty ? '添加一个' : '再添加一个',
              style: TextStyle(color: t.accent, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _matrixSection() {
    final t = _t;
    final total = _states.length * _emotions.length;
    final missing = _missingCount;
    final have = total - missing;
    return StudioSection(
      theme: t,
      title: '立绘矩阵',
      hintKey: 'char.portraits',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (total > 0)
                StudioTag(
                  theme: t,
                  text: missing == 0 ? '立绘齐全（$total 张）' : '$missing 个格子缺图',
                  color: missing == 0 ? t.accent : Colors.red,
                ),
              const Spacer(),
              if (total > 0)
                Text(
                  '已导入 $have / $total',
                  style: TextStyle(fontSize: 11.5, color: t.sub),
                ),
            ],
          ),
          const SizedBox(height: 6),
          StudioNote(
            theme: t,
            text: '命名就是约定：每格的文件名是「状态_情绪.png」。'
                '点空格子导入单张（再点格子可换图）；点每行左边的「导入」一次选多张，'
                '再给每张挑情绪。体检会因为缺图报 error，所以矩阵要填满。',
          ),
          if (_states.isEmpty || _emotions.isEmpty)
            StudioNote(
              theme: t,
              text: _states.isEmpty
                  ? '先加至少一个状态，矩阵才有行。'
                  : '先加至少一个情绪，矩阵才有列。',
              color: t.accent,
            )
          else
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      SizedBox(
                        width: 116,
                        child: Text(
                          '状态 \\ 情绪',
                          style: TextStyle(fontSize: 10.5, color: t.sub),
                        ),
                      ),
                      for (final e in _emotions)
                        SizedBox(
                          width: 78,
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text(
                              e,
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w700,
                                color: t.ink,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  for (final s in _states)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 116,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: Text(
                                  s,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w700,
                                    color: t.ink,
                                  ),
                                ),
                              ),
                              TextButton.icon(
                                onPressed:
                                    _busy ? null : () => _batchImport(s),
                                icon: Icon(
                                  Icons.add_photo_alternate_outlined,
                                  size: 14,
                                  color: t.accent,
                                ),
                                label: Text(
                                  '导入',
                                  style: TextStyle(
                                    color: t.accent,
                                    fontSize: 11,
                                  ),
                                ),
                                style: TextButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  padding: EdgeInsets.zero,
                                  minimumSize: const Size(0, 26),
                                ),
                              ),
                            ],
                          ),
                        ),
                        for (final e in _emotions) _cell(s, e),
                      ],
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _cell(String state, String emotion) {
    final t = _t;
    final name = _portraitName(state, emotion);
    final has = _hasPortrait(state, emotion);
    return SizedBox(
      width: 78,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 4, bottom: 2),
            child: Stack(
              children: [
                InkWell(
                  onTap: _busy
                      ? null
                      : () => _importPortrait(state, emotion),
                  borderRadius: BorderRadius.circular(10),
                  child: has
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Image.file(
                            File(_absPath(name)),
                            key: ValueKey('$name-$_stamp'),
                            width: 70,
                            height: 62,
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stack) => Container(
                              width: 70,
                              height: 62,
                              alignment: Alignment.center,
                              color: t.bg,
                              child: Icon(
                                Icons.broken_image_outlined,
                                size: 18,
                                color: t.sub,
                              ),
                            ),
                          ),
                        )
                      : CustomPaint(
                          painter: DashedBorderPainter(
                            color: t.sub.withValues(alpha: 0.6),
                          ),
                          child: Container(
                            width: 70,
                            height: 62,
                            alignment: Alignment.center,
                            child: Icon(
                              Icons.add_rounded,
                              size: 22,
                              color: t.accent,
                            ),
                          ),
                        ),
                ),
                if (has)
                  Positioned(
                    top: 0,
                    right: 0,
                    child: InkWell(
                      onTap: _busy
                          ? null
                          : () => _deletePortrait(state, emotion),
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          color: t.card.withValues(alpha: 0.9),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: t.sub.withValues(alpha: 0.3),
                          ),
                        ),
                        child: const Icon(
                          Icons.close_rounded,
                          size: 13,
                          color: Colors.red,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Text(
            name,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 9,
              height: 1.2,
              color: has ? t.sub : Colors.red,
            ),
          ),
        ],
      ),
    );
  }
}

/// 批量导入时的「每张图挑一个情绪」弹窗。
///
/// 每行：缩略图 + 文件名 + 情绪下拉 + 跳过 —— 不用再靠记「第几张是哪张」。
/// 情绪按文件名猜着预选（见 [guessEmotionFromFileName]），猜不出的按情绪列表
/// 顺序补一个本次还没被选过的，尽量避免两张图抢同一个格子。
class _BatchEmotionDialog extends StatefulWidget {
  const _BatchEmotionDialog({
    required this.theme,
    required this.state,
    required this.characterId,
    required this.fileNames,
    required this.paths,
    required this.emotions,
    required this.targetName,
    required this.exists,
  });

  final ChatGalTheme theme;
  final String state;

  /// 落盘目录 characters/<角色id>/ 的那一节，用来把路径写清楚。
  final String characterId;
  final List<String> fileNames;

  /// 本地路径；Android SAF 下可能为 null，那时缩略图显示占位图标。
  final List<String?> paths;
  final List<String> emotions;
  final String Function(String emotion) targetName;
  final bool Function(String emotion) exists;

  @override
  State<_BatchEmotionDialog> createState() => _BatchEmotionDialogState();
}

class _BatchEmotionDialogState extends State<_BatchEmotionDialog> {
  /// 每张图选的情绪；null = 还没选（例如猜不出、情绪又都被占完了）。
  late final List<String?> _picked;

  /// 跳过这张：不写盘。默认全部参与。
  late final List<bool> _skipped;

  @override
  void initState() {
    super.initState();
    final n = widget.fileNames.length;
    _picked = List<String?>.filled(n, null);
    _skipped = List<bool>.filled(n, false);
    final used = <String>{};
    for (var i = 0; i < n; i++) {
      final guess = guessEmotionFromFileName(widget.fileNames[i], widget.emotions);
      if (guess != null) {
        _picked[i] = guess;
        used.add(guess);
        continue;
      }
      // 猜不出：按情绪列表顺序取一个这次还没选过的（免得重复盖掉前一张）。
      final next = _firstUnused(used);
      if (next == null) continue;
      _picked[i] = next;
      used.add(next);
    }
  }

  String? _firstUnused(Set<String> used) {
    for (final e in widget.emotions) {
      if (!used.contains(e)) return e;
    }
    return null;
  }

  /// 参与导入的行号（没被跳过的）。
  List<int> get _participants => <int>[
        for (var i = 0; i < _skipped.length; i++)
          if (!_skipped[i]) i,
      ];

  List<(int, String)> _picks() => <(int, String)>[
        for (final i in _participants)
          if (_picked[i] != null) (i, _picked[i]!),
      ];

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    final participants = _participants;
    final targets = <String>[
      for (final i in participants)
        if (_picked[i] != null) widget.targetName(_picked[i]!),
    ];
    final duplicated = targets.length != targets.toSet().length;
    final overwrites = <String>[
      for (final i in participants)
        if (_picked[i] != null && widget.exists(_picked[i]!))
          '${widget.fileNames[i]} → ${widget.targetName(_picked[i]!)}',
    ];
    final missed = <int>[
      for (final i in participants)
        if (_picked[i] == null) i,
    ];
    final canImport = participants.isNotEmpty && missed.isEmpty;
    final dir = 'characters/${widget.characterId}';
    return AlertDialog(
      backgroundColor: t.card,
      title: Text(
        '给「${widget.state}」的 ${widget.fileNames.length} 张图挑情绪',
        style: TextStyle(color: t.ink, fontSize: 16),
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '每张图都会写进 $dir/${widget.state}_<情绪>.png'
                '（原图扩展名一律按 .png 落盘，游戏只认这个文件名）。\n'
                '情绪已按文件名猜好，对不上就在下拉里改；不想导入的按 ✕ 跳过，'
                '跳过的不会写盘。',
                style: TextStyle(fontSize: 11.5, height: 1.5, color: t.sub),
              ),
              const SizedBox(height: 8),
              if (participants.isEmpty)
                StudioNote(
                  theme: t,
                  text: '已经全部跳过了：没有要写盘的文件。',
                  color: Colors.orange,
                  icon: Icons.info_outline_rounded,
                ),
              if (overwrites.isNotEmpty)
                StudioNote(
                  theme: t,
                  text: '会覆盖已有的 ${overwrites.length} 张：'
                      '${overwrites.join('、')}',
                  color: Colors.red,
                  icon: Icons.warning_amber_rounded,
                ),
              if (missed.isNotEmpty)
                StudioNote(
                  theme: t,
                  text: '还有 ${missed.length} 张没选情绪：都给它们挑一个，'
                      '或者按 ✕ 跳过。',
                  color: Colors.orange,
                  icon: Icons.error_outline_rounded,
                ),
              if (duplicated)
                StudioNote(
                  theme: t,
                  text: '有两张图挑了同一个情绪：后一张会覆盖前一张（只剩一张）。',
                  color: Colors.orange,
                  icon: Icons.warning_amber_rounded,
                ),
              if (overwrites.isNotEmpty || missed.isNotEmpty || duplicated)
                const SizedBox(height: 6),
              for (var i = 0; i < widget.fileNames.length; i++) _row(i),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('取消', style: TextStyle(color: t.sub)),
        ),
        TextButton(
          onPressed: canImport ? () => Navigator.of(context).pop(_picks()) : null,
          child: Text(
            canImport
                ? '导入 ${participants.length} 张'
                : (missed.isEmpty ? '没有要导入的图' : '还有 ${missed.length} 张没选情绪'),
            style: TextStyle(
              color: canImport ? t.accent : t.sub,
              fontSize: 13,
            ),
          ),
        ),
      ],
    );
  }

  /// 一行：缩略图 + 文件名 + 情绪 + 跳过。
  Widget _row(int i) {
    final t = widget.theme;
    final skipped = _skipped[i];
    final emotion = _picked[i];
    final path = i < widget.paths.length ? widget.paths[i] : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Opacity(
        opacity: skipped ? 0.45 : 1,
        child: Row(
          children: [
            _thumb(path, t),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.fileNames[i],
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: t.ink,
                      decoration: skipped ? TextDecoration.lineThrough : null,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    skipped
                        ? '跳过：不写盘'
                        : '→ ${widget.state}_${emotion ?? '?'}.png',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10.5, color: t.sub),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            SizedBox(
              width: 96,
              child: StudioDropdown<String>(
                theme: t,
                value: emotion,
                dense: true,
                placeholder: '选情绪',
                options: <(String, String)>[
                  for (final e in widget.emotions) (e, e),
                ],
                onChanged: skipped
                    ? null
                    : (v) => setState(() => _picked[i] = v),
              ),
            ),
            const SizedBox(width: 2),
            Tooltip(
              message: skipped ? '重新参与这张' : '跳过这张（不写盘）',
              child: IconButton(
                onPressed: () => setState(() => _skipped[i] = !_skipped[i]),
                icon: Icon(
                  skipped ? Icons.undo_rounded : Icons.close_rounded,
                  size: 18,
                ),
                color: skipped ? t.accent : t.sub,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 56×56 圆角缩略图；拿不到路径或读不出图时给占位图标。
  Widget _thumb(String? path, ChatGalTheme t) {
    const size = 56.0;
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: size,
        height: size,
        color: t.bg,
        alignment: Alignment.center,
        child: path == null || path.isEmpty
            ? _thumbFallback(t)
            : Image.file(
                File(path),
                width: size,
                height: size,
                fit: BoxFit.cover,
                cacheWidth: 112,
                errorBuilder: (context, error, stack) => _thumbFallback(t),
              ),
      ),
    );
  }

  Widget _thumbFallback(ChatGalTheme t) => Icon(
        Icons.image_not_supported_outlined,
        size: 20,
        color: t.sub,
      );
}

/// 按文件名猜情绪。猜不出返回 null。
///
/// 优先级：
/// ① 去掉扩展名后**完全等于**某个已声明情绪；
/// ② 以 `_<情绪>` 结尾（也就是标准的「状态_情绪」命名，多个命中取最长）；
/// ③ 文件名里**包含**某个情绪词（取最长匹配，「不开心」优先于「开心」）。
String? guessEmotionFromFileName(String fileName, List<String> emotions) {
  if (emotions.isEmpty) return null;
  var stem = fileName;
  final dot = stem.lastIndexOf('.');
  if (dot > 0) stem = stem.substring(0, dot);
  if (stem.isEmpty) return null;
  final low = stem.toLowerCase();

  // ① 整个文件名就是某个情绪。
  for (final e in emotions) {
    if (e.isNotEmpty && low == e.toLowerCase()) return e;
  }

  // ② 以 `_<情绪>` 结尾：标准命名「状态_情绪」。
  String? tail;
  for (final e in emotions) {
    if (e.isEmpty || !low.endsWith('_${e.toLowerCase()}')) continue;
    if (tail == null || e.length > tail.length) tail = e;
  }
  if (tail != null) return tail;

  // ③ 包含情绪词：取最长匹配。
  String? hit;
  for (final e in emotions) {
    if (e.isEmpty || !low.contains(e.toLowerCase())) continue;
    if (hit == null || e.length > hit.length) hit = e;
  }
  return hit;
}

/// 虚线边框（缺图格子）。
class DashedBorderPainter extends CustomPainter {
  DashedBorderPainter({required this.color, this.radius = 10, this.dash = 4, this.gap = 3});

  final Color color;
  final double radius;
  final double dash;
  final double gap;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)),
      );
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        final next = (d + dash).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(d, next), paint);
        d = next + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant DashedBorderPainter old) =>
      old.color != color || old.radius != radius;
}

String _starterPrompt(String id) => '你是「$id」。\n\n'
    '身份：\n'
    '性格：\n'
    '说话：短句为主，常有停顿与没说出口的半句。\n'
    '动作：一律用全角括号（）写动作与心理，例如（她把袖子攥紧，又松开）。\n'
    '边界：不承认自己是 AI 或模型；不替玩家决定行动；不提前宣布结局；不跳出当前场景说话。';

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
