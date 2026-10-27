import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design_system/tokens.dart';
import 'privacy_fallback_page.dart';

/// 隐私政策网页（GitHub Pages：`RongShangs/chatgal_privacy`）。
///
/// 显示方式是**应用内原生 WebView**（`chatgal/webview` 通道 → Android
/// `PrivacyWebViewActivity`），因此不引 webview_flutter 也不用跳出应用。
/// 通道不可用（桌面调试、非 Android、WebView 被禁用）时退回一个
/// 应用内的说明页，至少把地址与复制入口给到用户，而不是无声无息。
///
/// 注意：隐私兜底页 `PrivacyFallbackPage` 也引用本常量 —— 换地址只改这里。
const String kPrivacyPolicyUrl = 'https://rongshangs.github.io/chatgal_privacy/';

/// 反馈用的联系方式。
const String kFeedbackEmail = '2806598097@qq.com';
const String kFeedbackQq = '2806598097';

/// ChatGal QQ 交流群。
const String kChatGalQqGroup = '1054545834';

/// 爱发电（支持作者）。
const String kAfdianUrl = 'https://afdian.com/a/rongshang';

/// 原生能力的薄封装：MethodChannel 在非 Android/单测环境里会抛
/// MissingPluginException，这里统一转成 bool/异常，调用方不必到处 try。
class NativeBridge {
  const NativeBridge({MethodChannel? channel, MethodChannel? webChannel})
      : _system = channel ?? const MethodChannel('chatgal/system'),
        _web = webChannel ?? const MethodChannel('chatgal/webview');

  final MethodChannel _system;
  final MethodChannel _web;

  static const NativeBridge instance = NativeBridge();

  /// 应用内 WebView 打开网页。[accent]/[dark] 用来让原生顶栏贴合当前主题。
  Future<bool> openWeb({
    required String url,
    required String title,
    int accent = 0xFFAA96DA,
    bool dark = false,
  }) async {
    try {
      await _web.invokeMethod<void>('open', {
        'url': url,
        'title': title,
        'accent': accent,
        'dark': dark,
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 交给系统处理：mailto:、mqqwpa:// 之类。
  Future<bool> launch(String url) async {
    try {
      await _system.invokeMethod<void>('launch', {'url': url});
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// 打开隐私政策：优先应用内原生网页，失败则退回应用内说明页。
Future<void> openPrivacyPolicy(BuildContext context, ChatGalTheme theme) async {
  final ok = await NativeBridge.instance.openWeb(
    url: kPrivacyPolicyUrl,
    title: '隐私政策',
    accent: theme.accent.toARGB32(),
    dark: theme.brightness == Brightness.dark,
  );
  if (ok) return;
  if (!context.mounted) return;
  await Navigator.of(context).push<void>(
    MaterialPageRoute(builder: (_) => PrivacyFallbackPage(theme: theme)),
  );
}

/// 创意工坊网页（系统浏览器打开）。
const String kWorkshopUrl = 'https://chatgal.rongshangs.top';

/// 官网轮播图目录（list.json + 图片文件）。
const String kCarouselDirUrl = 'https://chatgal.rongshangs.top/carousel';

/// 打开创意工坊：一律交系统浏览器，不用应用内 WebView。
Future<void> openWorkshop(BuildContext context, ChatGalTheme theme) async {
  final launched = await NativeBridge.instance.launch(kWorkshopUrl);
  if (launched) return;
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: const Text('当前打不开网页，可以复制地址到浏览器打开'),
      action: SnackBarAction(
        label: '复制地址',
        onPressed: () =>
            Clipboard.setData(const ClipboardData(text: kWorkshopUrl)),
      ),
    ),
  );
}

/// 轮播一条：图 + 点击目标（完整网址，不限于官网子目录）。
class CarouselSlide {
  const CarouselSlide({required this.image, required this.clickUrl});

  /// 展示用图：完整 URL，或 carousel 目录下的文件名。
  final String image;

  /// 点击后系统浏览器打开的完整网址。
  final String clickUrl;

  /// 解析 list.json 元素。
  ///
  /// * 字符串：若含 `://` 则图与点击都用它；否则图 = carousel/<文件名>，
  ///   点击 = 官网根路径 +「去扩展名的文件名」（兼容旧约定）。
  /// * 对象：`image`/`file` 为图；`url`/`href`/`click` 为完整点击网址。
  ///   `image` 若含 `://` 则直接当网络图。
  static CarouselSlide? parse(Object? raw) {
    if (raw is String && raw.trim().isNotEmpty) {
      final s = raw.trim();
      if (s.contains('://')) {
        return CarouselSlide(image: s, clickUrl: s);
      }
      return CarouselSlide(
        image: kCarouselDirUrl + '/' + s,
        clickUrl: carouselFallbackClickUrl(s),
      );
    }
    if (raw is Map) {
      final img = '${raw['image'] ?? raw['file'] ?? ''}'.trim();
      final url =
          '${raw['url'] ?? raw['href'] ?? raw['click'] ?? ''}'.trim();
      if (img.isEmpty) return null;
      final image = img.contains('://') ? img : '$kCarouselDirUrl/$img';
      final click = url.isNotEmpty
          ? url
          : (img.contains('://') ? img : carouselFallbackClickUrl(img));
      return CarouselSlide(image: image, clickUrl: click);
    }
    return null;
  }

  /// 旧约定：文件名去扩展名 → 官网同名路径（不进 carousel 子目录）。
  static String carouselFallbackClickUrl(String fileName) {
    var stem = fileName;
    final dot = stem.lastIndexOf('.');
    if (dot > 0) stem = stem.substring(0, dot);
    final base = kWorkshopUrl.endsWith('/')
        ? kWorkshopUrl.substring(0, kWorkshopUrl.length - 1)
        : kWorkshopUrl;
    return '$base/$stem';
  }
}
