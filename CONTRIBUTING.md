# 参与贡献

欢迎提交应用、核心包、内容创作工具及文档的改进。

1. 先查看 [作者指南](docs/AUTHOR_GUIDE.md)、[架构边界](docs/BOUNDARY.md) 与 [支持范围](docs/SUPPORT.md)。较大的行为变更建议先在 Issue 说明场景。
2. 从 `main` 创建分支，提交聚焦的修改。应用依赖方向应保持 `UI → gal_storage / gal_ai → gal_protocol`。
3. 按 [构建指南](docs/BUILD.md) 运行相关单文件测试和静态检查。修改内容时运行两包打包与体检；修改应用时验证 Android release 构建。
4. PR 说明实际行为变化、验证结果和未验证范围。不要提交 API Key、设置、存档、聊天日志、签名材料或本机路径配置。

默认包 JSON 由 `tools/rebuild_default_v2_demo.py` 生成，剧情原始文本在 `tools/legacy_content.json`；修改生成源后再重建。教学包可直接编辑 `content/daily_v2/`。

自有贡献沿用本项目 **GPL-3.0-only** 许可证。引入第三方代码、字体或素材时保留来源、许可证及必要的声明，并更新 `THIRD_PARTY_NOTICES.md`。
