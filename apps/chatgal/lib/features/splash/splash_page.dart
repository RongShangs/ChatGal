import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_logger.dart';
import '../../app/app_services.dart';
import '../settings/privacy_page.dart';

/// 开屏页（照旧项目 `pages/main/main.lua` 的做法复刻）。
///
/// 旧项目那一屏做了两件事，这里一件不落地搬过来：
/// 1. 居中一张 120dp 圆角卡片，里面是应用图标；
///    用 ObjectAnimator 做 **2000ms 淡入 + 减速插值**；
/// 2. 动画结束后弹「用户须知」滚动弹窗，只有「我已阅读并同意」才进游戏，
///    「不同意并退出」直接关掉应用；同意过就不再拦。
///
/// 差别只在落地方式：旧项目把同意状态放 `setSharedData("agreed_notice")`，
/// 这里放进 `AppSettings.noticeAgreed`（和应用设置同生共死，清数据一并清掉）。
class SplashPage extends StatefulWidget {
  const SplashPage({
    super.key,
    required this.services,
    required this.onEntered,
  });

  /// 应用服务：为 null 表示默认包还在后台安装，这一屏继续等。
  final AppServices? services;

  /// 动画跑完 + 服务就绪 + 须知已同意之后调用。
  final void Function(AppServices services) onEntered;

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage>
    with SingleTickerProviderStateMixin {
  /// 旧项目是 `setDuration(2000)` + `DecelerateInterpolator()`，但 2 秒太长
  /// （用户反馈「等得久」，尤其第二次启动没有装包要等，纯粹在等动画）。
  /// 保留同一条减速曲线与淡入+微推近的观感，时长压到 0.9 秒。
  static const Duration _fadeDuration = Duration(milliseconds: 900);

  /// 旧项目卡片色 `#aa96da`（= 主题「浅色·紫罗兰」的 accent）。
  static const Color _accent = Color(0xFFAA96DA);

  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: _fadeDuration,
  );

  late final Animation<double> _fade = CurvedAnimation(
    parent: _ctrl,
    curve: Curves.decelerate,
  );

  /// 缩放跟淡入同一条曲线，但幅度很小：旧项目只有淡入，
  /// 这里多一点点推近感，避免那么大一张卡片「凭空出现」。
  late final Animation<double> _scale = Tween<double>(
    begin: 0.92,
    end: 1.0,
  ).animate(_fade);

  bool _animationDone = false;
  bool _noticeShown = false;
  bool _handedOff = false;

  @override
  void initState() {
    super.initState();
    _ctrl.forward().whenComplete(() {
      if (!mounted) return;
      setState(() => _animationDone = true);
      _maybeContinue();
    });
    _maybeContinue();
  }

  @override
  void didUpdateWidget(covariant SplashPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 服务可能在动画跑完之后才就绪，两个条件谁后到都行。
    if (widget.services != null && oldWidget.services == null) _maybeContinue();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// 动画结束 + 服务就绪才算「可以往下走」。
  void _maybeContinue() {
    if (!mounted || _handedOff) return;
    final services = widget.services;
    if (!_animationDone || services == null) return;

    if (services.api.load().noticeAgreed) {
      _handedOff = true;
      appLog.i('splash', '已同意过用户须知，直接进入主页');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onEntered(services);
      });
      return;
    }
    if (_noticeShown) return;
    _noticeShown = true;
    // 不能在 didUpdateWidget / 布局阶段直接 showDialog：首启装完包、服务
    // 刚 setState 就进这条路径时，弹窗会静默失败，人就卡在开屏且再也弹不出来。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _handedOff) return;
      unawaited(_showNotice(services));
    });
  }

  Future<void> _showNotice(AppServices services) async {
    appLog.i('splash', '首次启动：弹出用户须知');
    final agreed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _NoticeDialog(),
    );
    if (!mounted) return;

    if (agreed == true) {
      try {
        await services.api.update((s) => s.copyWith(noticeAgreed: true));
        appLog.i('splash', '用户已同意用户须知');
      } catch (e) {
        // 存不下去也不能把用户卡在开屏：本次会话照常放行，
        // 下次启动再问一遍就是了。
        appLog.w('splash', '保存同意状态失败：$e');
      }
      if (!mounted) return;
      _handedOff = true;
      widget.onEntered(services);
    } else {
      appLog.i('splash', '用户不同意用户须知，退出应用');
      await SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _accent,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FadeTransition(
              opacity: _fade,
              child: ScaleTransition(
                scale: _scale,
                child: Container(
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(
                    color: _accent,
                    borderRadius: BorderRadius.circular(30),
                    boxShadow: const [
                      BoxShadow(
                        color: Colors.black26,
                        blurRadius: 24,
                        offset: Offset(0, 8),
                      ),
                    ],
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Image.asset(
                    'assets/app_icon.png',
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const Center(
                      child: Text(
                        'ChatGal',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // 动画跑完了但默认包还在装（首次启动要解 58MB 的包），
            // 给一句进度提示，免得看起来像卡住了。
            if (_animationDone && widget.services == null) ...[
              const SizedBox(height: 22),
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white.withValues(alpha: 0.85),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '正在准备默认内容包…\n（仅首次安装，可能需要十几秒）',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.4,
                  color: Colors.white.withValues(alpha: 0.9),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 开屏 → 主（或：主页 → 其它根页面）的**交叉淡入淡出**。
///
/// 原来根页面是直接替换 `MaterialApp.home`，观感是开屏「啪」一下没了
/// （用户反馈「有点突兀」）。这里把两个根页面放进 `AnimatedSwitcher`：
/// 新页面淡入的同时旧页面淡出，不会有中间空一帧的发黑。
class SplashFade extends StatelessWidget {
  const SplashFade({
    super.key,
    required this.showFirst,
    required this.first,
    required this.second,
    this.duration = const Duration(milliseconds: 420),
  });

  /// true 显示 [first]（开屏），false 显示 [second]（主页）。
  final bool showFirst;
  final Widget first;
  final Widget second;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: duration,
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      // 两个根页面都是整屏的：叠在一起交叉淡，谁也不挤谁。
      layoutBuilder: (currentChild, previousChildren) => Stack(
        fit: StackFit.expand,
        children: [...previousChildren, ?currentChild],
      ),
      child: showFirst
          ? KeyedSubtree(key: const ValueKey('splash'), child: first)
          : KeyedSubtree(key: const ValueKey('home'), child: second),
    );
  }
}

/// 首次启动「用户须知」：本作自己的说明，不是技术文档。
///
/// 玩家需要知道：这是 AI 互动剧情、内容包驱动；对话会发往你自己配置的
/// 模型服务；隐私政策可点开查看；同意后才进入游戏。
class _NoticeDialog extends StatelessWidget {
  const _NoticeDialog();

  static const Color _accent = Color(0xFFAA96DA);

  @override
  Widget build(BuildContext context) {
    // 旧项目是 `setCancelable(false)`：`barrierDismissible: false` 只挡点空白，
    // 返回键照样能 pop 掉弹窗 —— 而 pop 出去等于「不同意」，会直接退出应用。
    // 这里再挡一层返回键，让「同意 / 不同意」成为唯一的两个出口。
    return PopScope(
      canPop: false,
      child: Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(40),
          ),
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '欢迎来到 ChatGal',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF333333),
                ),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: const [
                      Text(
                        'ChatGal 是一款 AI 互动剧情游戏。\n'
                        '故事、角色与画面来自「内容包」；你的对话由你配置的模型生成。\n\n'
                        '请在开始前了解：\n'
                        '· 游戏对话、朗读等联网功能，会把你输入的内容发往你自己选择的服务地址（第三方模型 / 语音服务）。\n'
                        '· 本应用不收集账号信息，数据默认只存在你的手机上。\n'
                        '· 详细说明可点下方「隐私政策」查看。\n\n'
                        '内容包可能包含恋爱、悬疑或惊悚向剧情，请自行判断是否适合。\n'
                        '若不同意以下使用约定，请选择退出。',
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.6,
                          color: Color(0xFF555555),
                        ),
                      ),
                      SizedBox(height: 10),
                      _NoticePrivacyLink(),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _NoticeButton(
                      label: '不同意并退出',
                      background: const Color(0xFFF1F1F1),
                      foreground: const Color(0xFF888888),
                      onTap: () => Navigator.of(context).pop(false),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _NoticeButton(
                      label: '我已阅读并同意',
                      background: _accent,
                      foreground: Colors.white,
                      bold: true,
                      onTap: () => Navigator.of(context).pop(true),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 须知里的隐私政策入口：优先系统浏览器，失败再提示复制。
class _NoticePrivacyLink extends StatelessWidget {
  const _NoticePrivacyLink();

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton(
        onPressed: () async {
          final url = kPrivacyPolicyUrl;
          final ok = await NativeBridge.instance.launch(url);
          if (ok || !context.mounted) return;
          await Clipboard.setData(const ClipboardData(text: kPrivacyPolicyUrl));
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已复制隐私政策地址，可粘贴到浏览器打开')),
          );
        },
        style: TextButton.styleFrom(
          padding: EdgeInsets.zero,
          foregroundColor: _NoticeDialog._accent,
        ),
        child: const Text(
          '查看隐私政策',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

class _NoticeButton extends StatelessWidget {
  const _NoticeButton({
    required this.label,
    required this.background,
    required this.foreground,
    required this.onTap,
    this.bold = false,
  });

  final String label;
  final Color background;
  final Color foreground;
  final VoidCallback onTap;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: background,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          height: 45,
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              color: foreground,
              fontWeight: bold ? FontWeight.w700 : null,
            ),
          ),
        ),
      ),
    );
  }
}
