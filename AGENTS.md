# ProjectFactory 智能体开发规则

适用于整个仓库。开始任务先读本文件、README、相关 `docs/features/` 和已有代码/测试。

## 项目事实

- Godot 4.7.2、Forward Plus、Jolt Physics、typed GDScript。
- 体素边长 0.5 米；有限平地。当前范围与规则见 `docs/features/001-voxel-foundation.md`。
- 玩家为世界轴对齐长方体；0.25 米自动台阶、1.5 米跳跃、9.81 m/s² 重力；
  24 格空物品栏，游戏不做自由掉落物。最新规格见 `docs/features/002-player-and-inventory.md`。
- Godot AI 4.2.3：`addons/godot_ai`；GdUnit4 6.2.1：`addons/gdUnit4`。
- 项目级 Skills 在 `.trae/skills/`。两个 addons 是 vendored 上游代码，常规开发不得修改。
- 文档统一放在 `docs/`，仅 README 与本指南留在根目录。

## 强制开发流程

1. **先查已有实现**：用 `rg` 搜索类、方法、场景、测试和相关文档，优先复用。
2. **明确验收**：功能规格与任务清单写入 `docs/features/`；合理默认可在授权范围内执行。
3. **先测试（RED）**：重要游戏规则或行为先写失败测试，实际运行并确认正确失败原因。
4. **后实现（GREEN）**：实现最小可用功能，运行相关测试；重构后保持测试通过。
5. **场景验证**：每次修改 `.tscn` 后，立即运行导入与项目检查；视觉批次还需运行项目、检查日志和截图。
6. **独立审查**：功能完成后必须单开 subagent，先读测试再审查实现。不得用作者自审代替。
   提供规格、变更范围、测试结果；记录 Critical/Important/Optional，处理阻断项后复验。
7. **记录与交付**：审查和验证写入 `docs/reviews/`；同步 README 与项目事实。
   未执行测试、存在解析/运行错误或没有独立审查时不得宣称功能完成。

使用项目级 TDD、GDScript、质量审查 Skills。用户已明确授权时不要因流程建议重复请求许可。
若 subagent 或实时编辑器不可用，说明缺失环节，不能虚构审查或可视化验证。

## 命名、类型与架构

- 文件、目录、变量、信号、参数和方法用 `snake_case`；节点和类用 `PascalCase`；
  常量用 `UPPER_SNAKE_CASE`，内部状态/内部方法以 `_` 开头。
- 尽可能显式声明变量、参数与返回类型（包括 `-> void`），容器使用 `Array[T]`、
  `Dictionary[K, V]`；在引擎 Variant API 的边界尽快校验并转换，避免扩散动态类型。
- `project.godot` 开启 untyped/inferred declaration 和 unsafe property/method/cast/call 警告。
  不为了过关全局关闭警告；第三方插件警告与业务代码警告分开处理。
- 游戏规则与场景表现分离：`scripts/core/` 不查询节点树、Input 或物理世界。
  通过参数、返回值和信号连接模块；在主场景明确注入依赖，避免隐含路径和全局状态。
- 优先组合、信号、独立场景和 Resource/RefCounted；不擅自增加游戏 Autoload。
  `_mcp_game_helper` 仅用于 Godot AI 调试，不承载游戏规则。
- 物品定义 Resource 为共享只读数据；可变槽位数量由 InventoryData 独立持有，
  用信号刷新界面，不从 UI 直接写槽位状态。游戏不创建自由掉落物节点。
- 运动和碰撞用 `_physics_process`，视觉更新用 `_process`；场景编辑后显式保存。
- 测试验证用户可观察行为，勿镜像实现；纯规则放 `tests/unit/`，
  场景与模块协作放 `tests/integration/`；bug 必须先补复现测试。

```gdscript
func can_build(cell: Vector3i, occupied_bounds: AABB) -> bool:
	var block_bounds: AABB = cell_bounds(cell)
	return is_in_bounds(cell) and not block_bounds.intersects(occupied_bounds)
```

## Godot AI 与验证

1. 获取编辑器状态，确认连接的是当前项目。
2. 读取目标场景/节点，优先用 Godot AI 操作编辑器；直接改文件时触发扫描/导入。
3. 每个场景批次保存、运行项目、检查错误；视觉变化获取截图，验证结束停止游戏。
4. 无实时连接时用无头验证并明确记录限制。

```bash
GODOT_BIN=/Applications/Godot.app/Contents/MacOS/Godot bash scripts/verify.sh
```

该命令检查插件版本、导入、业务脚本警告、GdUnit4、主场景运行。
临时日志和测试报告输出到系统临时目录；不得编辑 `.godot/` 生成文件。

## Git 与安全边界

- 默认分支 `main`；新功能用 `feat/<topic>`，修复用 `fix/<topic>`。
- 提交采用 Conventional Commits，保持小而完整；源码、测试与对应文档一起提交。
- 提交前运行验证与独立审查；按具体文件暂存，不用 `git add .` 掩盖无关变更。
- 仅用户明确要求时创建提交或推送；不 amend、不跳 hooks、不改 git config。
- 本地 hook 和 CI 见 `docs/development.md`；不要提交绝对路径、固定端口或访问令牌。
- 不删除用户变更，不执行 force push、reset --hard、clean -f 等破坏性操作。
