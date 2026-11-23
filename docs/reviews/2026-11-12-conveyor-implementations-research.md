# 成熟工厂游戏的传送带实现调研

日期：2026-11-12。面向 ProjectFactory 的物流实现者与审查人员。
这是带来源的技术调研，建议均未实施，不替代现行功能规格，也不代表新的性能验收通过。
本次只读取外部源码、官方介绍与本地实现，不修改游戏代码或运行其他游戏的性能基准。

## 主要发现

Mindustry、原版 shapez 和 Factorio 提供了两条成熟路线：Mindustry 普通带继续逐格运行，
用固定小数组、直接下游引用和空带休眠控制成本；shapez 与 Factorio 将连续带组合为运输路径，
用物品间距表示运动，避免每 tick 修改所有物品位置。成熟项目没有统一采用同一种算法。
[[cite:2]](#source-2)[[cite:3]](#source-3)[[cite:6]](#source-6)[[cite:7]](#source-7)[[cite:10]](#source-10)

对 ProjectFactory 当前编辑停顿最有价值的经验，是**让已有运输路径长期存活，针对编辑点拆分、
延长、合并或更新边界，区分必须立即完成的正确性工作和可以延后的组织工作**。
shapez 有实际的路径编辑实现；Factorio 官方明确说明运行组合并必须立即完成，但运行组拆分可以延后。
这不等于编辑没有线性成本：shapez 仍扫描、复制受影响路径的内容。
[[cite:6]](#source-6)[[cite:7]](#source-7)[[cite:11]](#source-11)

本项目已局部更新格子邻接，也已合并纯带段。尚存的结构性差距位于更上层：
编辑使受影响连通区的压缩状态失效；随后重新发现连通区、建立区域数据、逐格结算并重新合段。
减少重复展开的上一批优化已经有效，但保留下来的一次全区转换仍会随区域规模增长。
这里应优先验证“能否保留未改变的段”，而不是根据语言外观猜测重写收益。
[[cite:16]](#source-16)

## 样本、版本与证据边界

“成熟”在本报告中表示已有公开发行、持续使用的完整游戏，不表示任意规模都能实时运行。
shapez 的商店页确认其正式发行日期为 2020-06-07，仓库提供原版游戏源码与发布记录；
因此它是 Mindustry 之外可用的开源工厂样本。此处研究的是原版 shapez，不把结论延伸到 shapez 2。
[[cite:1]](#source-1)[[cite:5]](#source-5)

| 样本 | 核验范围 | 为什么采用 | 不能据此证明什么 |
| --- | --- | --- | --- |
| Mindustry | v160.7，提交 `17012d61d9e4c3cbd9820d87e81c24495486ac53`；普通 Conveyor、BuildingComp，补看 StackConveyor | Java、GPL-3.0；自动化与塔防结合，现成运行源码 | 未覆盖所有运输器械、Duct、桥或全部引擎成本；未测百万带性能 |
| 原版 shapez | 1.5.1，提交 `4e5e5c8ef7eefa674fc9c4191b1a9b800ae262ee`；BeltSystem、BeltPath、BeltComponent、物品解析器 | JavaScript、GPL-3.0；已发行的工厂游戏，路径编辑源码直接对应研究问题 | 不是当前 Steam 构建逐字审计；不是 shapez 2 的实现或性能 |
| Factorio | 官方 FFF-148、176、364、405、421；2025 年开发者论坛说明；访问当日 Lua API 页面 | 闭源，但开发者连续公开了表示、堵塞、编辑、确定性与读取成本 | 未读取私有源码；旧文章的调参值和性能数字不能当作今天的精确实现参数 |
| Satisfactory | 只作补充检索，读取社区 Modding 的 Factory Tick 文档 | 可了解远处工厂仍模拟、线程与表现分离的约束 | 此次没有取得足够的官方传送带内部算法证据，不作为核心方案依据 |

前三行的项目资格与机制分别由下文固定源码、发布信息和官方文章支持。
Satisfactory 资料是专业社区文档，不是 Coffee Stain 官方源码或官方架构说明。
[[cite:1]](#source-1)[[cite:5]](#source-5)[[cite:10]](#source-10)[[cite:11]](#source-11)[[cite:15]](#source-15)

证据分为三种：固定版本源码可以直接确认该版本执行机制；官方文章可以确认作者当时公开的设计；
迁移建议属于分析，需要本项目实验。单个游戏的内部机制仍是 `[SINGLE-SOURCE]`，同仓库多个文件
不算独立来源。跨游戏共同支持的结论是“减少重复工作、保持已有表示、显式管理交互边界”；
不能声称三个独立来源证明了任一游戏内部的全部实现。

## Mindustry：逐格小数组、直接引用与空带休眠

### 运行状态与持续运输

普通 `Conveyor` 的容量常量为 3。每格 `ConveyorBuild` 保存 `Item[] ids`、`float[] xs`、
`float[] ys` 与有效长度 `len`，另缓存 `next`、`nextc` 和是否同向的 `aligned`。
`ids` 名字容易误导：元素是物品种类 `Item`，不是每件矿石的唯一实例 ID。
这比每件物品建立独立运动对象更紧凑，但仍有每格 Building、数组和通用库存模块等开销，
不能把它描述成整张地图只有三个连续数组。
[[cite:2]](#source-2)

`updateTile()` 从出口方向倒序处理本格物品。每件物品只受前一件物品的位置约束；
同向下游通过缓存的 `nextc.minitem` 约束跨格空间。到达出口后直接调用下游
`acceptItem()` 与 `handleItem()`，不为一次运输重新构造全线路拓扑，也不调用全图位置求解器。
因此普通活动带的运输工作仍随活动格和物品数量增长，但每格最多三件，单格工作有小的上界。
[[cite:2]](#source-2)

这说明“成熟游戏也可能逐格更新”，但不说明当前 ProjectFactory 的旧逐格路径已经等价于它。
逐格固定数组与直接下游交接，和每批维护求解工作区、资格、原子交接及公平轮询，是不同的工作量。
两者没有同条件基准，不能从 Java 与 GDScript 的差别推导一个速度倍数。
[[cite:2]](#source-2)[[cite:16]](#source-16)

### 堵塞与唤醒

空带且 `timeScale` 约等于 1 时，`updateTile()` 调用 `sleep()` 并返回。
`BuildingComp.sleep()` 累积空闲时间，达到阈值后 `remove()`；
`noSleep()` 则清零计时，必要时 `add()` 重新激活。
接收物品、删除物品和部分单位交互会调用 `noSleep()`。
这不是每 tick 仍扫描所有空带、再在函数开头返回的同一种成本。
[[cite:2]](#source-2)[[cite:3]](#source-3)

**满载堵塞的普通带不走上述空带休眠分支。** 它仍检查有限数量的物品，尝试出口交接，
更新 `clogHeat`，并在结尾调用 `noSleep()`。`clogHeat` 控制动画和声音等表现，
不能把停止动画当作停止模拟的证据。本次源码不支持“Mindustry 将所有堵塞带转为事件唤醒”的说法。
[[cite:2]](#source-2)

### 编辑与存档

普通带的 `onProximityUpdate()` 重新计算表现连接并缓存 `front()`。
`BuildingComp.updateProximity()` 与 `removeFromProximity()` 遍历建筑边缘附近的建筑，
通知这些邻居更新。普通传送带不维护必须先展开、再重建的长运输路径，
因此这部分编辑维护范围是附近建筑，而不是整条连通带。
此结论只覆盖普通带邻接；不能泛化到电力、其他物流器械或所有游戏编辑成本。
[[cite:2]](#source-2)[[cite:3]](#source-3)

普通带存档按本格写物品种类与位置，`xs`、`ys` 编码为字节，并在读取时还原。
这是一种量化持久化方式，不是本项目要求的完整浮点状态连续性。
可以借鉴紧凑编码与运行数据分离，不能直接复用其精度和逐件身份语义。
[[cite:2]](#source-2)[[cite:16]](#source-16)

### 另一种带：StackConveyor

`StackConveyor` 的默认容量为 10，区分装载、运输、卸载状态。
运输状态在冷却完成且下游为空时，将 `items` 中的整批内容添加到下游并清空上游；
表现通过来源 `link` 与 `cooldown` 插值。这是在独立器械规则下把多件物品作为一批运输，
不是普通 Conveyor 已经合并整条长带的证据。
[[cite:4]](#source-4)

对本项目，普通带的固定小数组和邻居引用可作为数据组织参照；
整批货物运输则会改变当前逐件、容量两颗与交接规则，不属于保持玩法的直接优化。
[[cite:4]](#source-4)[[cite:16]](#source-16)

## 原版 shapez：路径间距队列与已有路径编辑

### 运行与堵塞表示

`BeltSystem` 持有 `beltPaths`，每 tick 调用每条路径的 `update()`；
单格 BeltComponent 通过 `assignedPath` 指向所属路径。
`BeltPath.items` 保存 `[distanceToNext, item]`，另存 `spacingToFirstItem`。
物品运动通过减少出口或内部剩余间距、增加入口空距表达，不需要沿途每格逐件改坐标。
`typeItemSingleton` 的解析器按颜色、形状等解析共享物品值，
没有为每一件运输副本保存 ProjectFactory 式稳定实例 ID。
[[cite:6]](#source-6)[[cite:7]](#source-7)[[cite:8]](#source-8)

出口堵塞后，`update()` 消耗仍可缩短的间距；已经紧贴的出口队列使用
`numCompressedItemsAfterFirstItem` 跳过。解除堵塞时有额外的后继物品进度修正，
避免跳过压紧队列造成运力损失。空路径直接返回，但 `BeltSystem.update()` 仍遍历路径列表；
源码不能证明所有空路径都已从活动列表移除。
[[cite:6]](#source-6)[[cite:7]](#source-7)

优势来自平移不改变内部间距、压紧部分无需重复处理，既适用于相等间距，也适用于不同间距的自由流。
它不是每 tick 无条件只改两个数：交接、间距压缩与缓存失效仍有成本；
`tryAcceptItem()` 使用 `unshift()`，也不是保证常数成本的环形队列。
[[cite:7]](#source-7)

### 编辑维护：复用路径，但仍有扫描和复制

新增带首先找供给带和后继带，选择延长上游路径、向下游路径前面添加，或新建路径；
连接两条已有路径时调用 `extendByPath()` 合并。拆除时区分路径开头、末尾和中间；
中间删除调用 `deleteEntityOnPathSplitIntoTwo()`。周边更新只找建筑范围外扩一格的邻居，
收集改变的路径，再统一通知，减少重复通知。
[[cite:6]](#source-6)

这与每次编辑重新发现整个器械连通图有明显区别：单格和路径都有长期身份，
正常编辑直接操作它们。箱子等非带建筑改变时，邻近路径还可以只重新绑定接收端，
不必为了端口变化重建路径内部物品表示。
但 `onPathChanged()` 会重置压紧缓存，因此某些后续更新可能重新承担识别压紧区的成本。
[[cite:6]](#source-6)[[cite:7]](#source-7)

需要保留三个反证，避免把成熟实现理想化：

- `extendOnEnd()` 虽然只改末端空距和路径长度，仍调用 `computeBounds()` 扫描路径格子。
- 中间拆除要寻找分割点、扫描物品并迁移后半段，还在循环中使用 `splice()`；
  不能保证拆分总耗时是常数，也不应未经测量就把它标为严格线性。
- 两路径合并要逐格修改后半路径的 `assignedPath`，逐件复制队列项并重算包围盒。

以上均可在固定源码中确认。正确借鉴是“只维护受影响的路径并保留无关路径”，
不是“照抄 shapez 的数组操作即可解决十万格长带编辑”。
[[cite:7]](#source-7)

### 几何、绘制与存档

直带有效长度为 1，曲带为 0.78，位置按路径长度映射回格子与弧线。
这与 ProjectFactory 转弯、斜坡沿用规定单格运输时间的契约不同。
长路径的逻辑坐标可以独立于几何坐标，但其长度与交接规则必须按本项目定义。
[[cite:8]](#source-8)[[cite:16]](#source-16)

路径序列化直接保存 `entityPath`、间距队列和入口空距，读取后重建派生数据；
恢复后的路径列表为空时走全路径重算，包括旧档或空工厂。该设计说明压缩表示可以直接进入存档，
不必以逐格状态作为唯一持久化表达；本项目仍需保留非法恢复校验和旧格式兼容。
[[cite:6]](#source-6)[[cite:7]](#source-7)[[cite:16]](#source-16)

绘制先判断路径包围盒与可见矩形是否相交，然后仍从路径起点遍历格子和物品并做可见性筛选。
`containsRect()` 在该项目中的含义是相交测试，已核对 Rectangle 实现。
路径逻辑高效不等于局部可见采样高效；不要为了采用路径队列，把 ProjectFactory 的范围查询
改回先遍历一整条很长的路径。绘制还会将同种、连续排列的物品组合绘制，
这是表现批量化，与运输求解分别评估。
[[cite:7]](#source-7)[[cite:8]](#source-8)

## Factorio：间距、压紧游标、运行组与确定性

### 运输线与堵塞压缩

FFF-148 在 2016 年提出将连续带合并为段，将物品放在连续内存里，并用共同偏移推进。
该文同时列出编辑拆并、保存恢复、绘制和分流器执行顺序等未解决问题；
它是计划，不能独自证明后来实际完成了哪些优化。
[[cite:9]](#source-9)

FFF-176 在 2017 年公开了更具体的实现：连续带共享物品序列，
保存相邻物品之间的间距以及两端空距。自由流时修改两端空距；
堵塞后修改出口侧最后一个仍可缩短的间距，缓存其索引，跳过已经压紧的区间。
没有中途取放等扰动时，压紧关系保持，游标只沿压紧方向移动。
这给出关于物品沿线路运动的摊销成本，而不是所有操作无条件 `O(1)`。
[[cite:10]](#source-10)

这里的关键优势超过“相邻格运动状态完全相同才合并”：自由流中各件物品之间可以有不同间距，
只要间距不变，就无需每 tick 更新每件物品。ProjectFactory 当前压缩的是重复格状态；
如果各格相位不同，状态段数可能接近格数。是否值得引入更一般的间距表示，取决于这种非重复状态
在真实工厂中是否常见，以及能否严格保留本项目的逐格规则。
[[cite:10]](#source-10)[[cite:16]](#source-16)

### 长度限制与中途交互

间距表示也有代价：某件物品的绝对位置不能直接按数组索引取得，需要累加间距或额外索引。
FFF-176 描述让机械臂持续跟踪关注物品，并对有机械臂、侧入等交互的运输线动态拆并，
把昂贵的取放、绘制和查询限制在较短范围。文中的“可能 9 格”“100 格”明确处于调参阶段；
**本报告不把它们当作 2026 年的固定上限，也不建议本项目直接照搬该数值。**
[[cite:10]](#source-10)

2024 年 FFF-405、421 进一步确认运输线仍是有效抽象：整线读取可以跨地下带，
会被分流和侧入中断；逐格电路读取原本会将运输线切成一格，整线读取则能避免这种碎片化。
当读取器大量使用后，逐 tick 统计所有物品仍成为开销，作者再将适合的只读计算并行化。
访问当日官方 Lua API 也说明，不同所属实体可关联同一个跨多格的内部运输线。
这些证据支持路径抽象延续，不能证明内部仍逐字采用 2017 年的全部参数和代码。
[[cite:12]](#source-12)[[cite:13]](#source-13)[[cite:14]](#source-14)

### 编辑：必须合并的运行组，可延后的组拆分

FFF-364 区分了**运输线**与**运输线运行组**：能互相直接交换物品的线必须放在同一组，
组内按确定顺序执行，不同组可以并行。玩家新增、旋转或删除连接会改变分组。
作者明确指出：合并必须立即完成，否则并行组可能互相写入；拆分可以延后。
[[cite:11]](#source-11)

可延后的是运行组重新划分，不是让被拆掉的传送带继续运输。
旧的大组包含几个已经断开的分量时，仍可以按原顺序一起执行，结果正确但并行度较低；
延后拆分只延后恢复最佳组织方式。对于纯单线程项目，立即合并的理由不完全相同，
但“语义连接立即正确、组织结构允许暂时不最优”的区分仍有参考价值。
[[cite:11]](#source-11)

本项目的 `LogisticsTransportRegion` 接近连通运行组，`BeltSegmentTransport` 中的 Segment
才接近运输线。当前一次编辑将区域内的段一并失效，因此不能只把“区域”改名成“线路”
就认为已经采用了上述做法。候选方案应同时保持正确的新连接和仍可运行的旧段状态。
[[cite:11]](#source-11)[[cite:16]](#source-16)

### 活动边界与有序唤醒

FFF-364 描述空闲机械臂向运输线登记唤醒需求。并行运输线产生请求，
完成后由主线程按组更新顺序合并、执行，以保留确定性。
2025 年 Factorio 开发者 boskid 还明确说明，没有空隙的满带不应反复唤醒侧面交互；
允许机械臂补充已有部分堆叠会破坏这一基础假设，因此拒绝了该玩法提议。
这是“状态无关时不再询问、相关变化时通知”的实际例子。
[[cite:11]](#source-11)[[cite:14]](#source-14)

这能支持矿机、箱子与入口活动集合的设计方向，但不能把“Factorio 满带不唤醒侧面交互”
写成“所有满带运输线自身都退出更新”。这两个命题不同，本次资料没有充分确认后一命题。
本项目还有公平轮询、预留机会、生产相位和同 tick 资格，唤醒顺序必须由这些契约决定，
不能用线程完成顺序、回调偶然顺序或只检查库存数量替代。
[[cite:11]](#source-11)[[cite:14]](#source-14)[[cite:16]](#source-16)

### 公开性能数字的用途

FFF-176 报告物品位置推进部分约 50～100 倍的改善，但当时对传送带整体约 5～10 倍是预期，
整厂例子由 25 UPS 到 35～40 UPS。FFF-364 在部分每分钟 10k 科学包的工厂中报告
传送带更新从 4 ms 到 1.6 ms，整厂改善 20～40%。
它们分别涉及表示变化与后续并行化，硬件、游戏版本、地图及计时范围都与本项目不同。
[[cite:10]](#source-10)[[cite:11]](#source-11)

这些数字只用于说明局部收益不等于整厂收益；没有被作为 ProjectFactory 的预期提速倍数。
FFF-421 还报告过电网并行化因内存吞吐限制未改善整厂速度的失败尝试。
因此“换原生语言”“多线程”“更紧凑的数据”都应先证明实际瓶颈和收益，
不能从其他系统的数字推断本项目会快十倍。
[[cite:13]](#source-13)

## 与 ProjectFactory 当前问题的对应

### 当前编辑实际触发的工作

下表按访问当日工作树读取，指向具体调用；不是重新做的一次计时分解。

| 层次 | 当前实际行为 | 对应源码 |
| --- | --- | --- |
| 格子邻接 | 编辑邻域登记，`rebuild_pending()` 只重连待更新目标；已经局部化 | [LogisticsTopology](../../scripts/core/logistics_topology.gd)，`edit_neighborhood()`、`mark_changed()`、`rebuild_pending()` |
| 区域失效 | 邻域涉及的区域 `invalidate()`；活动纯段整体 `materialize()` | [区域管理](../../scripts/core/logistics_transport_regions.gd)，`before_edit()`；[区域](../../scripts/core/logistics_transport_region.gd)，`invalidate()` |
| 状态展开 | 遍历区域内纯带段与格子，用 `save_row()` 生成逐格内容，新建 LogisticsOre 并清除段表示 | [纯段](../../scripts/core/belt_segment_transport.gd)，`materialize()` |
| 区域重建 | 清除旧区域归属，沿输出和输入重新发现连通区、排序索引、构造区域拓扑与映射 | [区域管理](../../scripts/core/logistics_transport_regions.gd)，`rebuild()` |
| 编辑批次 | 整 tick／部分 tick 使用对应补充或正式结算；保留旧图推进与新图交接时序 | [物流入口](../../scripts/core/logistics_data.gd)，`advance()`；[区域](../../scripts/core/logistics_transport_region.gd)，`move_before_rebuild()`、`settle_tick()` |
| 重新合段 | 准备逐格队列、拓扑排序、重建段与重复状态、逐件 Identity 包装、区间标记 | [区域](../../scripts/core/logistics_transport_region.gd)，`prepare()`；[纯段](../../scripts/core/belt_segment_transport.gd)，`prepare()`、`_prepare_runs()` |

来源与上一批性能验证的范围见 [[cite:16]](#source-16)。
因此“局部拓扑仍未做”是不准确的；准确问题是**局部边变化触发了较粗粒度的区域状态重建**。
计数和源码能确认这些工作存在，不能据此给每部分分配精确毫秒或认定某一部分占比最大。

上一批已验证一次展开取代重复展开，十万格冻结长带编辑加首 tick 仍为秒级停顿；
稳定运输则在该重复状态基准中已很便宜。完整数字、计时口径和限制只在
[2026-11-12 性能审查](prealpha2-logistics-performance.md#2026-11-12编辑时减少重复展开与合段)维护。
此次没有重复测量，不将该基准扩展成复杂工厂或 FPS 上限。
[[cite:16]](#source-16)

### 可迁移机制与迁移边界

| 机制 | 成熟项目的证据 | 对当前问题的作用 | 必须保留的边界 |
| --- | --- | --- | --- |
| 直接邻接和固定小容器 | Mindustry 普通带 [[cite:2]](#source-2) | 减少逐件对象、包装与指针间接访问的候选方向 | 已有稠密索引与邻接不能重复建设；不能换掉公平、原子批次语义 |
| 物品间距与压紧游标 | shapez、Factorio [[cite:7]](#source-7)[[cite:10]](#source-10) | 可能减少不同相位自由流中的状态段工作 | 不能把每格容量、入向、到出口截断和资格规则抹掉 |
| 保留路径，局部拆并 | shapez [[cite:6]](#source-6)[[cite:7]](#source-7) | 编辑时保留无关段，端口变化尽量只重绑端口 | 路径拆分仍可能扫长队列；环与合流顺序另验 |
| 限制昂贵操作涉及的存储范围 | Factorio 历史设计 [[cite:10]](#source-10) | 避免十万格同属于一次必须展开的单位 | 存储分片边界不能成为多一道有延迟的游戏交接边界 |
| 正确性工作与组整理分开 | Factorio 运行组 [[cite:11]](#source-11) | 已断开的分量可以暂留同组，后台渐进重分组 | 新边必须按正式／补充批次及时正确生效；旧图不能误接 |
| 事件唤醒相关器械 | Mindustry 空带、Factorio 机械臂 [[cite:2]](#source-2)[[cite:11]](#source-11) | 减少空闲对象与无效边界轮询 | 完全压紧链解除堵塞要整队同批恢复；所有必要唤醒必须登记 |
| 压缩状态直接保存 | shapez [[cite:6]](#source-6)[[cite:7]](#source-7) | 减少保存前逐格表达的中间工作 | 保存仍需覆盖全部权威内容、完整校验、旧档兼容与精确时序 |

### 为什么不能直接换成自由平移队列

本项目要求每格最多两颗、固定 60 Hz 批次、到出口截断、交接不保留越过出口的余量，
新收到物品同批不能再次输出，并保留稳定 ID、入向、资格、最近输出 tick 和轮询。
转弯、坡道还有固定单格运输时间。自由平移整条路径的模型如果忽略内部格边界，
即使视觉近似正确，也会改变到达时间、容量与竞争结果。
[[cite:16]](#source-16)

间距表示并非因此不可采用：可把身份、路径坐标、格容量与时间资格分开维护，
或继续使用现有重复状态段，只先改善编辑维护。
但“任何不同间距都能整体移动”的成熟算法优势，需要额外证明它能与逐格量化约束共同成立。
尤其堵塞后解除、侧入、部分 tick 编辑和满载环，都不能仅用吞吐量相同作为等价证明。

当前纯段准备对整个区域做有向无环检查，区域含环时会回退。
这意味着真实工厂中的环可能影响同区域其他链的优化资格；
局部保留段时应研究环的求解边界，而不是顺手声称已具备普遍的环内路径优化。
[[cite:16]](#source-16)

## 后续验证建议

以下是按证据安排的候选实验，不是已批准的新实现范围。首要实验只检验编辑维护；
普通运输的现有三尺度成绩已经说明，无需先花一轮重写语言来证明简单长带可以快速运输。
[[cite:16]](#source-16)

### 优先实验：端口改变时保留带段

选用同一条长带，改变末端箱子方向；这是已有慢操作，也是不改变带内部几何的编辑。
比较当前实现与“只更新边界、保留段状态”的最小候选。
先沿用冻结参考逐 tick 核对全部身份、进度、资格、轮询、生产相位，
同时覆盖整 tick 和部分 tick 的补充结算。若仍必须访问整段，应明确指出是哪一条规则要求，
不能用“为了保险重建”代替分析。

本实验的关键输出是展开格数、保留段数、重建格数、同步编辑与首 tick 耗时。
若只改变末端器械仍必须展开十万格，就未达到这项结构性目标；
不能仅用对象池让一次全区展开快一些便宣布完成局部维护。
借鉴依据是 shapez 的端点接收绑定与路径生命周期，而非其所有数组操作。
[[cite:6]](#source-6)[[cite:7]](#source-7)

### 第二实验：中间拆带、重连与有界存储单位

保留路径身份和队列，针对中间拆除将路径切开，重连时接合。
先测直接数组拆分的实际成本；如果长路径编辑仍受大复制影响，再比较有界存储分片或队列切片。
不同分片大小是实验参数，需要测稳态边界成本、编辑访问范围、初建与内存，
不能从 Factorio 旧文中的 100 格直接决定。
[[cite:7]](#source-7)[[cite:10]](#source-10)

这里的分片是存储和维护单位。它必须允许同批内部推进与原有交接结果，
不能让新增分片边界增加一 tick 等待、重复丢弃余量或影响满载链同批恢复。
必须加入跨分片的物品、末尾拆除、坡道、合流和环切断／重连验收。
若无法在现有规则下得到有界编辑，应如实报告例外，而不是把最坏情况隐藏到首 tick。

### 第三实验：区域拆分延后，连接仍立即正确

在能保存段状态之后，再尝试让删除连接后的多个分量暂留原运行组，
以有限工作预算逐步重分组。对外仍只暴露已经生效的新图。
新连接、旋转、连续编辑、保存、暂停和恢复都要能够中断或合并整理任务。
这比把当前重建函数机械地每帧处理一部分更有依据：
它需要先给出一个整理未完成时仍正确可运行的表示。
[[cite:11]](#source-11)

当前区域队列、求解和索引依赖区域重建，不能直接认为已满足该前提。
如果新图导致多个旧区域相互作用，必须先提供一致的运行归属和执行顺序；
仅延后分量提取不能允许遗漏交接、重复归属或查询见到混合版本。

### 其他优化的启动条件

| 候选 | 何时值得启动 | 本次证据能支持到什么程度 |
| --- | --- | --- |
| 更一般的间距表示 | 不同合法相位让 `R` 接近格数，且真实工厂稳定推进开始成为主要成本 | shapez／Factorio 证明不同间距自由流可高效表示；本项目等价性未证明 |
| 更紧凑的数组或对象复用 | 分配、复制、峰值内存或缓存访问被分项测量确认为主要剩余成本 | Mindustry 提供小数组参照；本项目展开确实新建对象，但未测其单独占比 |
| 活动器械与唤醒 | 大量空闲区域、箱子、矿机或端口造成持续轮询成本 | 成熟项目有实例；必须审计本项目已有到期生产与活动端口能力，避免重复实现 |
| Rust／其他原生实现 | 局部维护已定型，固定工作量的紧凑规则仍受 VM 执行明显限制 | 本次没有 GDScript／Rust 对照，不提供提速倍数 |
| 多线程 | 独立运行组充足、瓶颈不是内存吞吐，唤醒和 ID 分配顺序可确定 | Factorio 同时有成功与失败例子；不是当前同步编辑问题的首项解法 |

每个实验都应增加三个与现有同相位长带互补的世界：合法不同进度的长带；
包含多路汇入、器械、分支的连通工厂；含闭环及切断重连的工厂。
另外把同总格数分别组织成一条长路径与多条短路径，分清成本随格数、状态段数、边界数
还是受影响区域规模增长。继续采用前后同输入、新进程、独占规则测量，
分开同步编辑、首 tick、稳定运输、范围采样、初建与内存，不把保存或 observer 时间混进同一指标。
本次没有新测量数据。

## 调研验收与审查

文档验收要求：核心机制能定位到固定源码或官方原文；旧计划和现状分开；
明确普通带与其他器械、线路与运行组、动画与模拟、局部推进与整厂性能的区别；
所有建议标为未实施；本地规则与实现映射可追踪；本地链接、来源锚点和 diff 检查通过，
并完成独立文档审查。游戏未变更，游戏测试和实时编辑器验证不属于本次检查。

独立审查结果：Critical 0／Important 0／Optional 1，无阻断项。
审查先读取上述验收，再核对全文、两游戏关键源码、五个本地物流模块与现行规格，
通过 GitHub CLI 核对 11 份材料哈希、版本标签与许可证，并读取五篇 Factorio FFF 和官方 API。
唯一 Optional 是“只有旧档才重算路径”的表述过窄，已依据空路径列表判断修正，涵盖空工厂。
历史性能记录新增的调研入口也已纳入审查。

来源限制：2025 年开发者论坛正文由主调研读取，独立审查的再次获取被安全验证拦截，
该补证未完成独立正文核验；核心运输与分组结论另有已独立读取的官方 FFF 支持。
本地链接、来源锚点、固定源码版本、标题结构与空白检查通过。

## 来源

<a id="source-1"></a>
**[cite:1] Mindustry 项目与版本。** [README](https://github.com/Anuken/Mindustry/blob/17012d61d9e4c3cbd9820d87e81c24495486ac53/README.md)，
[发布 v160.7](https://github.com/Anuken/Mindustry/releases/tag/v160.7)，GitHub 仓库 API 的许可证元数据为 GPL-3.0。
源码通过 GitHub CLI 获取，版本标签解析到上文固定提交。

<a id="source-2"></a>
**[cite:2] Mindustry 普通 Conveyor。** [固定源码](https://github.com/Anuken/Mindustry/blob/17012d61d9e4c3cbd9820d87e81c24495486ac53/core/src/mindustry/world/blocks/distribution/Conveyor.java)：
[容量 L26–53](https://github.com/Anuken/Mindustry/blob/17012d61d9e4c3cbd9820d87e81c24495486ac53/core/src/mindustry/world/blocks/distribution/Conveyor.java#L26-L53)，
[字段 L123–141](https://github.com/Anuken/Mindustry/blob/17012d61d9e4c3cbd9820d87e81c24495486ac53/core/src/mindustry/world/blocks/distribution/Conveyor.java#L123-L141)，
[邻接 L212–224](https://github.com/Anuken/Mindustry/blob/17012d61d9e4c3cbd9820d87e81c24495486ac53/core/src/mindustry/world/blocks/distribution/Conveyor.java#L212-L224)，
[运行与堵塞 L253–305](https://github.com/Anuken/Mindustry/blob/17012d61d9e4c3cbd9820d87e81c24495486ac53/core/src/mindustry/world/blocks/distribution/Conveyor.java#L253-L305)，
[接收与保存 L352–428](https://github.com/Anuken/Mindustry/blob/17012d61d9e4c3cbd9820d87e81c24495486ac53/core/src/mindustry/world/blocks/distribution/Conveyor.java#L352-L428)。

<a id="source-3"></a>
**[cite:3] Mindustry BuildingComp。** [休眠与激活 L654–671](https://github.com/Anuken/Mindustry/blob/17012d61d9e4c3cbd9820d87e81c24495486ac53/core/src/mindustry/entities/comp/BuildingComp.java#L654-L671)，
[邻域更新 L1866–1914](https://github.com/Anuken/Mindustry/blob/17012d61d9e4c3cbd9820d87e81c24495486ac53/core/src/mindustry/entities/comp/BuildingComp.java#L1866-L1914)，
[更新入口 L2270–2282](https://github.com/Anuken/Mindustry/blob/17012d61d9e4c3cbd9820d87e81c24495486ac53/core/src/mindustry/entities/comp/BuildingComp.java#L2270-L2282)，
[Logic 建筑组更新入口 L487–491](https://github.com/Anuken/Mindustry/blob/17012d61d9e4c3cbd9820d87e81c24495486ac53/core/src/mindustry/core/Logic.java#L487-L491)。

<a id="source-4"></a>
**[cite:4] Mindustry StackConveyor。** [固定源码](https://github.com/Anuken/Mindustry/blob/17012d61d9e4c3cbd9820d87e81c24495486ac53/core/src/mindustry/world/blocks/distribution/StackConveyor.java)，
[更新与整批转移 L268–315](https://github.com/Anuken/Mindustry/blob/17012d61d9e4c3cbd9820d87e81c24495486ac53/core/src/mindustry/world/blocks/distribution/StackConveyor.java#L268-L315)。

<a id="source-5"></a>
**[cite:5] 原版 shapez 资格与版本。** [固定 README](https://github.com/tobspr-games/shapez.io/blob/4e5e5c8ef7eefa674fc9c4191b1a9b800ae262ee/README.md)，
[发布 1.5.1](https://github.com/tobspr-games/shapez.io/releases/tag/1.5.1)，
[发行商 Steam 页面](https://store.steampowered.com/app/1318690/shapez/)；GitHub 仓库 API 的许可证元数据为 GPL-3.0。

<a id="source-6"></a>
**[cite:6] shapez BeltSystem。** [保存读取 L70–111](https://github.com/tobspr-games/shapez.io/blob/4e5e5c8ef7eefa674fc9c4191b1a9b800ae262ee/src/js/game/systems/belt.js#L70-L111)，
[附近更新 L117–215](https://github.com/tobspr-games/shapez.io/blob/4e5e5c8ef7eefa674fc9c4191b1a9b800ae262ee/src/js/game/systems/belt.js#L117-L215)，
[编辑路径 L218–325](https://github.com/tobspr-games/shapez.io/blob/4e5e5c8ef7eefa674fc9c4191b1a9b800ae262ee/src/js/game/systems/belt.js#L218-L325)，
[全路径重算与更新 L420–492](https://github.com/tobspr-games/shapez.io/blob/4e5e5c8ef7eefa674fc9c4191b1a9b800ae262ee/src/js/game/systems/belt.js#L420-L492)。

<a id="source-7"></a>
**[cite:7] shapez BeltPath。** [表示与初始化 L24–155](https://github.com/tobspr-games/shapez.io/blob/4e5e5c8ef7eefa674fc9c4191b1a9b800ae262ee/src/js/game/belt_path.js#L24-L155)，
[绑定及缓存 L169–306](https://github.com/tobspr-games/shapez.io/blob/4e5e5c8ef7eefa674fc9c4191b1a9b800ae262ee/src/js/game/belt_path.js#L169-L306)，
[延长与拆分 L529–781](https://github.com/tobspr-games/shapez.io/blob/4e5e5c8ef7eefa674fc9c4191b1a9b800ae262ee/src/js/game/belt_path.js#L529-L781)，
[合并 L1033–1104](https://github.com/tobspr-games/shapez.io/blob/4e5e5c8ef7eefa674fc9c4191b1a9b800ae262ee/src/js/game/belt_path.js#L1033-L1104)，
[运输与压紧缓存 L1123–1255](https://github.com/tobspr-games/shapez.io/blob/4e5e5c8ef7eefa674fc9c4191b1a9b800ae262ee/src/js/game/belt_path.js#L1123-L1255)，
[绘制 L1396–1547](https://github.com/tobspr-games/shapez.io/blob/4e5e5c8ef7eefa674fc9c4191b1a9b800ae262ee/src/js/game/belt_path.js#L1396-L1547)。

<a id="source-8"></a>
**[cite:8] shapez 几何与物品值。** [BeltComponent L6、53–71、101–116](https://github.com/tobspr-games/shapez.io/blob/4e5e5c8ef7eefa674fc9c4191b1a9b800ae262ee/src/js/game/components/belt.js)，
[共享物品解析器](https://github.com/tobspr-games/shapez.io/blob/4e5e5c8ef7eefa674fc9c4191b1a9b800ae262ee/src/js/game/item_resolver.js)，
[Rectangle 相交测试](https://github.com/tobspr-games/shapez.io/blob/4e5e5c8ef7eefa674fc9c4191b1a9b800ae262ee/src/js/core/rectangle.js#L227-L247)。

<a id="source-9"></a>
**[cite:9] Factorio FFF-148，2016-07-22，初始合段计划与待解问题。**
[Optimizations for 0.14](https://factorio.com/blog/post/fff-148)。

<a id="source-10"></a>
**[cite:10] Factorio FFF-176，2017-02-03，间距表示、压紧索引、动态拆并与当时性能。**
[Belts optimization for 0.15](https://factorio.com/blog/post/fff-176)。

<a id="source-11"></a>
**[cite:11] Factorio FFF-364，2021-01-29，运输线组、延后拆组、确定性唤醒与并行收益。**
[1.1 stable — Multithreaded belts](https://factorio.com/blog/post/fff-364)。

<a id="source-12"></a>
**[cite:12] Factorio FFF-405，2024-04-05，整线读取及侧入／分流边界。**
[Whole belt reader](https://factorio.com/blog/post/fff-405)。

<a id="source-13"></a>
**[cite:13] Factorio FFF-421，2024-07-26，读取器成本、并行化与内存瓶颈反例。**
[Optimizations 2.0](https://www.factorio.com/blog/post/fff-421)。

<a id="source-14"></a>
**[cite:14] Factorio 近年机制补证。** boskid，2025-10-20，
[不补充部分堆叠的开发者说明](https://forums.factorio.com/viewtopic.php?p=683324#p683324)；
[LuaTransportLine 官方 API](https://lua-api.factorio.com/latest/classes/LuaTransportLine.html#line_equals)。
API 为动态 latest 地址，访问当日页头版本 2.1.24，只用于核验跨多格内部线的公开契约。

<a id="source-15"></a>
**[cite:15] Satisfactory Modding 社区补充材料。**
[Factory Tick](https://docs.ficsit.app/satisfactory-modding/latest/Development/Satisfactory/FactoryTick.html)。
只说明检索范围与证据缺口，不据此宣称具体传送带表示。

<a id="source-16"></a>
**[cite:16] ProjectFactory 访问当日工作树及已有验收。**
[现行基础物流规则](../features/prealpha-1/003-basic-logistics.md#行为与边界)，
[纯段与编辑转换规格](../features/prealpha-2/001-logistics-performance.md#当前实施纯传送带段合并)，
[此前性能证据](prealpha2-logistics-performance.md#2026-11-12编辑时减少重复展开与合段)；
实现定位见上文表格。工作树包含未提交修改，报告不将当前代码冒充某个已提交版本。
