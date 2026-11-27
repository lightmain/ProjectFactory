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
每个引擎进程默认超时 1800 秒；用 `PRESSURE_TIMEOUT_SECONDS` 指定正数秒数，
用可选的 `PRESSURE_MAX_RSS_BYTES` 指定正整数 RSS 字节上限，例如：

```bash
PRESSURE_TIMEOUT_SECONDS=120 PRESSURE_MAX_RSS_BYTES=4294967296 \
  RUST_CONVEYOR_SOURCE=/path/to/RustConveyor \
  bash scripts/run_native_pressure.sh /tmp/new-bounded-window gdscript headless million
```

RSS 每 200 ms 采样，阶段边界也检查；观测超限后停止引擎，并非操作系统硬内存配额。
超时或超限返回失败，`phases.json` 保留已有阶段、RSS、限额及 `stop_reason`，
对应日志保留引擎输出，失败例不进入有效比较。没有指定 RSS 上限时仅受超时限制。
`provenance.json` 记录实际命令、两仓库源码输入指纹及安装库的构建信息和哈希，
`work_samples.json` 将每 tick 的工作量与时间样本对应。
没有 Rust 源码路径或安装库构建清单时明确标为未知来源，不从当前源码推定旧库来源。
`process_interval` 从每个已测 tick 起点量至下一帧起点，包含最后 tick 之后的引擎工作；
人口审计和报告写入在墙钟测量窗口外，分别计量。

编辑器全局目录受限时，可在工作区内使用独立 Godot 可执行文件和 `_sc_`
标记隔离编辑器数据；macOS 游戏用户目录还需为 Godot 子进程单独设置 HOME。
验证编排器与 Git 保持原 HOME。实际验证过的隔离步骤和限制见
[2026-11-23 环境记录](reviews/2026-11-23-verification-environment.md)。

## alpha-2.0 Rust workspace

`rust/` 是完整数据后端的独立 workspace，当前切片状态与验收范围见
[003 迁移计划](features/alpha-2.0/003-migration-plan.md#m01rust-workspace桥接能力和黄金输入m依赖-m00)。
依赖、最低 Rust 版本和编译 profile 以 [Cargo 配置](../rust/Cargo.toml)为准。
连续运输依赖独立 `RustConveyor` 源码，当前 Cargo 相对路径要求它与 `Godot/`
位于同一父目录；具体位置见 `factory_core/Cargo.toml`。
构建身份同时包含该包的源码指纹，安装清单包含其 MIT 许可。
安装器目前仅支持 macOS arm64，生成库、描述文件、构建身份和依赖许可／源码归档；
安装目标必须是已有 Godot 项目，拒绝已有安装和 `native` 父目录符号链接。
新扩展提供握手及同步小工厂；主菜单的“新后端试玩”使用该路径，
默认“新游戏”仍使用原后端。

纯 Rust 的后台执行、时间切片、线程回收及保存作业与接入边界见
[M06](features/alpha-2.0/003-migration-plan.md#m06后台执行时钟与可靠协议l依赖-m05)。
最新单操作／一次领取及暂停后保存契约见
[受控等待](features/alpha-2.0/002-backend-protocol-and-persistence.md#受控等待第-17-项)。
该通道已纳入 workspace 测试，试玩仍使用同步入口，扩展尚不声明后台能力。

```bash
python3 -B rust/verify.py
bash rust/install.sh /path/to/isolated-project debug
cargo run --locked --manifest-path rust/Cargo.toml -p factory_cli -- simulate conveyor_continuous_v1 300
```

本机试玩首次安装可在仓库根目录运行 `bash rust/install.sh "$PWD" debug`，
然后重新打开 Godot，在 Godot 编辑器里按 F5（运行项目），选择“新后端试玩”。
已有安装时安装器拒绝覆盖；使用独立项目构建验证，避免热替换正在加载的库。
试玩默认连续运输，Esc 暂停面板可确认切换规则并重新创建示例世界。
选择平带（5）后，依次右键起点／终点建造整条线路；R 切换折线轴顺序，
C 锁定当前前缀（可多次），左键取消。线路自动匹配地形并生成上下坡，
无法通过时整条标红、保留草稿。其他工具保持单格建拆与朝向旋转，
支持第一人称与自由视角。
工具栏、物品栏与暂停菜单沿用原 UI；I 打开／关闭物品栏，Esc 先关闭物品栏，
再次按下暂停。物品栏打开时物流继续、草稿隐藏并保留；
暂停、失焦、切换视角或工具时取消草稿。暂停时物流停止；
保存、载入、命名／覆盖确认、删除和保存并退出沿用现有菜单。
暂停菜单可修改世界显示名称、自动保存分钟数（0 关闭）和保留份数，
设置随存档保存。主菜单“新后端存档”直接打开新目录的列表；
原后端存档仍从原“继续／载入游戏”入口进入。
格式、目录事务和本切片边界见
[同步试玩存读档规格](features/alpha-2.0/002-backend-protocol-and-persistence.md#同步试玩存读档切片2026-11-26当前规则)。
加载／保存退出期间保持暂停，退出只有持久提交成功后才返回主菜单；
读档失败保留原世界，Esc 可取消尚未提交的读档。异步手动保存允许恢复游戏，
自动保存只在游戏运行时计时。
范围与人工验收门槛见 [M05](features/alpha-2.0/003-migration-plan.md#m05godot-同步小工厂链路m依赖-m03m04)。

验证在独立临时项目安装并启动真实扩展，日志保留在工具输出的目录；
包括无库的明确错误、两个实例生命周期、安装来源、许可文件与源码归档核对。
同步桥接与小工厂场景验收同时验证两套规则的收货、库存账目、批量观测、
完整线路的折线／锁定／地形／失败原子性、单格建拆、朝向、
Rust 射线、暂停和视角切换。
存档集成另验完整玩家／会话恢复、两规则精确续跑、坏档保护、
自动轮换、退出冻结、覆盖确认与失败提示。独立进程离线检查命令为：

```bash
cargo run --locked --manifest-path rust/Cargo.toml -p factory_cli -- validate-save /path/to/checkpoint.pfs
```

可在文件路径后加 0～36000 个 tick 的续跑数量。
此命令只读档案并恢复候选，不修改目录或玩家存档。
原运输扩展已安装时另验两类并存。首次发现原生扩展后先运行正常编辑器生命周期，
再执行导入，兼容当前引擎在过早退出时的故障；任何异常退出仍使验证失败。
入口同时生成当前 Godot 世界、射线与线路几何的独立观测并运行 Rust 对照；
对应 oracle 测试需 `godot_oracle` feature 与新观测路径，默认 workspace 测试不代替这些对照。
射线与世界的损坏观测也必须得到预期拒绝结果。
此限制与当次独立对照见 [M01 审查](reviews/2026-11-25-alpha-2-start.md)。
安装后重新启动编辑器，不能热重载原生库。

已有无个人数据黄金档保存在 `rust/fixtures/legacy/`；以下入口核对原始字节，
并以原 Godot 规则在新进程逐步续跑，后者要求已安装 RustConveyor：

```bash
python3 -B rust/test_legacy_fixtures.py
python3 -B rust/verify.py --legacy
```

重新生成是显式开发操作：`rust/generate_fixtures.py` 要求已有已知来源的原运输库，
只写新的输出，拒绝覆写已存在的黄金档。旧写端只作为兼容 oracle，
不访问玩家存档目录，也不替代新后端的旧档导入验收。

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
