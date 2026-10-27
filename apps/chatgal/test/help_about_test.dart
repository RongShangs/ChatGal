import 'dart:io';

import 'package:chatgal/features/help/update_service.dart';
import 'package:chatgal/features/settings/privacy_page.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「帮助与关于」与设置页迁移：常量 + 源码结构断言。
///
/// 页面本体需要 `AppServices`（真 IO），widget 层不整树挂载；
/// 玩家可见文案的完整性靠源码关键字钉住，运行日志/网络检查分别由
/// 单测与真机构成验证。
void main() {
  test('隐私政策与交流/支持常量', () {
    expect(kPrivacyPolicyUrl, 'https://rongshangs.github.io/chatgal_privacy/');
    expect(kChatGalQqGroup, '1054545834');
    expect(kAfdianUrl, 'https://afdian.com/a/rongshang');
    expect(kGithubRepoUrl, 'https://github.com/RongShangs/ChatGal');
    expect(kOfficialSiteUrl, 'https://chatgal.rongshangs.top');
  });

  test('帮助与关于页源码含必要分区文案', () {
    final source = File(
      r'D:\HelloJJs\ChatGal\apps\chatgal\lib\features\help\help_about_page.dart',
    ).readAsStringSync();
    for (final needle in [
      '帮助与关于',
      '版本与更新',
      'ChatGal QQ 交流群',
      'kChatGalQqGroup',
      '支持戎戎',
      '爱发电',
      'kAfdianUrl',
      '隐私政策',
      '反馈',
      '运行日志',
      'GitHub',
      '从ChatGal官网下载',
      'kOfficialSiteUrl',
      'kPrivacyPolicyUrl',
      'kGithubRepoUrl',
      '复制',
      '_copyQqGroup',
    ]) {
      expect(source.contains(needle), isTrue, reason: '缺少：$needle');
    }
    expect(source.contains('hellojj-privacy'), isFalse);
  });

  test('设置页不再包含关于整组', () {
    final source = File(
      r'D:\HelloJJs\ChatGal\apps\chatgal\lib\features\settings\settings_page.dart',
    ).readAsStringSync();
    expect(source.contains("SettingsSectionTitle('关于'"), isFalse);
    expect(source.contains("title: '隐私政策'"), isFalse);
    expect(source.contains("title: '反馈'"), isFalse);
    expect(source.contains("title: '运行日志'"), isFalse);
  });

  test('主页功能入口含帮助与关于，且有更新小黄点', () {
    final source = File(
      r'D:\HelloJJs\ChatGal\apps\chatgal\lib\features\home\home_page.dart',
    ).readAsStringSync();
    expect(source.contains("'帮助与关于'"), isTrue);
    expect(source.contains('showBadge'), isTrue);
    expect(source.contains('_hasUpdate'), isTrue);
    expect(source.contains('_HomeCarousel'), isTrue);
    expect(source.contains('_hubWaterfallArt'), isTrue);
    // 帮助入口在创作区下方
    final hub = source.indexOf('_creatorHub(t)');
    final help = source.indexOf("'帮助与关于'");
    expect(hub, greaterThan(0));
    expect(help, greaterThan(hub));
  });

  test('包名已改为 top.rongshangs.chatgal', () {
    final gradle = File(
      r'D:\HelloJJs\ChatGal\apps\chatgal\android\app\build.gradle.kts',
    ).readAsStringSync();
    expect(gradle.contains('applicationId = "top.rongshangs.chatgal"'), isTrue);
    expect(gradle.contains('namespace = "top.rongshangs.chatgal"'), isTrue);
    expect(gradle.contains('top.rongshangs.chatgal.chatgal'), isFalse);
    final kt = File(
      r'D:\HelloJJs\ChatGal\apps\chatgal\android\app\src\main\kotlin\top\rongshangs\chatgal\MainActivity.kt',
    );
    expect(kt.existsSync(), isTrue);
    expect(
      kt.readAsStringSync().startsWith('package top.rongshangs.chatgal'),
      isTrue,
    );
  });

  test('开屏用户须知不再是占位文案', () {
    final source = File(
      r'D:\HelloJJs\ChatGal\apps\chatgal\lib\features\splash\splash_page.dart',
    ).readAsStringSync();
    expect(source.contains('开发中，仅占位'), isFalse);
    expect(source.contains('欢迎来到 ChatGal'), isTrue);
    expect(source.contains('隐私政策'), isTrue);
  });

  test('update service 导出可用', () {
    expect(kAppVersion, isNotEmpty);
    expect(UpdateService.parseVersion(kAppVersion), isNotNull);
  });
}
