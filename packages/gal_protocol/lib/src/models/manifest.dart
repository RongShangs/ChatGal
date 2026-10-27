import '../validation_error.dart';

/// Package identity + metadata (manifest.json).
///
/// 只留作者真正要填的东西：包身份（packageId/version）、展示信息（name/author/
/// description）与变量注册表（由 [VariableRegistry] 直接读原始 JSON）。
///
/// 已经删掉的字段（作者不用再写，写了也读不到）：`schemaVersion`、
/// `engineCompatibility`、`entrypoints`、`characters`、`homeBackground`、
/// `assetIndex`、`characterVariables`、`license`、`contentTags`。
/// 它们要么是引擎层的固定约定（入口固定 `start`、主页背景固定 `home.png`、
/// 角色由 `characters/` 下的文件夹决定），要么是无人使用的元数据。
class PackageManifest {
  const PackageManifest({
    required this.packageId,
    required this.version,
    required this.name,
    required this.author,
    required this.description,
  });

  final String packageId;

  /// 版本号**只能是数字**，而且只能往高版本升（打包脚本会拦）。
  /// 它同时是「默认包是否需要重装」的判据：与
  /// `AppServices.defaultPackageVersion` 必须一致。
  final String version;
  final String name;
  final String author;
  final String description;

  /// 入口情景固定为 `start`（包必须有 `stories/start.json`）。
  static const entrypointId = 'start';

  /// 主页背景固定用包根的 `home.png`。
  static const homeBackgroundFile = 'home.png';

  factory PackageManifest.fromJson(
    Map<String, Object?> json, {
    String path = '/manifest',
  }) {
    final errors = <ValidationError>[];
    Object? req(String key) {
      if (!json.containsKey(key)) {
        errors.add(ProtocolErrors.missing(path, key));
        return null;
      }
      return json[key];
    }

    final packageId = req('packageId');
    final version = req('version');
    final name = req('name');
    // author / description 允许缺省：它们只影响展示，不影响能否玩。
    if (errors.isNotEmpty) {
      throw PackageFormatException(errors);
    }

    String asString(Object? v, String key) {
      if (v is! String || v.isEmpty) {
        throw PackageFormatException([
          ProtocolErrors.type(path, key, 'non-empty string', v),
        ]);
      }
      return v;
    }

    final packageIdStr = asString(packageId, 'packageId');
    // packageId 会直接参与安装路径拼接（packages/<packageId>/<version>）。
    // 只校验非空时，`../outside` 会被接受并解析到 packages 目录之外。
    // 限制为安全字符：字母数字 . _ -，禁止路径分隔符与 ..。
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$').hasMatch(packageIdStr) ||
        packageIdStr.contains('..')) {
      throw PackageFormatException([
        ValidationError(
          code: 'invalid_package_id',
          message: 'packageId 只能包含字母、数字、点、下划线、连字符，'
                '且不能以点开头、不能含 ..（会逃出安装目录）',
          path: '$path/packageId',
          hint: 'value=$packageIdStr',
        ),
      ]);
    }

    final versionStr = asString(version, 'version');
    if (!RegExp(r'^[0-9]+$').hasMatch(versionStr)) {
      throw PackageFormatException([
        ValidationError(
          code: 'invalid_version',
          message: 'version 只能是数字（例如 "250"），不能带字母或点',
          path: '$path/version',
          hint: 'value=$versionStr',
        ),
      ]);
    }

    return PackageManifest(
      packageId: packageIdStr,
      version: versionStr,
      name: asString(name, 'name'),
      author: '${json['author'] ?? ''}',
      description: '${json['description'] ?? ''}',
    );
  }

  Map<String, Object?> toJson() => {
        'packageId': packageId,
        'version': version,
        'name': name,
        'author': author,
        'description': description,
      };
}

/// Thrown when raw JSON cannot become a typed model.
class PackageFormatException implements Exception {
  PackageFormatException(this.errors);
  final List<ValidationError> errors;

  @override
  String toString() => 'PackageFormatException(${errors.join('; ')})';
}
