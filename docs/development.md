# 开发与版本管理

开发流程、代码约束、文档维护和 Git 安全边界统一见 [AGENTS](../AGENTS.md)。

## 环境要求

- Godot **4.7.2**、Forward Plus、Jolt Physics，业务脚本使用 typed GDScript。
- Godot AI **4.4.2** 与 GdUnit4 **6.2.1** 已 vendored；启用状态见 `project.godot`。
- 验证需要 Bash、Python 3 和 Git；插件连接步骤见 [AI 配置](setup/godot_ai.md)。

升级时同步版本要求、`scripts/verify.sh` 的检查和 CI 配置，并完整回归。

中文界面与用户输入的世界／存档名称使用随项目打包的 Noto Sans SC 字体，
许可见 [OFL](../assets/fonts/OFL.txt)；
游戏运行与验证无需联网下载字体，也无需安装系统中文字体。

## 本地检查

```bash
bash scripts/verify.sh
```

在仓库根目录运行；也可从任意目录使用该脚本的实际路径调用。
默认查找 `godot`，macOS 可自动找到标准安装；其他位置用 `GODOT_BIN` 指定引擎。
依次检查插件版本、验证脚本回归、导入、首次跨进程启动、业务类型安全、
全部 GdUnit4 测试、再次跨进程启动、120 帧主场景运行、原项目缓存与 diff 空白。
引擎步骤在系统临时目录的工作副本运行，包含未提交资源，排除 `.godot/`、
Git、本机配置及生成输出，避免与已打开的编辑器共用缓存。
结束时删除工作副本，日志与测试报告留在输出的临时目录，均不纳入版本控制。
检查流程不修改 Git 配置，也不改 HOME。

类型检查使用 Python 3，在系统临时目录复制隔离项目，用正常无头编辑器将业务脚本的
六类类型安全警告提升为错误，并预加载所有业务脚本，不污染原项目编辑器设置，
不修改 vendored 插件。正式项目设置仍保留同类警告。

跨进程启动使用两个新的真实 Godot 进程，保留项目配置的启动场景；
只在临时副本注入测试 Autoload，通过可见按钮的信号验证主菜单、
新游戏命名与确认、第一人称玩家、暂停和继续。检查后恢复副本配置。
第二次启动复用经过全部测试的类缓存，不重新导入；每次必须输出成功标记，
脚本错误、异常退出、超时或缺标记均失败。
完整流程同时检查原项目全局类表和文件系统缓存的内容及修改时间，
连原项目开始时没有缓存、后来被验证创建的情况也会失败。
原项目已存在类缓存时，还核对业务脚本的当前类名与注册路径，
避免把检查开始前就缺少新类的旧缓存当成有效基线。

新建 `class_name` 脚本后，必须确认实时编辑器已注册该类型并能启动项目。
无头副本导入通过不能证明原编辑器内存中的全局类表已刷新。
若全盘扫描仍遗漏新类型，保存已编辑场景后重新打开编辑器，再验证启动；
不要在已打开的原项目中另跑无头导入来暂时覆盖缓存。

GdUnit4 的无头模式不能保证引擎真实派发键鼠事件，集成测试通过玩家公开的
`handle_input(event)` 边界传入真实 InputEvent，验证输入→信号→规则→碰撞链路；
真实窗口输入与视觉必须另做编辑器验证。

## 可选 Rust 运输后端

本仓库不携带原生二进制；RustConveyor 的安装脚本同时生成扩展描述和共享库，
安装目录由 Git 忽略。未安装时默认 GDScript 后端可运行，
显式请求 Rust 会返回错误并停止该物流后端。行为及验收见
[002 接入规格](features/prealpha-2/002-rust-conveyor-integration.md)。
在 RustConveyor 源码根目录执行，使用所选 Godot 项目的实际路径：

```bash
bash godot/install.sh /path/to/project-factory release
```

然后重新启动 Godot 编辑器；原生库不可热重载。
安装后的 `verify.sh` 除原检查外还执行原生运输契约和宿主回归脚本。
未安装扩展的 CI 只验证默认后端；目前没有发布到注册表的原生包或自动下载步骤。
压力测量使用真实磁盘存档并挂载完整主场景：

```bash
godot --headless --path . -s res://scripts/pressure_native_benchmark.gd \
  -- 128 64 /tmp/new-million-pressure-report 300 120 rust
```

输出目录必须尚不存在；保留原始样本、bank 存档和阶段报告。
去掉 `--headless` 可同时生成运行截图。用 `/usr/bin/time -l` 包裹命令测量进程 RSS；
核心、绑定、模拟和整场景提交分别计量，绑定耗时包含核心耗时。

顺序运行完整四尺度矩阵或仅百万窗口：

```bash
RUST_CONVEYOR_SOURCE=/path/to/RustConveyor \
  bash scripts/run_native_pressure.sh /tmp/new-native-matrix rust headless
RUST_CONVEYOR_SOURCE=/path/to/RustConveyor \
  bash scripts/run_native_pressure.sh /tmp/new-native-window rust window million
```

每例预热 120 tick、测量 300 tick；目录必须尚不存在。
`provenance.json` 记录实际命令、两仓库源码输入指纹及安装库的构建信息和哈希，
`work_samples.json` 将每 tick 的工作量与时间样本对应。
没有 Rust 源码路径或安装库构建清单时明确标为未知来源，不从当前源码推定旧库来源。
`process_interval` 从每个已测 tick 起点量至下一帧起点，包含最后 tick 之后的引擎工作；
人口审计和报告写入在墙钟测量窗口外，分别计量。

编辑器全局目录受限时，可在工作区内使用独立 Godot 可执行文件和 `_sc_`
标记隔离编辑器数据；macOS 游戏用户目录还需为 Godot 子进程单独设置 HOME。
验证编排器与 Git 保持原 HOME。实际验证过的隔离步骤和限制见
[2026-11-23 环境记录](reviews/2026-11-23-verification-environment.md)。

## 当前状态与文档检查

新对话的阅读顺序、版本规格状态及继承规则统一见 [AGENTS](../AGENTS.md)；
版本与规格链接见 [README](../README.md#版本规格入口)。
在仓库根目录查询实际工作树、近期变更、远端连接与已有 tag：

```bash
git status --short
git log -5 --oneline
git remote -v
git tag --list
```

规格说明应有行为；确认实际实现时，结合相关代码、测试和当次 [本地检查](#本地检查)。
测试总数与通过情况读取本次输出，CI 结果与服务端分支保护查询 GitHub 的实际状态；
历史审查仅证明记录日期及范围内的结果，不能代替当前验证。

纯文档变更检查本地链接及标题锚点、路径引用、内容一致性与 `git diff --check`，
并按 AGENTS 完成独立审查；无需运行游戏测试或视觉验证。
涉及版本规格时，核对新增、继承和替代链接，确保待实施内容未覆盖当前规则。
没有游戏变更时，不把历史游戏测试结果写成此次验证结果。

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
本地验证不代表远端 CI 已运行；各次执行结果按 [状态查询](#当前状态与文档检查) 核实。
建议保护 main：必须通过 Godot verification 与独立代码审查方可合并；
该建议不表示服务端已经配置保护。

第三方插件从参考模板复制，保留各插件自带许可。
