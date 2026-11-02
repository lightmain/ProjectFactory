# 002：轴对齐玩家、运动与空物品栏

维护类型：当前玩家与物品栏规则、验收及模块契约。开发约束见 [AGENTS](../../AGENTS.md)；
体素尺度与世界规则见 [对应规格](001-voxel-foundation.md)。

## 验收与范围

- 玩家碰撞为 0.56×1.75×0.56 米的 BoxShape3D。身体始终与世界 XYZ 轴对齐；
  鼠标只旋转相机，水平移动依据相机 yaw，占用 AABB 与实际碰撞箱保持一致。
- 落地时可直接走上不超过 0.5 米（1 格）的台阶，包括真实体素方块，不需跳跃；
  超过该高度的障碍不得自动攀升，不能在空中攀台阶或穿过低天花板。
  较低台阶只需其实际高度的头部净空，不因最大台阶高度而错误拒绝。
  地形使用整格方块，不提供半砖类型；台阶能力也适用于后续设施的碰撞形状。
- 标准重力 9.81 m/s²，玩家导出变量 `max_jump_height` 以米为单位，默认 1.6 米，
  可在 Inspector 调整并随玩家场景保存；跳跃初速度为 `sqrt(2 * 9.81 * max_jump_height)`。
  使用解析位移积分，60/120 Hz 下实际跳高与配置值误差不超过 0.01 米，
  场景碰撞恢复允许 0.001 米上限容差；非正高度不产生向上的跳跃速度。
- 物品栏为 24 格，初始为空，I 打开/关闭，Esc 或关闭按钮关闭；打开时释放鼠标，
  停止玩家主动移动、视角、跳跃和方块编辑；重力继续作用。
- 点击槽位可选中并查看空槽说明；界面随数据变化刷新，容器保存堆叠数量、
  支持增减、移动、合并/交换，非法输入不得改变数据。
- 使用空格激活面板按钮后屏蔽残留跳跃输入；模态关闭后跨过两次物理帧，
  且按键与 just_pressed 状态都释放才重新允许跳跃。面板期间失焦取消旧捕获恢复。
- 玩家库存当前没有初始物品、拾取或自由掉落物。破坏方块不创建掉落节点。
  草地/泥土/石头和 [物流设施](003-basic-logistics.md) 是独立的沙盒建造工具，
  不表示玩家拥有这些物品；工厂铁矿由独立工厂规则保存，不写入玩家库存。
- 不增加存档或第三方物品栏插件；通用 Autoload 约束见 AGENTS。

## 架构与资料

根据 Godot 官方 API，采用 Resource 物品定义、RefCounted 容器/堆叠数据、
信号驱动 Control 视图、GridContainer 布局。该组合是当前项目的实现选择，
不将某教程的单例或插件宣称为普遍“最佳方案”。

- [Resource](https://docs.godotengine.org/en/stable/classes/class_resource.html)：
  可序列化并在 Inspector 编辑的数据定义，资源可共享；只读定义与可变数量分离。
- [GridContainer](https://docs.godotengine.org/en/stable/classes/class_gridcontainer.html)：
  自动排列 Control 子节点，columns 控制列数。
- [Control](https://docs.godotengine.org/en/stable/classes/class_control.html)：
  GUI 输入、焦点、mouse_filter；UI 输入不泄漏到世界编辑。
- [CharacterBody3D](https://docs.godotengine.org/en/stable/classes/class_characterbody3d.html)：
  test_move 检测假设位置的碰撞，move_and_slide 执行运动与落地。

核心文件：
`scripts/core/player_motion_rules.gd`、`item_definition.gd`、`item_stack.gd`、`inventory_data.gd`。
玩家负责物理检测；物品定义 Resource 为共享只读数据，可变槽位数量由 InventoryData 持有。
`InventoryView` 只读取槽位快照并发出关闭请求，不直接写槽位状态；
`FactoryGame` 显式注入数据与协调输入。
合并要求使用同一 ItemDefinition 资源，未来物品注册表保证每种物品有唯一共享定义。

## 验收入口

- [运动规则测试](../../tests/unit/test_player_motion_rules.gd)与
  [玩家物理测试](../../tests/integration/test_player_movement.gd)：轴对齐、重力、跳高和台阶限制。
- [库存数据测试](../../tests/unit/test_inventory_data.gd)：容量、快照、堆叠、移动和非法操作。
- [界面集成测试](../../tests/integration/test_inventory_view.gd)：开关、输入隔离、失焦和数据刷新。
- [验证命令](../development.md#本地检查)与 [初次审查记录](../reviews/002-player-and-inventory.md)。
