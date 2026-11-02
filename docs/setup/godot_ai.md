# Godot AI 与 Trae 配置

环境版本统一见 [开发说明](../development.md#环境要求)。

1. 使用要求的 Godot 版本打开本项目。
2. 在项目设置 → 插件确认 Godot AI 与 GdUnit4 已启用。
3. 打开 Godot AI 面板，在客户端列表选择 Trae，点击 Configure。
4. 若客户端提示重新加载，重新加载 Trae；保持编辑器打开。
5. 调用编辑器状态工具，确认返回的项目为 **ProjectFactory**。

客户端路径、端口、MCP 配置属于机器设置，仓库安全与场景验证要求见 [AGENTS](../../AGENTS.md)。
如果没有连接，先检查当前项目插件是否启用、编辑器与 MCP 服务是否在同一机器/网络环境。

无头检查命令与输入验证限制见 [开发说明](../development.md#本地检查)。
