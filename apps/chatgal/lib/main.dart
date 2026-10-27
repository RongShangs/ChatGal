import 'package:flutter/material.dart';

import 'app/app_logger.dart';
import 'app/app_services.dart';
import 'app/font_registry.dart';
import 'design_system/tokens.dart';
import 'features/home/home_page.dart';
import 'features/settings/api_settings.dart';
import 'features/splash/splash_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ChatGalApp());
}

/// 构建标记：只做「这次跑的是哪一版行为」的判据，每次改提示词/关键行为就 +1。
/// 排查时对着日志看这一行，能立刻分辨是代码没生效还是行为没效果。
const String kBuildMarker = 'prompt-contract-v4';

class ChatGalApp extends StatefulWidget {
  const ChatGalApp({super.key});

  @override
  State<ChatGalApp> createState() => _ChatGalAppState();
}

class _ChatGalAppState extends State<ChatGalApp> {
  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();
  AppServices? _services;
  Object? _bootError;
  int _themeIndex = 0;
  bool _entered = false;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      final services = await AppServices.open();
      // 先读设置再 attach：日志上限就存在设置里，attach 会按它把盘上最近
      // N 条读回内存（日志页因此能跨启动看到上一轮的记录）。
      final settings = services.api.load();
      AppLogger.instance.attach(
        services.root.path,
        maxEntries: settings.logMaxEntries,
      );
      appLog.i('app',
          '启动完成，数据目录 ${services.root.path}（日志上限 ${settings.logMaxEntries} 条，'
          '已恢复 ${AppLogger.instance.entries.length} 条）');
      // 构建标记：日志里能一眼看出「这次跑的是哪套提示词/行为」，
      // 免得再出现「改了代码但手机上还是旧包」的判断困难。
      appLog.i('app', '构建标记=$kBuildMarker');
      await FontRegistry.ensure(settings);
      if (!mounted) return;
      setState(() {
        _services = services;
        _bootError = null;
        _applyTheme(settings);
      });
      // 设置文件读坏了（解析失败）也要说一声：不然用户只会觉得设置被重置了。
      final settingsError = services.api.loadError;
      if (settingsError != null) {
        appLog.w('settings', settingsError);
        _showBanner('$settingsError（已保留备份 app_settings.json.corrupt）');
      }
    } catch (e, st) {
      appLog.e('app', '启动失败', e, st);
      if (!mounted) return;
      setState(() => _bootError = e);
    }
  }

  /// 进入主页之后再提示：启动阶段还没有可用的 ScaffoldMessenger。
  void _showBanner(String message) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _messengerKey.currentState
          ?.showSnackBar(SnackBar(content: Text(message)));
    });
  }

  void _applyTheme(AppSettings settings) {
    final idx = ChatGalTheme.all.indexWhere((t) => t.id == settings.themeId);
    if (idx >= 0) _themeIndex = idx;
  }

  /// 设置页改过主题/字体后回来同步一次。
  void _onSettingsChanged() {
    final services = _services;
    if (services == null) return;
    final settings = services.api.load();
    FontRegistry.ensure(settings);
    setState(() => _applyTheme(settings));
  }

  @override
  Widget build(BuildContext context) {
    final theme = ChatGalTheme.all[_themeIndex];
    final services = _services;

    MaterialApp shell(Widget home) => MaterialApp(
          // Unicode escapes: avoid Windows/GBK writing mojibake into task title.
          title: 'ChatGal',
          scaffoldMessengerKey: _messengerKey,
          debugShowCheckedModeBanner: false,
          theme: theme.toThemeData(),
          home: home,
        );

    if (_bootError != null) {
      return shell(
        _BootErrorPage(
          theme: theme,
          error: _bootError!,
          onRetry: () {
            setState(() => _bootError = null);
            _boot();
          },
        ),
      );
    }

    // 开屏 → 主页走 **SplashFade 的交叉淡入淡出**：以前是直接替换 `home`，
    // 观感是开屏「啪」一下没了（用户反馈「有点突兀」）。
    // 注意：`second` 只能在 services 就绪时构造（`showFirst` 为真时它不会被 build）。
    return shell(
      SplashFade(
        showFirst: !_entered,
        first: SplashPage(
          // 开屏页同时承担「等默认包安装完成」：动画在跑，安装在后台继续。
          services: services,
          onEntered: (ready) {
            if (!mounted) return;
            setState(() => _entered = true);
            // 内容包更新失败但有旧包可用 → 进主页后如实提示一句。
            final warning = ready.bootWarning;
            if (warning != null) _showBanner(warning);
          },
        ),
        second: services == null
            ? const SizedBox.shrink()
            : HomePage(
                theme: theme,
                services: services,
                onSettingsChanged: _onSettingsChanged,
              ),
      ),
    );
  }
}

/// 启动阶段就失败（默认包装不上、目录不可写）时的兜底页：
/// 至少让用户看到错误与重试，而不是永远停在开屏动画上。
class _BootErrorPage extends StatelessWidget {
  const _BootErrorPage({
    required this.theme,
    required this.error,
    required this.onRetry,
  });

  final ChatGalTheme theme;
  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: theme.bg,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 40, color: theme.sub),
              const SizedBox(height: 14),
              Text(
                '启动失败',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: theme.ink,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '$error',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, height: 1.5, color: theme.sub),
              ),
              const SizedBox(height: 20),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: theme.accent,
                  foregroundColor: Colors.white,
                ),
                onPressed: onRetry,
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
