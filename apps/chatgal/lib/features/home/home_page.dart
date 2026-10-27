import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal_protocol/gal_protocol.dart';
import 'package:gal_storage/gal_storage.dart';

import '../../app/app_logger.dart';
import '../../app/app_services.dart';
import '../../design_system/tokens.dart';
import '../help/help_about_page.dart';
import '../help/update_service.dart';
import '../library/library_page.dart';
import '../session/chat_page.dart';
import '../settings/model_providers_page.dart';
import '../settings/privacy_page.dart';
import '../settings/settings_page.dart';
import '../studio/studio_page.dart';
import 'home_selector.dart';

/// Home: fixed bg + package intro; bottom sheet snaps collapsed / expanded.
class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.theme,
    required this.services,
    this.onSettingsChanged,
  });

  final ChatGalTheme theme;
  final AppServices services;
  final VoidCallback? onSettingsChanged;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  /// 抽屉收起时占屏幕高度的比例。
  ///
  /// 三处都引用它：sheet 的 `initialChildSize` / `minChildSize` / `snapSizes`
  /// 以及**背景图的下沿**（图只铺到抽屉顶边为止）。
  static const _sheetCollapsed = 0.24;

  /// 抽屉顶部两个圆角的半径（与下面 sheet 的 BorderRadius 保持一致）。
  ///
  /// 背景图的下沿要**再往下伸这么多**：圆角的弧线外侧仍然属于可见的背景区，
  /// 图停到抽屉顶边的话，那两个角露出来的就是 Scaffold 的底色（看着像白边）。
  static const _sheetCorner = 32.0;

  List<PackageRef> _packages = [];
  PackageRef? _package;
  List<_SaveChoice> _saves = [];
  _SaveChoice? _save = const _SaveChoice.newGame();
  PlaySessionData? _session;
  final _sheetCtrl = DraggableScrollableController();

  /// 检测到更新时，主页「帮助与关于」入口右侧亮小黄点。
  bool _hasUpdate = false;

  /// build 里要用的两处「顺手读盘」结果，统一在 [_reload] 里取好。
  /// 不然每次 setState 重建都会在 build 内读一遍整个内容包目录（`packageDisplayName`
  /// 会 loadPlaySession）再同步解析一次设置文件，低端机上每次重建都卡几十毫秒。
  String _packageTitle = '无内容包';
  String? _providerName; // null = 没配供应商，胶囊变红底提示

  @override
  void initState() {
    super.initState();
    _reload();
    _checkUpdateQuietly();
  }

  Future<void> _checkUpdateQuietly() async {
    final info = await const UpdateService().check();
    if (!mounted) return;
    if (info.hasUpdate != _hasUpdate) {
      setState(() => _hasUpdate = info.hasUpdate);
    }
  }

  @override
  void dispose() {
    _sheetCtrl.dispose();
    super.dispose();
  }

  void _reload() {
    if (!mounted) return;
    final prefs = widget.services.api.load();
    final pkgs = widget.services.listPackagesForHome();
    PackageRef? pkg;
    // 多版本并存：优先按 packageId+version 精确匹配；匹配不到再按 packageId
    // 退回第一个（通常是最新的）。只存 packageId 时会随便挑一个同名包。
    if (prefs.lastPackageId != null) {
      for (final p in pkgs) {
        if (p.packageId != prefs.lastPackageId) continue;
        if (prefs.lastPackageVersion != null &&
            p.version == prefs.lastPackageVersion) {
          pkg = p;
          break;
        }
        pkg ??= p;
      }
    }
    pkg ??= pkgs.isNotEmpty ? pkgs.first : null;
    final selectedPkg = pkg;

    final slots = selectedPkg == null
        ? <SaveSlot>[]
        : widget.services.saves
              .listSaves()
              .where((s) => s.packageRef.packageId == selectedPkg.packageId)
              .toList();
    final List<_SaveChoice> saves = [
      const _SaveChoice.newGame(),
      ...slots.map(
        (s) => _SaveChoice.slot(s.saveId, s.label, updatedAt: s.updatedAt),
      ),
    ];
    _SaveChoice? save;
    if (prefs.lastSaveId != null) {
      for (final s in saves) {
        if (s.id != null && s.id == prefs.lastSaveId) save = s;
      }
    }
    save ??= saves.first;

    setState(() {
      _packages = pkgs;
      _package = pkg;
      _saves = saves;
      _save = save;
      final session = selectedPkg == null
          ? null
          : widget.services.loadPlaySession(selectedPkg);
      _session = session;
      // 与 packageDisplayName 同口径：包名先取 manifest.name，读不出来才退回注册名。
      _packageTitle =
          session?.packageTitle ??
          selectedPkg?.displayName ??
          selectedPkg?.packageId ??
          '无内容包';
      _providerName = prefs.activeProvider?.name;
    });
  }

  Future<void> _selectPackage(PackageRef p) async {
    appLog.i('home', '切换内容包：${p.packageId} v${p.version}');
    // 换包必须把「上次的存档」也清掉：留着旧 id 会让下次进入时去匹配
    // 新包下拉不到的存档（copyWith 的 `?? this.x` 光传 null 是清不掉的）。
    await widget.services.api.update(
      (prefs) => prefs.copyWith(
        lastPackageId: p.packageId,
        lastPackageVersion: p.version,
        clearLastSave: true,
      ),
    );
    _reload();
  }

  Future<void> _selectSave(_SaveChoice? s) async {
    if (s == null) return;
    await widget.services.api.update(
      (prefs) => prefs.copyWith(
        lastSaveId: s.id,
        // 选了「新的开始」就要真的不再记住旧档，否则离开游戏再回来会跳回旧档。
        clearLastSave: s.isNew,
      ),
    );
    if (!mounted) return;
    setState(() => _save = s);
  }

  String _defaultSaveName() {
    final now = DateTime.now();
    final y = now.year.toString().padLeft(4, '0');
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    final hh = now.hour.toString().padLeft(2, '0');
    final mm = now.minute.toString().padLeft(2, '0');
    return '存档 $y$m$d-$hh$mm';
  }

  Future<void> _start() async {
    if (_package == null) return;
    String? saveId;
    String? saveLabel;
    if (_save != null && _save!.isNew) {
      final name = await _promptNewSaveName();
      if (name == null || name.isEmpty) return;
      saveLabel = name;
    } else {
      saveId = _save?.id;
      saveLabel = _save?.label;
    }
    if (!mounted) return;
    appLog.i(
      'home',
      '进入游戏：包 ${_package!.packageId} v${_package!.version}，'
          '存档 ${saveLabel ?? '(新档)'}',
    );
    // 游戏页会把**这次真正在用的存档 id** 交回来（新档是进去之后才建的）。
    // 从「新的开始」进来时主页记住的是「新的开始」，不接这个返回值的话
    // 退出后还停在「新的开始」，玩家得自己再挑一次刚建的那个档。
    final played = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => ChatPage(
          theme: widget.theme,
          services: widget.services,
          packageRef: _package,
          saveId: saveId,
          initialSaveLabel: saveLabel,
        ),
      ),
    );
    if (!mounted) return;
    try {
      if (played != null && played.isNotEmpty) {
        await widget.services.api.update(
          (prefs) => prefs.copyWith(lastSaveId: played),
        );
      }
    } finally {
      // 设置写盘失败（磁盘满 / 只读）也要刷新列表：否则刚建出来的档
      // 因为一句异常就永远不出现在主页，玩家以为进度没了。
      if (mounted) _reload();
    }
  }

  Future<String?> _promptNewSaveName() => showDialog<String>(
        context: context,
        builder: (_) => _NewSaveNameDialog(
          theme: widget.theme,
          initial: _defaultSaveName(),
        ),
      );

  Future<void> _push(Widget page) async {
    await Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => page));
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    final h = MediaQuery.sizeOf(context).height;
    final w = MediaQuery.sizeOf(context).width;
    final bgPath = _session?.homeAsset();
    // 游戏内显示的包名就是 manifest.name（没装包时给一句占位）。
    final title = _session?.packageTitle ?? '未选择内容包';
    final intro = _session != null && _session!.packageIntro.trim().isNotEmpty
        ? _session!.packageIntro
        : '选择内容包后开始你的故事。';

    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: Colors.white,
        systemNavigationBarIconBrightness: Brightness.dark,
      ),
    );

    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(
        children: [
          // 背景图只铺到**抽屉收起时的顶边**为止：抽屉顶部那两个圆角是「切掉」的，
          // 图一旦伸到它们下面，就会从圆弧外侧露出边角。
          // 区域内用 cover —— 上下钉满、左右按比例裁切，不改图本身的画面比例。
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            bottom: h * _sheetCollapsed - _sheetCorner,
            child: bgPath != null
                ? Image.file(
                    File(bgPath),
                    key: const ValueKey('home-bg'),
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    errorBuilder: (_, __, ___) => ColoredBox(color: t.accent),
                  )
                : ColoredBox(
                    key: const ValueKey('home-bg'),
                    color: t.accent,
                  ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            bottom: h * _sheetCollapsed - _sheetCorner,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.center,
                  colors: [
                    Colors.black.withValues(alpha: 0.28),
                    Colors.black.withValues(alpha: 0.05),
                  ],
                ),
              ),
            ),
          ),
          // Title block sits at ~1/3 of full screen height (not SafeArea-relative).
          Positioned(
            left: 22,
            right: 22,
            top: h * 0.13,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 52,
                    height: 1.05,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                    shadows: [
                      Shadow(
                        blurRadius: 14,
                        color: Colors.black45,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                ConstrainedBox(
                  // 简介只占画面左半边。
                  constraints: BoxConstraints(maxWidth: w * 0.5),
                  child: Text(
                    intro,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.6,
                      color: Colors.white.withValues(alpha: 0.94),
                      shadows: const [
                        Shadow(blurRadius: 8, color: Colors.black54),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: DraggableScrollableSheet(
              controller: _sheetCtrl,
              initialChildSize: _sheetCollapsed,
              minChildSize: _sheetCollapsed,
              // 展开最高仍为 95% 页高；内容在抽屉内的 ListView 里上下滚
              maxChildSize: 0.95,
              snap: true,
              snapSizes: const [_sheetCollapsed, 0.95],
              builder: (context, sheetScroll) {
                return Container(
                  decoration: BoxDecoration(
                    color: t.card,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(32),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.1),
                        blurRadius: 16,
                        offset: const Offset(0, -4),
                      ),
                    ],
                  ),
                  child: ListView(
                    controller: sheetScroll,
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 28),
                    children: [
                      Center(
                        child: Container(
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: t.sub.withValues(alpha: 0.35),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      HomeSelector(
                        theme: t,
                        packageName: _packageTitle,
                        saveLabel: _save?.label ?? '新的开始',
                        onPackageTap: _openPackages,
                        onSaveTap: _openSaves,
                        onStart: _package == null ? null : _start,
                      ),
                      const SizedBox(height: 12),
                      Center(child: _modelStatusLine(t)),
                      const SizedBox(height: 16),
                      _menuTile(
                        t,
                        Icons.settings,
                        '设置',
                        () => _push(
                          SettingsPage(
                            theme: widget.theme,
                            services: widget.services,
                            onSettingsChanged: widget.onSettingsChanged,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      _menuTile(
                        t,
                        Icons.folder_copy,
                        '内容包与存档',
                        () => _push(
                          LibraryPage(
                            theme: widget.theme,
                            services: widget.services,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      _creatorHub(t),
                      const SizedBox(height: 10),
                      _menuTile(
                        t,
                        Icons.help_outline,
                        '帮助与关于',
                        showBadge: _hasUpdate,
                        () async {
                          await _push(
                            HelpAboutPage(
                              theme: widget.theme,
                              services: widget.services,
                            ),
                          );
                          if (mounted) await _checkUpdateQuietly();
                        },
                      ),
                      const SizedBox(height: 16),
                      _HomeCarousel(theme: t, cacheRoot: widget.services.root),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 主页那颗「模型供应商」小胶囊：**点一下直接进模型设置页**。
  /// 未配置时是红底提示，同样可以点进去配。
  Widget _modelStatusLine(ChatGalTheme t) {
    // 供应商名来自 [_reload] 的缓存：不要在 build 里同步读设置文件。
    final activeName = _providerName;

    final Widget pill;
    if (activeName == null) {
      pill = Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.redAccent.shade400,
          borderRadius: BorderRadius.circular(999),
        ),
        child: const Text(
          '未配置模型供应商，当前为 Mock 对话',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
      );
    } else {
      pill = Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: t.sub.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          '供应商：$activeName',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: t.sub,
          ),
        ),
      );
    }

    return Semantics(
      button: true,
      label: '打开模型供应商设置',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: () async {
            await _push(
              ModelProvidersPage(
                theme: widget.theme,
                api: widget.services.api,
                onChanged: widget.onSettingsChanged,
              ),
            );
            if (mounted) setState(() {});
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                pill,
                const SizedBox(width: 4),
                Icon(Icons.chevron_right, size: 14, color: t.sub),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 创作卡右侧装饰：两列错位圆角矩形。
  ///
  /// 高度完全由左侧两个入口决定：这里只用 Stack + Positioned 画超出上下边的
  /// 卡片，**不参与 IntrinsicHeight**，否则装饰会把整张卡撑高。
  /// 左侧内边距小于右侧，图形整体偏左，右边留白更宽。
  Widget _hubWaterfallArt(ChatGalTheme t) {
    Widget card(double alpha) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: t.accent.withValues(alpha: alpha),
          borderRadius: BorderRadius.circular(12),
        ),
      );
    }

    // 版面：左列 left=6 宽 40，右列 left=52 宽 40 → 右侧留白 16 > 左侧 6
    return SizedBox(
      width: 108,
      child: ClipRect(
        child: Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            // 左列：略靠上，上下各出一点由卡片边缘裁断
            Positioned(left: 6, top: -26, width: 40, height: 92, child: card(0.20)),
            Positioned(left: 6, top: 80, width: 40, height: 68, child: card(0.12)),
            Positioned(left: 6, top: 164, width: 40, height: 84, child: card(0.16)),
            // 右列：错位下移
            Positioned(left: 52, top: 10, width: 40, height: 66, child: card(0.14)),
            Positioned(left: 52, top: 90, width: 40, height: 80, child: card(0.22)),
            Positioned(left: 52, top: 186, width: 40, height: 70, child: card(0.11)),
          ],
        ),
      ),
    );
  }

  Widget _menuTile(
    ChatGalTheme t,
    IconData icon,
    String label,
    VoidCallback onTap, {
    bool showBadge = false,
  }) {
    return Container(
      // 和「创作」区那张大卡同一个口径：有一道细描边，才看得出这是一块能点的
      // 容器，而不是和页面底色糊在一起。
      decoration: BoxDecoration(
        color: t.bg,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: t.sub.withValues(alpha: 0.12)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
            child: Row(
              children: [
                // 图标衬底：与设置页 / 创作区入口同一套圆角矩形底。
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: t.accent.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, size: 18, color: t.accent),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    style:
                        TextStyle(fontWeight: FontWeight.w600, color: t.ink),
                  ),
                ),
                if (showBadge)
                  Container(
                    width: 8,
                    height: 8,
                    margin: const EdgeInsets.only(right: 8),
                    decoration: const BoxDecoration(
                      color: Color(0xFFFFC107),
                      shape: BoxShape.circle,
                    ),
                  ),
                Icon(Icons.chevron_right, size: 18, color: t.sub),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 「创作」区：内容包创作台 + 创意工坊**共享一张大卡**。
  ///
  /// 两个入口竖排在卡片左侧，右侧那条竖带是自绘的装饰图形（不是按钮，
  /// 也不接受点击）—— 一块整卡比两张并排的小条更像「一个地方的两个门」。
  Widget _creatorHub(ChatGalTheme t) {
    return Container(
      decoration: BoxDecoration(
        color: t.bg,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: t.sub.withValues(alpha: 0.12)),
      ),
      clipBehavior: Clip.antiAlias,
      // Row 在 ListView 里高度是无界的：先套一层 IntrinsicHeight 拿到确定高度，
      // 否则 CrossAxisAlignment.stretch 会算出「无限高」（布局断言直接炸）。
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _hubEntry(
                    t,
                    icon: Icons.edit_note,
                    title: '内容包创作台',
                    subtitle: '自己写剧情、角色与事件',
                    onTap: () => _push(
                      StudioPage(
                        theme: widget.theme,
                        services: widget.services,
                      ),
                    ),
                  ),
                  Divider(
                    height: 1,
                    thickness: 1,
                    indent: 14,
                    endIndent: 14,
                    color: t.sub.withValues(alpha: 0.10),
                  ),
                  _hubEntry(
                    t,
                    icon: Icons.palette_outlined,
                    title: '创意工坊',
                    subtitle: '体验他人的创意',
                    onTap: () => openWorkshop(context, widget.theme),
                  ),
                ],
              ),
            ),
            // 右侧：两列错位纯色圆角矩形；高度不撑高容器，上下边缘裁断
            SizedBox(width: 108, child: _hubWaterfallArt(t)),
          ],
        ),
      ),
    );
  }

  Widget _hubEntry(
    ChatGalTheme t, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: t.accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, size: 18, color: t.accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: t.ink,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: t.sub),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, size: 18, color: t.sub),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openPackages() async {
    final picked = await showModalBottomSheet<PackageRef>(
      context: context,
      backgroundColor: widget.theme.card,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: _packages.map((p) {
            final selected = p.packageId == _package?.packageId;
            return ListTile(
              title: Text(
                widget.services.packageDisplayName(p),
                style: TextStyle(color: widget.theme.ink),
              ),
              subtitle: Text(
                p.version,
                style: TextStyle(fontSize: 12, color: widget.theme.sub),
              ),
              trailing: selected
                  ? Icon(Icons.check, color: widget.theme.accent)
                  : null,
              onTap: () => Navigator.pop(ctx, p),
            );
          }).toList(),
        ),
      ),
    );
    if (picked != null) await _selectPackage(picked);
  }

  Future<void> _openSaves() async {
    final picked = await showModalBottomSheet<_SaveChoice>(
      context: context,
      backgroundColor: widget.theme.card,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: _saves.map((s) {
            final selected = s.id == _save?.id && s.isNew == _save?.isNew;
            return ListTile(
              title: Text(s.label, style: TextStyle(color: widget.theme.ink)),
              trailing: selected
                  ? Icon(Icons.check, color: widget.theme.accent)
                  : null,
              onTap: () => Navigator.pop(ctx, s),
            );
          }).toList(),
        ),
      ),
    );
    if (picked != null) await _selectSave(picked);
  }
}

class _SaveChoice {
  const _SaveChoice.slot(this.id, this.label, {this.updatedAt});
  const _SaveChoice.newGame() : id = null, label = '新的开始', updatedAt = null;

  final String? id;
  final String label;
  final DateTime? updatedAt;

  bool get isNew => id == null;
}

/// 主页抽屉底部轮播：读官网 `carousel/`，**落盘缓存**后再展示。
///
/// * `list.json` 与图片缓存在 `chatgal_data/carousel_cache/`
/// * 启动先读缓存（离线也有图），再后台拉网刷新
/// * 点击用 `url` 字段（任意完整网址）；兼容纯文件名旧约定
class _HomeCarousel extends StatefulWidget {
  const _HomeCarousel({required this.theme, required this.cacheRoot});

  final ChatGalTheme theme;

  /// App 数据根目录（`chatgal_data`）。
  final Directory cacheRoot;

  @override
  State<_HomeCarousel> createState() => _HomeCarouselState();
}

class _HomeCarouselState extends State<_HomeCarousel> {
  final _controller = PageController(viewportFraction: 1);
  Timer? _timer;

  List<CarouselSlide> _slides = const [];
  bool _loadedCache = false;

  static const _fallback = <({Color color, String label})>[
    (color: Color(0xFFB8A0E0), label: '敬请期待'),
    (color: Color(0xFF8FBF9F), label: '敬请期待'),
    (color: Color(0xFFE0B090), label: '敬请期待'),
  ];

  Directory get _cacheDir => Directory(
    '${widget.cacheRoot.path}${Platform.pathSeparator}carousel_cache',
  );

  /// 列表缓存的固定文件名。图片缓存一律带哈希前缀，不会撞上它。
  static const _listCacheName = 'list.json';

  /// 单张轮播图的下载上限：官网换图不该把手机内存拖垮。
  static const _maxImageBytes = 12 * 1024 * 1024;

  File get _listCache => File(
    '${_cacheDir.path}${Platform.pathSeparator}$_listCacheName',
  );

  /// 缓存文件名 = `短哈希-原名`。只取最后一段文件名会让「同名不同路径」的两张图
  /// 互相顶替；而且万一某张图恰好叫 list.json，还会把列表缓存自己覆盖掉。
  String _cacheFileName(String imageRef) {
    var name = imageRef;
    final uri = Uri.tryParse(imageRef);
    if (uri != null && uri.pathSegments.isNotEmpty) {
      name = uri.pathSegments.last;
    }
    name = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    if (name.isEmpty) name = 'slide.bin';
    return '${_urlHash(imageRef)}-$name';
  }

  /// 稳定的短哈希（FNV-1a 32 位）。缓存文件名要跨启动、跨版本都一致，
  /// 不能用 String.hashCode —— 它的实现没有跨版本稳定性承诺。
  static String _urlHash(String s) {
    var hash = 0x811c9dc5;
    for (final b in utf8.encode(s)) {
      hash = ((hash ^ b) * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  File _imageCacheFile(String imageRef) => File(
    '${_cacheDir.path}${Platform.pathSeparator}${_cacheFileName(imageRef)}',
  );

  /// 若本地已有该图的缓存文件，则返回本地路径（Image.file 用），否则仍用网络地址。
  String _displayImage(CarouselSlide s) {
    // 已是本地路径 / data / 非 http 的直接用
    if (!s.image.contains('://')) return s.image;
    final f = _imageCacheFile(s.image);
    if (f.existsSync() && f.lengthSync() > 0) return f.path;
    return s.image;
  }

  /// 清掉不再被当前列表引用的缓存文件（换图之后旧文件否则会一直留着）。
  Future<void> _pruneCache(List<CarouselSlide> keep) async {
    try {
      final alive = <String>{
        _listCacheName,
        for (final s in keep)
          if (s.image.contains('://')) _cacheFileName(s.image),
      };
      await for (final e in _cacheDir.list()) {
        if (e is! File) continue;
        final name = e.path.split(Platform.pathSeparator).last;
        if (alive.contains(name)) continue;
        try {
          await e.delete();
        } catch (_) {
          // 单个文件删不掉（被占用等）不值得打断
        }
      }
    } catch (_) {
      // 清理失败不影响展示
    }
  }

  List<CarouselSlide> _parseRows(Object? decoded) {
    final List<Object?> rows;
    if (decoded is List) {
      rows = decoded;
    } else if (decoded is Map && decoded['slides'] is List) {
      rows = decoded['slides'] as List;
    } else if (decoded is Map && decoded['files'] is List) {
      rows = decoded['files'] as List;
    } else {
      return const [];
    }
    return [
      for (final r in rows)
        if (CarouselSlide.parse(r) case final s?) s,
    ];
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadFromCacheThenNetwork());
    _timer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!mounted || !_controller.hasClients) return;
      final count = _slides.isEmpty ? _fallback.length : _slides.length;
      if (count < 2) return;
      final page = (_controller.page ?? 0).round();
      final next = (page + 1) % count;
      _controller.animateToPage(
        next,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
      );
    });
  }

  Future<void> _loadFromCacheThenNetwork() async {
    // 1) 先吃缓存：进主页立刻有图，不依赖网络
    try {
      await _cacheDir.create(recursive: true);
      if (_listCache.existsSync()) {
        final cached = _parseRows(
          jsonDecode(await _listCache.readAsString(encoding: utf8)),
        );
        if (mounted && cached.isNotEmpty) {
          setState(() {
            _slides = cached;
            _loadedCache = true;
          });
        }
      }
    } catch (_) {
      // 缓存坏了就当没有
    }

    // 2) 后台拉网并写缓存
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 6);
      try {
        final req = await client.getUrl(
          Uri.parse('$kCarouselDirUrl/list.json'),
        );
        req.headers.set(HttpHeaders.userAgentHeader, 'ChatGal/${kAppVersion}');
        final resp = await req.close();
        if (resp.statusCode != 200) {
          if (!_loadedCache && mounted) setState(() {});
          return;
        }
        final body = await resp.transform(utf8.decoder).join();
        final parsed = _parseRows(jsonDecode(body));
        if (parsed.isEmpty) return;

        // 下载每一张图到缓存目录（已有且非空则跳过）
        for (final s in parsed) {
          if (!s.image.contains('://')) continue;
          final dest = _imageCacheFile(s.image);
          if (dest.existsSync() && dest.lengthSync() > 0) continue;
          try {
            final imgReq = await client.getUrl(Uri.parse(s.image));
            imgReq.headers.set(
              HttpHeaders.userAgentHeader,
              'ChatGal/${kAppVersion}',
            );
            final imgResp = await imgReq.close();
            if (imgResp.statusCode != 200) continue;
            // 边收边判上限：单张巨图不该把内存吃掉，卡住的连接也别一直挂着。
            final bytes = <int>[];
            var oversize = false;
            await for (final chunk in imgResp.timeout(
              const Duration(seconds: 20),
            )) {
              bytes.addAll(chunk);
              if (bytes.length > _maxImageBytes) {
                oversize = true;
                break;
              }
            }
            if (oversize || bytes.isEmpty) continue;
            await dest.writeAsBytes(bytes, flush: true);
          } catch (_) {
            // 单张图失败不影响整包
          }
        }

        try {
          await _listCache.writeAsString(
            jsonEncode([
              for (final s in parsed)
                {
                  'image': s.image,
                  'url': s.clickUrl,
                },
            ]),
            encoding: utf8,
          );
        } catch (_) {}

        // 列表已经写好了，顺手清掉不再被引用的旧缓存：官网换过图之后
        // 旧文件不会永远留在手机里。只在真的拿到列表时才调——
        // 离线启动绝不能把缓存清空。
        await _pruneCache(parsed);

        if (!mounted) return;
        setState(() => _slides = parsed);
      } finally {
        client.close(force: true);
      }
    } catch (_) {
      // 无网：继续用缓存或占位
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _openSlide(CarouselSlide slide) async {
    final url = slide.clickUrl;
    // 轮播的 url 来自远端 list.json，是这里**唯一**不受我们控制的字符串。
    // 只放行 http/https：别让一条被改过的列表把 intent:// / tel: / market://
    // 这类东西直接送进原生 startActivity。
    // （反馈入口的 mailto: / mqqwpa:// 是编译期常量，不走这条路，所以原生通道保持通用。）
    final scheme = Uri.tryParse(url)?.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      _offerCopyToBrowser(url);
      return;
    }
    final ok = await NativeBridge.instance.launch(url);
    if (!ok) _offerCopyToBrowser(url);
  }

  void _offerCopyToBrowser(String url) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('当前打不开该页面，可复制地址到浏览器'),
        action: SnackBarAction(
          label: '复制',
          onPressed: () => Clipboard.setData(ClipboardData(text: url)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    final net = _slides.isNotEmpty;
    final count = net ? _slides.length : _fallback.length;
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: PageView.builder(
          controller: _controller,
          itemCount: count,
          itemBuilder: (context, i) {
            if (!net) {
              final slide = _fallback[i];
              return Container(
                color: slide.color.withValues(alpha: 0.85),
                alignment: Alignment.center,
                child: Text(
                  slide.label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.white.withValues(alpha: 0.92),
                  ),
                ),
              );
            }
            final slide = _slides[i];
            final display = _displayImage(slide);
            final isFile =
                !display.contains('://') && File(display).existsSync();
            return InkWell(
              onTap: () => _openSlide(slide),
              child: isFile
                  ? Image.file(
                      File(display),
                      key: ValueKey(display),
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => _errBox(t, slide),
                    )
                  : Image.network(
                      display,
                      fit: BoxFit.cover,
                      // 解码后缓存位图，减少重复下载/解码
                      cacheWidth: 1080,
                      errorBuilder: (_, _, _) => _errBox(t, slide),
                    ),
            );
          },
        ),
      ),
    );
  }

  Widget _errBox(ChatGalTheme t, CarouselSlide slide) {
    return Container(
      color: t.bg,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(8),
      child: Text(
        slide.clickUrl,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 11, color: t.sub),
      ),
    );
  }
}

/// 命名新存档的弹窗。
///
/// controller **由弹窗自己持有并释放**：写成「showDialog 返回后 dispose」会在
/// 退场动画还没跑完时就释放，那一帧 TextField 仍在树上、还要用它
/// （debug 下直接断言失败：`A TextEditingController was used after being disposed`）。
class _NewSaveNameDialog extends StatefulWidget {
  const _NewSaveNameDialog({required this.theme, required this.initial});

  final ChatGalTheme theme;
  final String initial;

  @override
  State<_NewSaveNameDialog> createState() => _NewSaveNameDialogState();
}

class _NewSaveNameDialogState extends State<_NewSaveNameDialog> {
  late final TextEditingController _name =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('命名新存档'),
      content: TextField(
        controller: _name,
        autofocus: true,
        decoration: const InputDecoration(labelText: '存档名称'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: widget.theme.accent,
            foregroundColor: Colors.white,
          ),
          onPressed: () => Navigator.pop(context, _name.text.trim()),
          child: const Text('开始'),
        ),
      ],
    );
  }
}
