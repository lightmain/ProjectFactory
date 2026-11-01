# 开发与版本管理

## 工作流

1. 阅读 AGENTS、相关规格和已有实现；使用 `rg` 查找复用点。
2. 在 `docs/features/` 写清行为、边界、验收与实施任务。
3. 创建 `feat/<topic>` 或 `fix/<topic>` 分支。
4. 添加重要规则/行为的测试并运行，确认 RED；修复 bug 时先证明旧实现失败。
5. 实现最小功能并确认 GREEN；规则在 core，场景只接收数据、输入和信号。
6. 每次场景修改后运行 `bash scripts/verify.sh`；视觉改动用编辑器运行、检查日志及截图。
7. 单开独立 subagent，提供规格、测试与变更范围；先审测试再审实现，
   检查正确性、可读性、架构、安全与性能。
8. 处理 Critical/Important 项后复验，将结果写入 `docs/reviews/`。
9. 用户要求提交时按具体文件暂存并创建小型提交，提交信息采用 Conventional Commits。

当前仓库本地默认分支为 `main`。不预设远端地址，不提交凭据或本机 MCP 配置。
源码、测试、规格、`.gd.uid` 和需要的 `.import` 配置一起版本管理；
`.godot/`、构建产物、测试报告与临时日志忽略。

## 本地检查

```bash
bash scripts/verify.sh
```

支持 `GODOT_BIN` 指定引擎。检查流程不修改 Git 配置，也不改 HOME。
类型检查使用 Python 3，在系统临时目录复制最小项目，用正常无头编辑器将业务脚本的
六类类型安全警告提升为错误，并预加载所有业务脚本，不污染原项目编辑器设置，
不修改 vendored 插件。正式项目设置仍保留同类警告。

GdUnit4 的无头模式不能保证引擎真实派发键鼠事件，集成测试通过玩家公开的
`handle_input(event)` 边界传入真实 InputEvent，验证输入→信号→规则→碰撞链路；
真实窗口输入与视觉必须另做编辑器验证。

## 提交检查 hook

已提供可执行 `.githooks/pre-commit`。Git 默认不会自动安装仓库内 hook。
为避免写入本机 Git 配置，用户需要提交时使用单次参数：

```bash
git add scripts/core/voxel_world_data.gd tests/unit/test_voxel_world_data.gd
git -c core.hooksPath=.githooks commit -m "fix: enforce voxel placement bounds"
```

每次提交均使用同一命令模式。不要 `--no-verify`、amend 或强制推送。
hook 会检查工作树，因此提交前应保证已暂存内容与验证内容一致。

## CI 与协作

`.github/workflows/verify.yml` 在 push 和 pull_request 上安装固定 Godot 4.7.2 并运行同一检查。
CI 文件已配置，只有上传到 GitHub 后才会实际执行；本地验证不代表远端 CI 已运行。
远端仓库创建后建议保护 main：必须通过 Godot verification 与独立代码审查方可合并。
当前未配置远端或服务端分支保护。

第三方插件直接从参考模板复制，不编辑其源码，保留各插件自带许可。
升级时更新版本说明、插件检查并完整回归。
