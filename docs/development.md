# 开发与版本管理

开发流程、代码约束、文档维护和 Git 安全边界统一见 [AGENTS](../AGENTS.md)。

## 环境要求

- Godot **4.7.2**、Forward Plus、Jolt Physics，业务脚本使用 typed GDScript。
- Godot AI **4.2.3** 与 GdUnit4 **6.2.1** 已 vendored；启用状态见 `project.godot`。
- 验证需要 Bash、Python 3 和 Git；插件连接步骤见 [AI 配置](setup/godot_ai.md)。

升级时同步版本要求、`scripts/verify.sh` 的检查和 CI 配置，并完整回归。

中文建造提示使用随项目打包的 Noto Sans SC 字符子集，
许可见 [OFL](../assets/fonts/OFL.txt)。新增中文文案时同步扩充字体子集；
游戏运行与验证无需联网下载字体，也无需安装系统中文字体。

## 本地检查

```bash
bash scripts/verify.sh
```

在仓库根目录运行；也可从任意目录使用该脚本的实际路径调用。
默认查找 `godot`，macOS 可自动找到标准安装；其他位置用 `GODOT_BIN` 指定引擎。
依次检查插件版本、导入、业务类型安全、全部 GdUnit4 测试、120 帧主场景运行和 diff 空白。
临时日志放在系统临时目录，测试报告在 Godot 用户数据目录，均不纳入版本控制。
检查流程不修改 Git 配置，也不改 HOME。

类型检查使用 Python 3，在系统临时目录复制最小项目，用正常无头编辑器将业务脚本的
六类类型安全警告提升为错误，并预加载所有业务脚本，不污染原项目编辑器设置，
不修改 vendored 插件。正式项目设置仍保留同类警告。

GdUnit4 的无头模式不能保证引擎真实派发键鼠事件，集成测试通过玩家公开的
`handle_input(event)` 边界传入真实 InputEvent，验证输入→信号→规则→碰撞链路；
真实窗口输入与视觉必须另做编辑器验证。

## 版本管理与提交检查

源码、测试、规格、`.gd.uid` 和需要的 `.import` 配置纳入版本管理；
`.godot/`、构建产物、测试报告与临时日志由 `.gitignore` 忽略。

已提供可执行 `.githooks/pre-commit`。Git 默认不会自动安装仓库内 hook。
为避免写入本机 Git 配置，用户需要提交时使用单次参数：

```bash
git add scripts/core/voxel_world_data.gd tests/unit/test_voxel_world_data.gd
git -c core.hooksPath=.githooks commit -m "fix: enforce voxel placement bounds"
```

每次提交均使用同一命令模式。hook 执行完整游戏验证并检查工作树，
因此提交前应保证已暂存内容与验证内容一致。

## CI 与协作

`.github/workflows/verify.yml` 在 push 和 pull_request 上安装上述要求的引擎并运行同一检查。
CI 文件已配置，只有上传到 GitHub 后才会实际执行；本地验证不代表远端 CI 已运行。
远端仓库创建后建议保护 main：必须通过 Godot verification 与独立代码审查方可合并。
当前未配置远端或服务端分支保护。

第三方插件从参考模板复制，保留各插件自带许可。
