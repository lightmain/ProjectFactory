# 005：游戏配置与统一重力

所属版本：prealpha-1。状态：当前规则。面向调整参数的开发者与场景集成者。
继承 [基础物流](003-basic-logistics.md#行为与边界) 的生产规则和
[玩家运动](002-player-and-inventory.md#验收与范围) 的跳高与碰撞规则。

## 配置来源与生效

- 自定义全局参数保存为 `config/game_config.tres`，类型为
  `scripts/core/game_config.gd` 定义的 `GameConfig` Resource；
  主场景 `FactoryGame.game_config` 引用该资源，在 Inspector 编辑并保存资源即可持久化。
  默认矿石表现距离为 12 米，矿机周期为 1 秒，每周期产量为 1。
- `FactoryGame` 显式将距离传给 `LogisticsView`，将周期和产量传给 `LogisticsData`。
  运行中修改所引用资源的字段会通过 `Resource.changed` 更新这些模块；
  距离在下一次表现刷新生效，矿机参数只影响后续放置，已有矿机保留放置时的快照。
  运行时修改不会自动保存回磁盘。资源仅保存参数，不保存工厂库存或计时。
- 距离以当前活动相机到设施格子中心的三维距离计算，包含边界；
  自由视角切换沿用活动相机。非正或非有限距离关闭这些近距表现；
  设施地形网格和后台物流继续工作。矿机非法参数沿用
  [003 的停产规则](003-basic-logistics.md#行为与边界)。
- 引擎重力的唯一配置来源为 `project.godot` 的
  `physics/3d/default_gravity`（默认 9.81 m/s²）。`FactoryGame` 在启动时读取、
  校验并注入玩家；`PlayerMotionRules` 只接受数值参数，不读取 ProjectSettings。
  跳跃初速度为 `sqrt(2 * gravity * max_jump_height)`，下落积分使用同一重力。
  零重力不产生跳跃初速度；负数或非有限重力按零处理。当前运动方向保持竖直向下。
- 调整重力后重新运行场景生效；在 Project → Project Settings → Physics → 3D
  修改 Default Gravity 并保存即可。不要在 `GameConfig` 中维护另一份重力。
  玩家局部的 `max_jump_height`、移动速度和鼠标灵敏度继续保存在玩家场景。
- 若需要独立实验参数，可复制 `.tres` 并在主场景替换引用后重新运行。
  清空引用时使用一份独立默认配置。共享资源会影响引用它的所有实例；
  测试或运行时临时调参先 `duplicate()`，避免修改其他实例的共享参数。
  本轮不新增设置界面、用户偏好存储、存档或 Autoload。
  **无存档的范围已由 [006](006-session-and-save.md#行为与验收) 扩展；
  存档中的矿机配置随会话恢复，不写回共享 `.tres`。**

## 验收入口

- [物流场景测试](../../../tests/integration/test_logistics_game.gd)：默认资源与持久引用、
  自定义参数、距离包含边界与非法值、实例隔离、空引用，以及已有矿机的配置快照。
- [运动规则测试](../../../tests/unit/test_player_motion_rules.gd)：不同重力下的解析跳高、
  下落与零重力；[玩家物理测试](../../../tests/integration/test_player_movement.gd)：
  非默认项目重力对真实下落生效，60/120 Hz 下仍达到配置跳高。
- [完整验证](../../development.md#本地检查)与
  [独立审查及现场证据](../../reviews/005-game-config.md)。

## 后续配置边界（待实施）

若增加分辨率、音量等个人偏好，使用 `ConfigFile` 保存到 `user://`，
与随项目分发的游戏规则参数分开；具体字段、路径及设置界面尚未定义。
