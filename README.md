# ProjectFactory

当前开发阶段：**prealpha-2 开发中**。**prealpha-1 功能范围已封版**。
各项优化的实施状态见下方版本规格入口。

基于 Godot 的三维体素工厂游戏基础框架，参考本地 `godot-template` 的 AI 脚手架搭建。
当前提供有限平地、第一人称移动与跳跃、自由建造视角、方块编辑、空玩家物品栏，
以及矿机、传送带、箱子组成的基础物流、主菜单、暂停与区块存读档。
功能范围与未实现边界见下方 [版本规格入口](#版本规格入口)。

## 运行

按 [环境要求](docs/development.md#环境要求)安装 Godot，打开 `project.godot`，按 **F5 运行项目**。
连接编辑器 AI 工具见 [Godot AI 配置](docs/setup/godot_ai.md)。

启动后选择 **新游戏**并输入世界名称、**继续**最新存档，或**载入游戏**选择存档。
**新后端试玩**进入由后台线程推进的独立小工厂，已接入移动、建拆、查询与动态物流；
构建与本轮验收范围见
[Rust 后端试玩](docs/development.md#alpha-20-rust-workspace)。
**新后端存档**打开 Rust 世界的独立存档列表。
原后端的 Esc 菜单提供继续、载入、命名保存与保存并退出到主菜单；
试玩菜单的可用操作见上述开发说明。
存档列表支持选择、双击载入与确认删除；覆盖同名档须确认。
自动存档参数与详细规则见 [多存档与简洁菜单](docs/features/prealpha-1/007-multiple-saves.md)；
Rust 试玩的存档及暂停菜单设置见
[同步存读档切片](docs/features/alpha-2.0/002-backend-protocol-and-persistence.md#同步试玩存读档切片2026-11-26当前规则)。

| 操作 | 按键 |
| --- | --- |
| 移动 / 视角 | WASD / 鼠标 |
| 跳跃 | 空格 |
| 第一人称 / 自由视角 | Tab |
| 自由镜头水平移动 | WASD |
| 自由镜头拉近 / 拉远 | 滚轮向上 / 向下，以视野中心最近方块表面为锚点 |
| 自由镜头绕锚点旋转 | 按住鼠标中键并移动 |
| 破坏 / 放置 | 鼠标左键 / 右键 |
| 草地 / 泥土 / 石头 | 1 / 2 / 3 |
| 矿机 / 传送带 / 箱子 | 4 / 5 / 6 |
| 3×3×3 测试结构 | 7 |
| 45° 上坡 / 下坡传送带 | 8 / 9 |
| 旋转待放置设施 / 激活线路切换轴顺序 | R |
| 传送带起点 / 终点 | 依次右键两处 |
| 锁定此前全部传送带路径 / 取消线路 | C（可多次）/ 左键 |
| 暂停 / 继续 | Esc |
| 打开 / 关闭物品栏 | I |

暂停时整个游戏停止，鼠标可操作菜单；库存打开时第一次 Esc 仅关闭库存。
第一人称失焦释放鼠标后点击可恢复操作。自由视角默认解锁鼠标，可在光标位置建造；
每次进入自由视角时北向上、东向右。
镜头有实体碰撞和玩家距离限制，切换取消未提交的传送带线路。
设施朝向保持世界坐标下的一致方向，R 旋转所选朝向，换工具也会保留；
传送带线路激活时 R 改为切换“先南北后东西 / 先东西后南北”，不旋转设施。
具体规则见 [自由视角与世界建造朝向](docs/features/prealpha-1/004-free-camera.md#行为与边界)。
物品栏打开时释放鼠标并暂停主动操作，按 I、Esc
或点击关闭按钮退出。九种工具均可无限建造，与空玩家物品栏分开。
多方块结构按底面中心吸附网格，R 旋转，挖掘任意格拆除整座；详见
[多方块规格](docs/features/prealpha-1/008-multiblock-structures.md)。
斜坡传送带每次放置一段，只能直行升降；它是独立单格设施，详见
[斜坡规格](docs/features/prealpha-1/009-sloped-belts.md)。
传送带线路按固定直角自动贴地、跨越建筑并生成坡道，坡道不足时整条标红；
操作与验收见 [直角线路](docs/features/prealpha-1/010-orthogonal-belt-routes.md)。
其他设施预览、锁定标记与失败处理见
[建造预览与路径操作](docs/features/prealpha-1/003-basic-logistics.md#建造预览与路径操作)。

沿同一方向摆放“矿机 → 传送带 → 箱子”，顶面箭头指向出口；瞄准设施查看铁矿数量。
生产、端口连接、矿石运输及堵塞规则见
[基础物流规格](docs/features/prealpha-1/003-basic-logistics.md#行为与边界)。

## 项目结构

```text
scenes/                会话入口、游戏与独立玩家场景
config/                Inspector 可编辑的游戏参数 Resource
scripts/core/          世界、运动、库存与物流规则、格子射线
scripts/world/         区块网格、碰撞、设施方向与矿石表现
scripts/player/        玩家移动和输入
scripts/ui/            主菜单、暂停、HUD、物品栏与操作提示
tests/unit/            隔离规则测试
tests/integration/     场景、输入边界与真实物理碰撞测试
prototypes/rust_world/ 独立 Rust 静态世界性能实验，命令与范围见版本规格
rust/                  alpha-2.0 数据后端 workspace，实施状态见版本规格
docs/features/         按游戏版本组织的功能规格
docs/                  开发说明、AI 配置与历史审查证据
addons/                原样复用的 Godot AI 与 GdUnit4
.trae/skills/          项目级 AI Skills
```

## 开发

- [AGENTS](AGENTS.md)：AI 新对话阅读顺序、开发约束与文档维护规则。
- [开发说明](docs/development.md)：环境、完整验证、提交检查与 CI。
- [游戏参数配置](docs/features/prealpha-1/005-game-config.md#配置来源与生效)：资源编辑、
  重力设置与参数生效时机。

## 版本规格入口

版本组织、规格状态与跨版本继承规则统一见
[AGENTS](AGENTS.md#版本规格与状态)。各规格维护功能范围、当前规则和待实施内容；
本入口只提供链接，实际实现与验证状态按 [开发说明](docs/development.md#当前状态与文档检查) 查询。

### prealpha-1

2026-11-08 冻结功能范围：此前全部功能归入下列 001～011 规格，
包括大世界存档、内容物编辑与压力测试工具。既有条款的继承／替代关系保持有效；
旧 HTML 草案按 007 的标识保留为历史材料。后续新增或变化的功能进入 prealpha-2。
本次完成范围封版；封版不表示已消除全部已知问题，
Git 与发布状态按开发说明查询。
百万带手工运行中的数组越界未复现，按用户决定跳过本次排查并继续开发，记录见
[prealpha-2 首项计划](docs/features/prealpha-2/001-logistics-performance.md#数组越界排查)；
当前性能限制与当次验证范围见 [压力存档审查](docs/reviews/011-pressure-save.md)。

- [体素规格](docs/features/prealpha-1/001-voxel-foundation.md)：世界尺度、边界、编辑和重生验收。
- [玩家与物品栏规格](docs/features/prealpha-1/002-player-and-inventory.md)：碰撞、运动、库存和输入验收。
- [基础物流规格](docs/features/prealpha-1/003-basic-logistics.md)：生产、运输、端口、方向和渲染解耦。
- [自由视角与世界建造朝向](docs/features/prealpha-1/004-free-camera.md)：模式切换、镜头碰撞、距离与输入验收。
- [游戏配置与统一重力](docs/features/prealpha-1/005-game-config.md)：参数来源、显式注入与生效边界。
- [主菜单、暂停与区块存档](docs/features/prealpha-1/006-session-and-save.md)：世界范围、
  会话生命周期、数据区块与本地存读档。
- [多存档与简洁菜单](docs/features/prealpha-1/007-multiple-saves.md)：
  世界身份、命名存档、自动轮换和黑白灰菜单。
- [多方块测试结构](docs/features/prealpha-1/008-multiblock-structures.md)：
  整座预览、底面中心吸附、旋转、整体挖掘与实例存档。
- [45° 斜坡传送带](docs/features/prealpha-1/009-sloped-belts.md)：
  独立单格的上坡／下坡、直行端口与升降运输。
- [直角贴地传送带线路](docs/features/prealpha-1/010-orthogonal-belt-routes.md)：
  固定直角投影、R 切换轴顺序与贪心坡道规划。
- [大世界存档与压力测试](docs/features/prealpha-1/011-pressure-save.md)：
  可变边界、紧凑存档、内容物编辑与压力档生成／测量工具。

### prealpha-2

- [首项更新：物流性能优化与开发计划](docs/features/prealpha-2/001-logistics-performance.md)：
  数组越界排查、回归基线、接口解耦、连续运输线路、可见范围采样、
  装饰批量绘制和读档去重；实施进展及待实施范围见规格。
- [RustConveyor 接入与百万传送带验证](docs/features/prealpha-2/002-rust-conveyor-integration.md)：
  首版独立运输包接入、真实坡道长度、Godot 批量接口、设施表面标记和百万压力测量；
  当前规则与后续边界见规格，实测证据见
  [接入验收](docs/reviews/2026-11-23-rust-conveyor-host.md)。
- [保存不再重建工厂](docs/features/prealpha-2/003-save-without-reconstruction.md)：
  保存与加载的校验边界调整；实施状态与验收见规格。
- [纯 Rust 百万方块最小原型](docs/features/prealpha-2/004-rust-world-prototype.md)：
  独立实验，验证静态世界存读档、局部编辑和范围数据更新；实施状态与验收见规格。

### alpha-2.0

**分阶段实施中的整体重构**，当前开发阶段尚未切换；
各规格按分节标明当前切片与待实施范围，替代关系仅在已验证的条款旁标注。

- [完整 Rust 数据后端重构](docs/features/alpha-2.0/001-rust-backend-refactor.md)：
  世界、工厂、数据查询与表现数据的职责划分、线程、规则兼容及候选性能预算。
- [后端通信与完整存档协议](docs/features/alpha-2.0/002-backend-protocol-and-persistence.md)：
  局部批量表现、受控等待、时钟、格式 5、原子保存、加载交接与旧档导入。
- [分阶段迁移、验收与新对话交接](docs/features/alpha-2.0/003-migration-plan.md)：
  从当前基线到默认切换的任务、依赖、验证与新对话启动材料。

历史审查与验证证据保存在 `docs/reviews/`，其中结果仅对应各次记录的验证范围。
