# ProjectFactory

当前开发阶段：**prealpha-1**。`prealpha-2` 目前仅为预先创建的空文件夹，尚未开始该阶段。

基于 Godot 的三维体素工厂游戏基础框架，参考本地 `godot-template` 的 AI 脚手架搭建。
当前提供有限平地、第一人称移动与跳跃、自由建造视角、方块编辑、空玩家物品栏，
以及矿机、传送带、箱子组成的基础物流、主菜单、暂停与区块存读档。
功能范围与未实现边界见下方 [版本规格入口](#版本规格入口)。

## 运行

按 [环境要求](docs/development.md#环境要求)安装 Godot，打开 `project.godot`，按 **F5 运行项目**。
连接编辑器 AI 工具见 [Godot AI 配置](docs/setup/godot_ai.md)。

启动后选择 **新游戏**并输入世界名称、**继续**最新存档，或**载入游戏**选择存档。
Esc 菜单提供继续、载入、命名保存与保存并退出到主菜单。
存档列表支持选择、双击载入与确认删除；覆盖同名档须确认。
自动存档参数与详细规则见 [多存档与简洁菜单](docs/features/prealpha-1/007-multiple-saves.md)。

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
| 旋转待放置设施 | R |
| 传送带起点 / 终点 | 依次右键两处 |
| 锁定此前全部传送带路径 / 取消线路 | C（可多次）/ 左键 |
| 暂停 / 继续 | Esc |
| 打开 / 关闭物品栏 | I |

暂停时整个游戏停止，鼠标可操作菜单；库存打开时第一次 Esc 仅关闭库存。
第一人称失焦释放鼠标后点击可恢复操作。自由视角默认解锁鼠标，可在光标位置建造；
每次进入自由视角时北向上、东向右。
镜头有实体碰撞和玩家距离限制，切换取消未提交的传送带线路。
设施朝向保持世界坐标下的一致方向，只有 R 改变所选朝向，换工具也会保留。
具体规则见 [自由视角与世界建造朝向](docs/features/prealpha-1/004-free-camera.md#行为与边界)。
物品栏打开时释放鼠标并暂停主动操作，按 I、Esc
或点击关闭按钮退出。六种方块是无限使用的沙盒建造工具，与空玩家物品栏分开。
设施建造、路线预览、锁定标记与失败处理见
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

- [体素规格](docs/features/prealpha-1/001-voxel-foundation.md)：世界尺度、边界、编辑和重生验收。
- [玩家与物品栏规格](docs/features/prealpha-1/002-player-and-inventory.md)：碰撞、运动、库存和输入验收。
- [基础物流规格](docs/features/prealpha-1/003-basic-logistics.md)：生产、运输、端口、方向和渲染解耦。
- [自由视角与世界建造朝向](docs/features/prealpha-1/004-free-camera.md)：模式切换、镜头碰撞、距离与输入验收。
- [游戏配置与统一重力](docs/features/prealpha-1/005-game-config.md)：参数来源、显式注入与生效边界。
- [主菜单、暂停与区块存档](docs/features/prealpha-1/006-session-and-save.md)：世界范围、
  会话生命周期、数据区块与本地存读档。
- [多存档与简洁菜单](docs/features/prealpha-1/007-multiple-saves.md)：
  世界身份、命名存档、自动轮换和黑白灰菜单。

历史审查与验证证据保存在 `docs/reviews/`，其中结果仅对应各次记录的验证范围。
