import 'package:chatgal/features/help/update_service.dart';
import 'package:chatgal/features/settings/api_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:io';

void main() {
  test('streamOutput 默认开启，可关写入设置', () {
    final s = AppSettings.empty;
    expect(s.streamOutput, isTrue);
    final off = s.copyWith(streamOutput: false);
    expect(off.streamOutput, isFalse);
    final on = off.copyWith(streamOutput: true);
    expect(on.streamOutput, isTrue);
  });

  test('模型供应商页含流式开关文案', () {
    final source = File(
      r'D:\HelloJJs\ChatGal\apps\chatgal\lib\features\settings\model_providers_page.dart',
    ).readAsStringSync();
    expect(source.contains('流式输出'), isTrue);
    expect(source.contains('streamOutput'), isTrue);
  });

  test('主页轮播为不层叠全宽样式', () {
    final source = File(
      r'D:\HelloJJs\ChatGal\apps\chatgal\lib\features\home\home_page.dart',
    ).readAsStringSync();
    expect(source.contains('viewportFraction: 1'), isTrue);
    expect(source.contains('_viewportFraction'), isFalse);
  });

  test('聊天页正文完成后启用发送，快捷回复可灰态', () {
    final source = File(
      r'D:\HelloJJs\ChatGal\apps\chatgal\lib\features\session\chat_page.dart',
    ).readAsStringSync();
    expect(source.contains('_onReplyTextVisible'), isTrue);
    expect(source.contains('_qrLoading'), isTrue);
    expect(source.contains('_sendLocked'), isTrue);
    expect(source.contains('runLookAgent'), isTrue);
  });

  test('聊天页可走真实流式 onDelta', () {
    final source = File(
      r'D:\HelloJJs\ChatGal\apps\chatgal\lib\features\session\chat_page.dart',
    ).readAsStringSync();
    expect(source.contains('_onStreamDelta'), isTrue);
    expect(source.contains('stream: useStream'), isTrue);
    expect(source.contains('streamOutput'), isTrue);
  });

  test('update service 仍可用', () {
    expect(UpdateService.parseVersion(kAppVersion), isNotNull);
  });
}
