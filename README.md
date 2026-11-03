# ProjectFactory

基于 Godot 的三维体素工厂游戏基础框架，参考本地 `godot-template` 的 AI 脚手架搭建。
当前提供有限平地、第一人称移动与跳跃、方块编辑、空玩家物品栏，
以及矿机、传送带、箱子组成的基础物流。
重新运行会恢复初始世界；存档和无限地图尚未实现。

## 运行

按 [环境要求](docs/development.md#环境要求)安装 Godot，打开 `project.godot`，按 **F5 运行项目**。
连接编辑器 AI 工具见 [Godot AI 配置](docs/setup/godot_ai.md)。

| 操作 | 按键 |
| --- | --- |
| 移动 / 视角 | WASD / 鼠标 |
| 跳跃 | 空格 |
| 破坏 / 放置 | 鼠标左键 / 右键 |
| 草地 / 泥土 / 石头 | 1 / 2 / 3 |
| 矿机 / 传送带 / 箱子 | 4 / 5 / 6 |
| 旋转待放置设施 | R |
| 释放或捕获鼠标 | Esc |
| 打开 / 关闭物品栏 | I |

鼠标释放后点击可恢复操作。物品栏打开时释放鼠标并暂停主动操作，按 I、Esc
或点击关闭按钮退出。六种方块是无限使用的沙盒建造工具，与空玩家物品栏分开。

沿同一方向摆放“矿机 → 传送带 → 箱子”，顶面箭头指向出口，
前方浅绿标记为出口、蓝色标记为入口。扁平传送带还接受左右侧面输入，
可合流或改变运输方向。矿石沿带面连续移动，堵塞时排队停留，
接通后整队同时恢复移动，保持原来的紧密间距；
瞄准设施查看铁矿数量。
矿机配置与物流边界见 [基础物流规格](docs/features/003-basic-logistics.md)；
工厂运算独立于视图，远处不渲染时仍继续生产。

## 项目结构

```text
scenes/                主场景与独立玩家场景
scripts/core/          世界、运动、库存与物流规则、格子射线
scripts/world/         区块网格、碰撞、设施方向与矿石表现
scripts/player/        玩家移动和输入
scripts/ui/            HUD、物品栏视图与操作提示
tests/unit/            隔离规则测试
tests/integration/     场景、输入边界与真实物理碰撞测试
docs/                  规格、开发说明、AI 配置、审查与验证记录
addons/                原样复用的 Godot AI 与 GdUnit4
.trae/skills/          项目级 AI Skills
```

## 开发与规格

- [AGENTS](AGENTS.md)：开发约束、文档职责与维护规则。
- [开发说明](docs/development.md)：环境、完整验证、提交检查与 CI。
- [体素规格](docs/features/001-voxel-foundation.md)：世界尺度、边界、编辑和重生验收。
- [玩家与物品栏规格](docs/features/002-player-and-inventory.md)：碰撞、运动、库存和输入验收。
- [基础物流规格](docs/features/003-basic-logistics.md)：生产、运输、端口、方向和渲染解耦。

历史审查与验证证据保存在 `docs/reviews/`，其中结果仅对应各次记录的验证范围。
