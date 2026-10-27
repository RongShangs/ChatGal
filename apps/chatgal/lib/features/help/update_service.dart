import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 版本更新检测。
///
/// 玩家侧只关心三件事：现在是什么版本、有没有新版本、去哪下载。
/// 下载渠道两个：GitHub Releases（仓库 `RongShangs/ChatGal`）和游戏官网
/// `chatgal.rongshangs.top`（站点入口先留好，页面之后搭建）。
class UpdateInfo {
  const UpdateInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.hasUpdate,
    this.releaseNotes = '',
    this.checked = true,
  });

  /// 本机安装的应用版本（来自 [kAppVersion]）。
  final String currentVersion;

  /// 远端最新版本；检查失败时与 [currentVersion] 相同。
  final String latestVersion;

  final bool hasUpdate;
  final String releaseNotes;

  /// false = 这次没检查成功（网络/接口不可用），不代表没有更新。
  final bool checked;
}

/// 与 pubspec `version` 的主版本号保持一致（去掉 `+build`）。
const String kAppVersion = '0.1.6';

/// 公开发布仓库：只放内容包与 Release，不放应用源码。
const String kGithubRepoUrl = 'https://github.com/RongShangs/ChatGal';

/// GitHub Releases 列表页，下载 APK 走这里。
const String kGithubReleasesUrl = 'https://github.com/RongShangs/ChatGal/releases';

/// GitHub API：最新 Release 的 tag 形如 `v0.1.0`。
const String kGithubLatestReleaseApi =
    'https://api.github.com/repos/RongShangs/ChatGal/releases/latest';

/// 官网首页（下载与说明都在站点上；页面之后搭建）。
const String kOfficialSiteUrl = 'https://chatgal.rongshangs.top';

/// 兼容旧引用：帮助页直接用 [kOfficialSiteUrl]，不再拼 /download。
const String kOfficialDownloadUrl = kOfficialSiteUrl;

class UpdateService {
  const UpdateService();

  /// 把 `v1.2.3` / `1.2.3` / `1.2` 解析成可比较的整数三元组。
  /// 非法或空 → null。
  static List<int>? parseVersion(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return null;
    if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
    // 只要数字与点；`0.1.0-beta` 取 `0.1.0`。
    final m = RegExp(r'^(\d+)(?:\.(\d+))?(?:\.(\d+))?').firstMatch(s);
    if (m == null) return null;
    return [
      int.parse(m.group(1)!),
      int.parse(m.group(2) ?? '0'),
      int.parse(m.group(3) ?? '0'),
    ];
  }

  /// 远端是否比本机新。任一端解析失败 → false（不要误报更新）。
  static bool isRemoteNewer({
    required String current,
    required String remote,
  }) {
    final a = parseVersion(current);
    final b = parseVersion(remote);
    if (a == null || b == null) return false;
    for (var i = 0; i < 3; i++) {
      if (b[i] > a[i]) return true;
      if (b[i] < a[i]) return false;
    }
    return false;
  }

  /// 从 GitHub Release JSON 里取出 tag_name。
  static String? extractTagName(Map<String, dynamic> json) {
    final tag = json['tag_name'];
    if (tag is String && tag.trim().isNotEmpty) return tag.trim();
    return null;
  }

  static String _trimNotes(Object? body) {
    if (body is! String) return '';
    final s = body.trim();
    if (s.isEmpty) return '';
    // 玩家侧只看前几行就够，别把整篇更新日志糊上去。
    final lines = s.split('\n').where((l) => l.trim().isNotEmpty).toList();
    return lines.take(8).join('\n');
  }

  /// 检查更新。超时 / 断网 / 接口挂了都返回「检查未完成」，而不是假装最新。
  Future<UpdateInfo> check({Duration timeout = const Duration(seconds: 8)}) async {
    const current = kAppVersion;
    try {
      final client = HttpClient()..connectionTimeout = timeout;
      try {
        final req = await client.getUrl(Uri.parse(kGithubLatestReleaseApi));
        req.headers.set(HttpHeaders.userAgentHeader, 'ChatGal/$current');
        req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
        final resp = await req.close().timeout(timeout);
        final body = await resp.transform(utf8.decoder).join().timeout(timeout);
        if (resp.statusCode != 200) {
          return UpdateInfo(
            currentVersion: current,
            latestVersion: current,
            hasUpdate: false,
            checked: false,
          );
        }
        final decoded = jsonDecode(body);
        if (decoded is! Map<String, dynamic>) {
          return UpdateInfo(
            currentVersion: current,
            latestVersion: current,
            hasUpdate: false,
            checked: false,
          );
        }
        final tag = extractTagName(decoded) ?? current;
        final latest = parseVersion(tag) == null ? current : tag;
        return UpdateInfo(
          currentVersion: current,
          latestVersion: latest,
          hasUpdate: isRemoteNewer(current: current, remote: latest),
          releaseNotes: _trimNotes(decoded['body']),
          checked: true,
        );
      } finally {
        client.close(force: true);
      }
    } catch (_) {
      return UpdateInfo(
        currentVersion: current,
        latestVersion: current,
        hasUpdate: false,
        checked: false,
      );
    }
  }
}
