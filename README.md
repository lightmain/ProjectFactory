# ProjectFactory

基于 Godot 4.7.2 的三维体素工厂游戏基础框架，参考本地 `godot-template` 的 AI 脚手架搭建。

初版是一块 16×16 米的平地：32×32 格、地下四层，每格边长 **0.5 米**。
支持第一人称移动、跳跃、破坏和放置方块；世界数据、编辑规则与场景表现独立。
玩家采用与世界轴对齐的长方体碰撞箱，自动走上不超过 **0.25 米（0.5 格）**的台阶。
重力 **9.81 m/s²**，跳跃上升约 **1.5 米**。按 **I** 打开 24 格空物品栏。

## 运行

用 Godot 4.7.2 打开 `project.godot`，按 **F6 运行当前主场景**或 **F5 运行项目**。
也可在根目录执行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --path .
```

| 操作 | 按键 |
| --- | --- |
| 移动 / 视角 | WASD / 鼠标 |
| 跳跃 | 空格 |
| 破坏 / 放置 | 鼠标左键 / 右键 |
| 草地 / 泥土 / 石头 | 1 / 2 / 3 |
| 释放或捕获鼠标 | Esc |
| 打开 / 关闭物品栏 | I |

鼠标释放后点击只恢复操作。交互距离 5 米，沙盒建造工具可无限放置方块，基岩不可破坏；
禁止越界、覆盖方块或放进玩家身体。走出边缘坠落后自动重生。
重新运行会恢复初始平地；保存、机器、物流与无限地图留待后续开发。
物品栏初始没有任何物品，与底部三种建造工具分开；打开时停止主动移动、跳跃、
视角和方块编辑，按 I/Esc 或点击关闭按钮退出。当前数据层支持堆叠、增减、
移动、合并/交换，为后续物品和机器接口准备。游戏不生成自由掉落物。

## AI 与开发脚手架

- Godot AI **4.2.3**：编辑器、场景、脚本、运行与截图工具。
- GdUnit4 **6.2.1**：真实单位测试与场景集成测试。
- `.trae/skills/`：规格、计划、TDD、GDScript 与独立质量审查工作流。
- [AGENTS.md](AGENTS.md)：命名、类型、架构与强制开发流程。
- [Godot AI 配置](docs/setup/godot_ai.md)：在 Godot AI 面板配置 Trae，确认连接当前项目。
- `scripts/verify.sh`、`.githooks/pre-commit`、GitHub Actions：本地与 CI 检查。

## 验证

```bash
GODOT_BIN=/Applications/Godot.app/Contents/MacOS/Godot bash scripts/verify.sh
```

依次检查插件版本、Godot 导入、业务 GDScript 类型安全、全部 GdUnit4 测试、
主场景运行及 Git diff。可从任意目录调用脚本；macOS 可自动找到标准 Godot 安装。
需要 Python 3；日志放在系统临时目录，测试报告在 Godot 用户数据目录，均不纳入版本控制。

## 项目结构

```text
scenes/                主场景与独立玩家场景
scripts/core/          0.5 米格子、世界数据、编辑规则、格子射线
scripts/world/         区块可见面网格、碰撞、网格着色器
scripts/player/        玩家移动和输入
scripts/ui/            HUD 与操作提示
tests/unit/            隔离规则测试
tests/integration/     场景、输入边界与真实物理碰撞测试
docs/                  规格、开发说明、AI 配置、审查与验证记录
addons/                原样复用的 Godot AI 与 GdUnit4
.trae/skills/          项目级 AI Skills
```

开发新功能必须 **先写失败测试 → 实现功能 → 单开 subagent 审查 → 完成验证**。
更多细节见 [开发与版本管理](docs/development.md)、
[基础框架规格](docs/features/001-voxel-foundation.md)。
最新规则见 [玩家与物品栏规格](docs/features/002-player-and-inventory.md)。
