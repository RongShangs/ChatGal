# 构建与验证

本指南从公开仓库的干净检出开始。Android 是当前支持的平台。

## 工具链

| 工具 | 已使用版本 | 说明 |
| --- | --- | --- |
| Flutter | 3.47.2 stable | 将 Flutter 的 `bin` 加入 PATH |
| Dart | 3.13.2 | Flutter 自带；应用要求 `^3.13.2` |
| JDK | 17 | 设置 `JAVA_HOME` |
| Android SDK | 对应 Flutter 的 compile/target SDK | 安装 platform-tools、build-tools、cmdline-tools 并接受许可 |
| Python | 3 | 打包/重建内容用；仅标准库 |
| Git | 近期版本 | 克隆仓库、版本比对 |

运行 `flutter doctor` 确认 Android 工具链就绪。首次构建需要联网下载 Dart、Gradle 和 Android 依赖。
Windows 上如未自动发现 SDK，可用 `flutter config --android-sdk <SDK目录>`；具体目录由你选择。
`android/local.properties` 是本机文件，由 Flutter 生成，不需要从别人机器复制。

## 获取源码与构建 APK

```sh
git clone https://github.com/RongShangs/ChatGal.git
cd ChatGal/apps/chatgal
flutter pub get
flutter build apk --release --target-platform android-arm64
```

输出：`apps/chatgal/build/app/outputs/flutter-apk/app-release.apk`。
调试设备上运行可使用 `flutter run`。

仓库包含内置 `.chatgal` 资源以及 Gradle Wrapper，直接构建不依赖旧 Fusion 项目、仓库外资料或 API Key。模型服务在应用设置里另行配置。

当前发布版本是 **0.1.6+7**，applicationId 为 `top.rongshangs.chatgal`。
当前 `release` 构建沿用 `debug` 签名配置；不同机器的 debug 签名可能不同，自行构建的 APK 不保证能覆盖官方 APK。改用正式签名时需自行保管签名材料，勿将密钥、口令或 `key.properties` 提交到仓库。

## 准备独立包依赖

以下命令从仓库根目录逐条执行；`flutter pub get` 只准备应用依赖，单独运行 Dart 包工具与测试前也要为各包执行 `dart pub get`。

```sh
cd packages/gal_protocol
dart pub get
cd ../gal_ai
dart pub get
cd ../gal_storage
dart pub get
cd ../..
```

## 内容打包与重建

从仓库根目录执行：

```sh
python tools/pack_default_v2.py
```

脚本调用同一份 Dart `PackageValidator`，通过后重建应用资源目录里的默认包和教学包。
先准备 `gal_protocol` 的依赖，并确认 `dart` 在 PATH。
内容包下载副本位于 `packs/`；发布内容更新时将应用资源中的两包同步复制到 `packs/`，保持两份字节一致。

默认包版本为 **264**，教学包版本为 **9**。内容变更时须递增版本并同步 `manifest.json` 与 `app_services.dart`；默认包还需同步重建脚本中的 `VERSION`。纯源码/文档修改无需增加内容版本。

默认内容的作者工具为：

```sh
python tools/rebuild_default_v2_demo.py
python tools/pack_default_v2.py
```

重建工具从 `tools/legacy_content.json` 及仓库内已有图片生成默认包文本，会覆盖默认包的 JSON/JSONC。修改默认剧情时应更新它的数据或生成逻辑，避免手改结果被覆盖。
正常构建不需要运行重建工具。

`tools/import_legacy_content.py <旧Fusion项目根目录>` 是历史迁移工具，只用于重新导入原 Lua 项目。导入后的 `legacy_content.json` 已完整入库；缺少旧 Fusion 目录不会影响打包、测试或应用构建。

仅校验一个目录：

```sh
cd packages/gal_protocol
dart run tool/validate_pack.dart ../../content/default_v2
```

## 静态检查与测试

在对应 Dart 包目录运行 `dart analyze`，在 `apps/chatgal` 运行 `flutter analyze`。
应用历史基线包含 info 级建议；判断失败时请区分 info、warning 与 error，现有细节见 [支持范围](SUPPORT.md)。

按单个文件运行测试，避免本机出现过的整批测试未完成问题：

```sh
cd packages/gal_protocol
dart test test/package_validator_test.dart
cd ../../apps/chatgal
flutter test --no-pub test/content_version_sync_test.dart
```

其它测试文件位于各项目的 `test/` 目录。Windows PowerShell 如遇 `%PROGRAMFILES(X86)% not found`，先设置：

```powershell
$env:PROGRAMFILES = 'C:\Program Files'
${env:ProgramFiles(x86)} = 'C:\Program Files (x86)'
```

自动化测试与构建通过不代表完成真机验证。界面手感、长时间游玩与 TTS 连续播放仍应在真实设备检查。
