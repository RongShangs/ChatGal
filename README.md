<div align="center">

<img src="apps/chatgal/assets/app_icon.png" width="96" alt="ChatGal 图标" />

# ChatGal

**内容包驱动的 AI 互动 Gal：写自己的故事，也走进别人的故事。**

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/release/RongShangs/ChatGal)](https://github.com/RongShangs/ChatGal/releases/latest)
[![Platform](https://img.shields.io/badge/platform-Android-99B89A)](docs/BUILD.md)

[下载安装包](https://github.com/RongShangs/ChatGal/releases/latest) · [官网](https://chatgal.rongshangs.top) · [内容包创作指南](docs/AUTHOR_GUIDE.md) · [反馈问题](https://github.com/RongShangs/ChatGal/issues)

</div>

ChatGal 是基于 Flutter 的 Android AI 互动 Gal 客户端，内置内容包创作台。角色、情景、立绘、变量、事件和结局由可安装的 `.chatgal` 内容包定义，客户端负责对话、记忆、结算和存档。

本仓库现已包含完整应用源码、三个核心 Dart 包、两个内置内容包的源文件、构建与打包工具、测试和协议文档，并继续提供 APK Release 与独立内容包下载。项目采用 **GNU GPL v3.0（GPL-3.0-only）**，许可范围与第三方资源说明见 [许可证](LICENSE) 和 [第三方声明](THIRD_PARTY_NOTICES.md)。

## 界面预览

<table>
  <tr>
    <td align="center"><img src="docs/screenshots/home.jpg" width="250" alt="内容包主页与开始入口" /><br />内容包主页</td>
    <td align="center"><img src="docs/screenshots/studio-manifest.jpg" width="250" alt="创作台基础信息编辑" /><br />基础信息</td>
    <td align="center"><img src="docs/screenshots/studio-character.jpg" width="250" alt="角色状态与表情立绘矩阵" /><br />角色与立绘</td>
  </tr>
  <tr>
    <td align="center"><img src="docs/screenshots/studio-scene.jpg" width="250" alt="情景背景与入场词编辑" /><br />情景编辑</td>
    <td align="center"><img src="docs/screenshots/studio-event.jpg" width="250" alt="事件图片与文本编辑" /><br />事件编辑</td>
    <td>截图展示「你好戒戒」示例内容包与创作台。截图中的内容版本为 v263；当前源码内置默认包为 v264。</td>
  </tr>
</table>

## 可以做什么

- **游玩内容包**：选择故事包、新建游戏或读取存档，通过聊天推进剧情。
- **流式 AI 对话**：连接 OpenAI 兼容接口；支持流式显示、每轮立绘选择和两条快捷回复。正文完成后即可发送下一句，快捷回复在 agent 完成后启用。
- **记忆与结算**：五层记忆与关键词辅助长期对话；情景离场时根据证据结算变量，按条件进入后续情景、事件与结局。
- **内容包创作台**：编辑基础信息、角色、状态与情绪立绘、情景、事件及出口条件；导入图片、体检并导出内容包。
- **独立存档**：内容包隔离、多档管理、复制与导入导出；无法读取的旧档会保留并显示提示。
- **个性化**：画面、字体、记忆、模型供应商配置，以及自备服务的云端 TTS。

当前验证与支持范围以 [SUPPORT.md](docs/SUPPORT.md) 为准。首发平台为 Android；iOS 未验证。模型服务需自行配置，本仓库不包含服务端 Key 或模型权重；本地推理通过独立服务的兼容接口接入。

## 下载与开始

1. 从 [GitHub Releases](https://github.com/RongShangs/ChatGal/releases/latest) 或 [官网](https://chatgal.rongshangs.top) 下载 Android arm64 APK。
2. 打开应用，在「设置 → 模型供应商」填写兼容接口地址、模型名和所需 Key。
3. 选择内置内容包并开始，或在「内容包与存档」安装自己的 `.chatgal` 文件。
4. 在「内容包创作台」创建与编辑故事。文件格式和规则见 [作者指南](docs/AUTHOR_GUIDE.md)。

### 两个内置内容包

| 内容包 | 版本 | 结构 | 源文件 | 下载 |
| --- | --- | --- | --- | --- |
| 你好戒戒 | v264 | 1 角色、54 幕、7 事件；十四天主线与无尽分支 | [content/default_v2](content/default_v2) | [hellojj_default.chatgal](packs/hellojj_default.chatgal) |
| 与戒戒的每一天 | v9 | 1 角色、3 幕循环，适合学习结构 | [content/daily_v2](content/daily_v2) | [hellojj_daily.chatgal](packs/hellojj_daily.chatgal) |

两个内容包是独立于引擎的示例。`.chatgal` 是 ZIP 容器；顶层为 `manifest.json`、`characters/`、`stories/`、`events/` 与主页图片等。配置支持 JSONC 注释，入口情景固定为 `start`。

## 从源码构建

已使用的工具链：Flutter **3.47.2 stable**、Dart **3.13.2**、JDK **17** 和 Android SDK。Python 3 用于重新打包内容。

```sh
git clone https://github.com/RongShangs/ChatGal.git
cd ChatGal
cd apps/chatgal
flutter pub get
flutter build apk --release --target-platform android-arm64
```

输出为 `apps/chatgal/build/app/outputs/flutter-apk/app-release.apk`。内置 `.chatgal` 文件已纳入仓库，普通构建无需重新导入旧 Fusion 项目，也无需仓库外的文件。

修改内容后，在仓库根目录运行：

```sh
python tools/pack_default_v2.py
```

先在 `packages/gal_protocol` 执行 `dart pub get`。完整环境配置、依赖准备、测试、内容重建和签名说明见 [构建指南](docs/BUILD.md)。当前 Release 构建沿用 debug 签名；自行构建的签名可能不同于已发布 APK，覆盖安装前请导出存档。

## 仓库结构

```text
apps/chatgal/           Flutter Android 客户端、创作台与应用测试
packages/gal_protocol/ 内容包/存档协议、模型与结构校验
packages/gal_ai/       对话、立绘 agent、记忆、结算和事务
packages/gal_storage/  包安装与导出、存档和创作工程持久化
content/default_v2/   「你好戒戒」内容源（含全部图片）
content/daily_v2/     「与戒戒的每一天」内容源
packs/               供直接下载安装的两个内置包
examples/            最小包与选择题示例包
schemas/v2/          JSON Schema 与协议说明
tools/               打包、内容重建、历史导入工具与文本数据
docs/                作者指南、架构、构建、支持范围与截图
```

依赖方向：`apps/chatgal → gal_storage + gal_ai → gal_protocol`。

## 文档与参与

- [构建与验证](docs/BUILD.md)
- [内容包作者指南](docs/AUTHOR_GUIDE.md)
- [支持范围与已知问题](docs/SUPPORT.md)
- [分层边界](docs/BOUNDARY.md) · [协议与 Schema](schemas/v2/README.md)
- [内容包格式的重构记录](docs/内容包结构改动规划.md)（历史设计以当前代码与作者指南为准）
- [参与贡献](CONTRIBUTING.md) · [开源发布记录](docs/OPEN_SOURCE.md)

欢迎通过 [Issues](https://github.com/RongShangs/ChatGal/issues) 反馈问题，或提交 Pull Request。反馈时请提供应用版本、复现步骤与已去除 Key、聊天隐私的日志。

QQ 交流群：`1054545834` · [支持作者](https://afdian.com/a/rongshang) · [作者博客](https://rongshangs.top/) · [隐私政策](https://rongshangs.github.io/chatgal_privacy/)

## 许可证

本项目自有代码与内容采用 **GNU General Public License v3.0 only**（SPDX：`GPL-3.0-only`），完整条款见 [LICENSE](LICENSE)。分发修改版时，请遵守 GPLv3 关于许可证、修改说明与对应源码的要求。

站酷快乐体按 **SIL Open Font License 1.1** 分发，Gradle Wrapper 按 **Apache License 2.0** 分发；第三方依赖与资源的原有许可继续适用，详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
