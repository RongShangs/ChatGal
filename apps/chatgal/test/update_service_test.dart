import 'package:chatgal/features/help/update_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// 版本比较：远端比本机新才亮黄点；解析失败不要误报。
void main() {
  test('parseVersion 支持 v 前缀与缺省段', () {
    expect(UpdateService.parseVersion('v0.1.0'), [0, 1, 0]);
    expect(UpdateService.parseVersion('0.2'), [0, 2, 0]);
    expect(UpdateService.parseVersion('1'), [1, 0, 0]);
    expect(UpdateService.parseVersion(''), isNull);
    expect(UpdateService.parseVersion('abc'), isNull);
  });

  test('isRemoteNewer 逐段比较', () {
    expect(
      UpdateService.isRemoteNewer(current: '0.1.0', remote: 'v0.1.1'),
      isTrue,
    );
    expect(
      UpdateService.isRemoteNewer(current: '0.1.0', remote: '0.2.0'),
      isTrue,
    );
    expect(
      UpdateService.isRemoteNewer(current: '0.1.0', remote: 'v0.1.0'),
      isFalse,
    );
    expect(
      UpdateService.isRemoteNewer(current: '0.2.0', remote: 'v0.1.9'),
      isFalse,
    );
    // 解析失败 → 不报更新
    expect(
      UpdateService.isRemoteNewer(current: '0.1.0', remote: 'nightly'),
      isFalse,
    );
    expect(
      UpdateService.isRemoteNewer(current: 'bad', remote: 'v9.9.9'),
      isFalse,
    );
  });

  test('extractTagName 取 GitHub tag', () {
    expect(
      UpdateService.extractTagName({'tag_name': 'v0.3.1'}),
      'v0.3.1',
    );
    expect(UpdateService.extractTagName({'tag_name': '  '}), isNull);
    expect(UpdateService.extractTagName({}), isNull);
  });
}
