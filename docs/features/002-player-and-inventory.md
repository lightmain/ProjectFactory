# 002：轴对齐玩家、运动与空物品栏

## 验收与范围

- 玩家碰撞改为 0.56×1.75×0.56 米的 BoxShape3D。身体始终与世界 XYZ 轴对齐；
  鼠标只旋转相机，水平移动依据相机 yaw，占用 AABB 与实际碰撞箱保持一致。
- “0.5 格”解释为 0.25 米（每格 0.5 米）：落地时可自动上不超过 0.25 米的台阶，
  不需跳跃；不能自动上 0.5 米方块，不能在空中攀台阶或穿过低天花板。
  地形仍使用整格方块，本次不增加半砖类型；台阶能力也适用于后续设施的碰撞形状。
- 标准重力 9.81 m/s²，跳跃初速度 `sqrt(2 * 9.81 * 1.5)`；
  使用解析位移积分，正常平地最大上升不超过 1.5 米，60/120 Hz 误差不超过 0.01 米。
- 增加 24 格空物品栏，I 打开/关闭，Esc 或关闭按钮关闭；打开时释放鼠标，
  停止玩家主动移动、视角、跳跃和方块编辑；重力继续作用。
- 点击槽位可选中并查看空槽说明；界面随数据变化刷新，容器保存堆叠数量、
  支持增减、移动、合并/交换，非法输入不得改变数据。
- 使用空格激活面板按钮后屏蔽残留跳跃输入；模态关闭后跨过两次物理帧，
  且按键与 just_pressed 状态都释放才重新允许跳跃。面板期间失焦取消旧捕获恢复。
- 当前没有实际物品定义、初始物品、拾取或自由掉落物。破坏方块不创建掉落节点。
  现有草地/泥土/石头是独立的沙盒建造工具，不表示玩家拥有这些物品。
- 不增加游戏 Autoload、存档或第三方物品栏插件。

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
玩家负责物理检测，规则层不查询节点树/输入/物理。
`InventoryView` 只读取槽位快照并发出关闭请求；`FactoryGame` 显式注入数据与协调输入。
合并要求使用同一 ItemDefinition 资源，未来物品注册表保证每种物品有唯一共享定义。

## 实施任务

1. [x] 先写运动规则与物品栏单位测试，运行确认 RED；实现并确认 GREEN。
2. [x] 先写碰撞轴对齐、跳跃高度、台阶/高墙/头部/空中限制的场景测试。
3. [x] 修改玩家场景后立即导入、检查、运行；确认运动集成测试通过。
4. [x] 先写空物品栏、I/Esc/按钮、输入隔离与 UI 同步集成测试。
5. [x] 实现物品栏和装配，修改主场景后立即导入、检查、运行与截图。
6. [x] 单开 subagent 先审测试再审代码；修复阻断项后复验。
7. [x] 同步 README/AGENTS 和 `docs/reviews/002-player-and-inventory.md`。

验证命令：`bash scripts/verify.sh`。测试报告与临时日志保持在仓库外。
