import 'package:flutter/material.dart';
import 'package:gal_protocol/gal_protocol.dart';
import 'package:gal_storage/gal_storage.dart';

import '../../app/app_services.dart';
import '../../design_system/tokens.dart';
import 'character_editor.dart';
import 'event_editor.dart';
import 'hints.dart';
import 'manifest_editor.dart';
import 'scene_editor.dart';

/// 内容包创作台的**编辑器**：一个工程（= 一棵包目录树）的全部内容都在这里改。
///
/// 四个页签对应四类东西：基础信息（manifest + 变量）/ 角色（character.json + 立绘）/
/// 情景（`stories/*.json`）/ 事件（`events/<事件id>/event.json`）。
/// 作者不需要碰 JSON：每个字段都有「一句话说明」，点一下展开细节。
class StudioEditorPage extends StatefulWidget {
  const StudioEditorPage({
    super.key,
    required this.theme,
    required this.services,
    required this.slug,
  });

  final ChatGalTheme theme;
  final AppServices services;

  /// 工程目录名（工程的身份就是它，不是 packageId）。
  final String slug;

  @override
  State<StudioEditorPage> createState() => _StudioEditorPageState();
}

class _StudioEditorPageState extends State<StudioEditorPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 4, vsync: this);
  int _lastIndex = 0;

  /// 保存计数 + 每个页签「最后一次重建时的保存计数」。
  /// 某个页签被改过之后，别的页签下次切进来时重建（重读磁盘），
  /// 这样新增的角色/变量会出现在情景的下拉框里。
  int _saves = 0;
  final List<int> _seen = <int>[0, 0, 0, 0];
  final List<int> _epoch = <int>[0, 0, 0, 0];

  /// 每个页签是否有未保存修改（由编辑器通过 onDirtyChanged 上报）。
  final List<bool> _dirty = <bool>[false, false, false, false];

  /// 最近一次体检结果：右上角按钮的图标与颜色跟着它走（error 红 / warning 橙 /
  /// 通过绿）。`check` 是同步的，所以初始化、切页签、每次保存后都能立刻刷新。
  StudioCheckResult? _health;

  StudioStore get _store => widget.services.studio;

  @override
  void initState() {
    super.initState();
    _tabs.addListener(_onTabChanged);
    _refreshHealth();
  }

  void _refreshHealth() {
    try {
      _health = _store.check(widget.slug);
    } catch (_) {
      _health = null;
    }
  }

  /// 编辑器上报脏状态：切页签时据此决定要不要重建。
  void _onDirtyChanged(int tabIndex, bool dirty) {
    if (_dirty[tabIndex] == dirty) return;
    setState(() => _dirty[tabIndex] = dirty);
  }

  /// 体检按钮的图标 / 文字 / 提示：跟随**最严重**的那一级（error 红、warning 橙、通过绿）。
  IconData get _healthIcon {
    final h = _health;
    if (h == null || !h.loaded) return Icons.fact_check_outlined;
    if (h.errors.isNotEmpty) return Icons.error_outline_rounded;
    if (h.warnings.isNotEmpty) return Icons.warning_amber_rounded;
    return Icons.verified_outlined;
  }

  Color _healthColor(ChatGalTheme t) {
    final h = _health;
    if (h == null) return t.sub;
    if (!h.loaded) return Colors.red.shade400;
    if (h.errors.isNotEmpty) return Colors.red.shade400;
    if (h.warnings.isNotEmpty) return Colors.orange.shade800;
    return Colors.green.shade600;
  }

  String get _healthLabel => _health == null ? '体检' : '体检';

  String get _healthTooltip {
    final h = _health;
    if (h == null) return '体检：还没检查过，点一下跑一次';
    if (!h.loaded) return '体检：工程读不出来（${h.loadError ?? '结构不对'}）';
    if (h.errors.isNotEmpty) {
      return '体检：${h.errors.length} 个错误'
          '${h.warnings.isEmpty ? '' : '、${h.warnings.length} 个警告'}';
    }
    if (h.warnings.isNotEmpty) return '体检：${h.warnings.length} 个警告（能装能玩，建议修）';
    return '体检：通过';
  }

  @override
  void dispose() {
    _tabs.removeListener(_onTabChanged);
    _tabs.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (_tabs.index == _lastIndex) return;
    final to = _tabs.index;
    _lastIndex = to;
    setState(_refreshHealth);
    // 进入的页签若磁盘上有更新（别的页签保存过）且它自己是干净的，才重建。
    // 脏页签不重建：重建会丢掉未保存的表单状态。
    if (_seen[to] != _saves && !_dirty[to]) {
      setState(() {
        _seen[to] = _saves;
        _epoch[to]++;
      });
    }
  }

  /// 保存完成回调：[tabIndex] 是发起保存的页签编号。
  /// 必须用固定编号而不是回调时的 _tabs.index —— 异步保存期间
  /// 用户可能已切到别的页签，用当前 index 会把那个页签误标为已保存。
  ///
  /// **这里不再清 `_dirty`**：脏状态统一由编辑器的 `onDirtyChanged` 上报。
  /// 编辑器在写完盘后会把「磁盘快照 vs 当前表单」重新比一次，保存期间用户
  /// 继续输入时它上报的是 `true`；父页面再无条件置 false 就等于把那份未保存
  /// 的修改当成已保存（退出保护与页签重建保护一起失效）。
  void _onSaved(int tabIndex) {
    if (!mounted) return;
    setState(() {
      _saves++;
      _seen[tabIndex] = _saves;
      _refreshHealth();
    });
    // 保存成功但还有草稿（保存期间又改了）时不要把「有未保存修改」的提示吞掉：
    // 只提示一次「已保存」，脏状态由编辑器随后的上报决定。
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_dirty[tabIndex] ? '已保存（表单又有新修改）' : '已保存'),
        duration: const Duration(milliseconds: 900),
      ),
    );
  }

  // ---------------------------------------------------------------- 体检

  Future<void> _check() async {
    StudioCheckResult result;
    try {
      result = _store.check(widget.slug);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('体检失败：$e')),
      );
      return;
    }
    if (!mounted) return;
    setState(() => _health = result);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: widget.theme.card,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _CheckSheet(theme: widget.theme, result: result),
    );
  }

  // ---------------------------------------------------------------- 界面

  String _packageName() {
    final m = _store.readJson(widget.slug, 'manifest.json');
    final name = '${m?['name'] ?? ''}'.trim();
    return name.isEmpty ? widget.slug : name;
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    if (!_store.exists(widget.slug)) {
      return Theme(
        data: t.toThemeData().copyWith(inputDecorationTheme: studioInputTheme(t)),
        child: Scaffold(
          backgroundColor: t.bg,
          appBar: AppBar(title: Text('工程不存在', style: TextStyle(color: t.ink))),
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(Spacing.lg),
              child: Text(
                '找不到工程目录「${widget.slug}」：它可能已经被删掉或改名了。\n返回列表刷新一下。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, height: 1.7, color: t.sub),
              ),
            ),
          ),
        ),
      );
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _confirmExit();
      },
      child: Theme(
        // 创作台里的输入框：边界看得见 + 提示明显更浅（用户反馈「分不清填了没填」）
        data: t.toThemeData().copyWith(inputDecorationTheme: studioInputTheme(t)),
        child: Scaffold(
          backgroundColor: t.bg,
          appBar: AppBar(
          backgroundColor: t.bg,
          foregroundColor: t.ink,
          titleSpacing: 0,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _packageName(),
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: t.ink,
                ),
              ),
              Text(
                widget.slug,
                style: TextStyle(fontSize: 11, color: t.sub),
              ),
            ],
          ),
          actions: [
            Tooltip(
              message: _healthTooltip,
              child: TextButton.icon(
                onPressed: _check,
                icon: Icon(_healthIcon, size: 18, color: _healthColor(t)),
                label: Text(
                  _healthLabel,
                  style: TextStyle(color: _healthColor(t), fontSize: 13),
                ),
              ),
            ),
          ],
          bottom: TabBar(
            controller: _tabs,
            labelColor: t.accent,
            unselectedLabelColor: t.sub,
            indicatorColor: t.accent,
            indicatorSize: TabBarIndicatorSize.tab,
            labelStyle: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
            unselectedLabelStyle: const TextStyle(fontSize: 13),
            tabs: const [
              Tab(text: '基础信息'),
              Tab(text: '角色'),
              Tab(text: '情景'),
              Tab(text: '事件'),
            ],
          ),
        ),
        body: TabBarView(
          controller: _tabs,
          children: [
            ManifestEditor(
              key: ValueKey('manifest-${_epoch[0]}'),
              theme: t,
              services: widget.services,
              slug: widget.slug,
              onSaved: () => _onSaved(0),
              onDirtyChanged: (d) => _onDirtyChanged(0, d),
            ),
            CharacterEditor(
              key: ValueKey('character-${_epoch[1]}'),
              theme: t,
              services: widget.services,
              slug: widget.slug,
              onSaved: () => _onSaved(1),
              onDirtyChanged: (d) => _onDirtyChanged(1, d),
            ),
            SceneEditor(
              key: ValueKey('scene-${_epoch[2]}'),
              theme: t,
              services: widget.services,
              slug: widget.slug,
              onSaved: () => _onSaved(2),
              onDirtyChanged: (d) => _onDirtyChanged(2, d),
            ),
            EventEditor(
              key: ValueKey('event-${_epoch[3]}'),
              theme: t,
              services: widget.services,
              slug: widget.slug,
              onSaved: () => _onSaved(3),
              onDirtyChanged: (d) => _onDirtyChanged(3, d),
            ),
          ],
        ),
        ),
      ),
    );
  }

  /// 退出工程前：有未保存修改时提醒。
  Future<void> _confirmExit() async {
    final anyDirty = _dirty.contains(true);
    if (!anyDirty) {
      Navigator.of(context).pop();
      return;
    }
    final tabs = <String>[
      if (_dirty[0]) '基础信息',
      if (_dirty[1]) '角色',
      if (_dirty[2]) '情景',
      if (_dirty[3]) '事件',
    ];
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: widget.theme.card,
        title: Text('有未保存的修改', style: TextStyle(color: widget.theme.ink)),
        content: Text(
          '「${tabs.join('、')}」有还没保存的修改。离开工程会丢掉这些修改。\n\n'
          '建议先回对应页签保存，再退出。',
          style: TextStyle(color: widget.theme.sub, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消', style: TextStyle(color: widget.theme.sub)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('仍要离开', style: TextStyle(color: Colors.orange.shade800)),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      Navigator.of(context).pop();
    }
  }
}

/// 体检结果：error / warning 分开列，message + path + hint，一键展开全部条目。
class _CheckSheet extends StatefulWidget {
  const _CheckSheet({required this.theme, required this.result});

  final ChatGalTheme theme;
  final StudioCheckResult result;

  @override
  State<_CheckSheet> createState() => _CheckSheetState();
}

class _CheckSheetState extends State<_CheckSheet> {
  bool _detail = true;

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    final r = widget.result;
    final errors = r.errors;
    final warnings = r.warnings;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.82,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 12, 0),
              child: Row(
                children: [
                  Icon(
                    r.ok
                        ? Icons.verified_outlined
                        : Icons.report_problem_outlined,
                    size: 20,
                    color: r.ok ? t.accent : Colors.red,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      r.ok ? '体检通过：能装能玩' : '体检没通过：先修 error',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: r.ok ? t.ink : Colors.red,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: _detail ? '只看结论' : '展开全部条目',
                    onPressed: () => setState(() => _detail = !_detail),
                    icon: Icon(
                      _detail
                          ? Icons.unfold_less_rounded
                          : Icons.unfold_more_rounded,
                      size: 20,
                      color: t.accent,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 2, 18, 6),
              child: Text(
                '体检用的就是安装内容包时那同一套校验器；'
                '体检通过就一定装得上。error 必须修，warning 建议修。',
                style: TextStyle(fontSize: 11.5, height: 1.5, color: t.sub),
              ),
            ),
            Flexible(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(18, 4, 18, 20),
                children: [
                  if (!r.loaded)
                    _entry(
                      t,
                      title: '这个包读不出来',
                      body: r.loadError ?? '未知原因',
                      color: Colors.red,
                    ),
                  _group(
                    t,
                    title: '错误 error（必须修）',
                    items: errors,
                    color: Colors.red,
                  ),
                  _group(
                    t,
                    title: '警告 warning（建议修）',
                    items: warnings,
                    color: Colors.orange,
                  ),
                  if (r.loaded && errors.isEmpty && warnings.isEmpty)
                    _entry(t, title: '没有发现问题', body: '结构、变量、立绘、出口全都对得上。'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _group(
    ChatGalTheme t, {
    required String title,
    required List<ValidationError> items,
    required Color color,
  }) {
    if (items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(
          '$title：无',
          style: TextStyle(fontSize: 12.5, color: t.sub),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 6),
          child: Text(
            '$title 共 ${items.length} 条',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
        ),
        for (final e in items)
          _entry(
            t,
            title: e.message,
            body: [e.path, if (e.hint != null && e.hint!.isNotEmpty) e.hint!]
                .join('\n'),
            color: color,
          ),
      ],
    );
  }

  Widget _entry(
    ChatGalTheme t, {
    required String title,
    required String body,
    Color? color,
  }) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: t.bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: (color ?? t.sub).withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(fontSize: 12.5, height: 1.5, color: t.ink),
          ),
          if (_detail && body.trim().isNotEmpty) ...[
            const SizedBox(height: 5),
            Text(
              body,
              style: TextStyle(fontSize: 11, height: 1.6, color: t.sub),
            ),
          ],
        ],
      ),
    );
  }
}
