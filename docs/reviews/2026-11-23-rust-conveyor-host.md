# 2026-11-23：RustConveyor 宿主接入切片

范围：`feat/rust-conveyor-integration` 中新增 Rust 后端及测量入口。
既有用户物流优化与 Godot AI 上游更新不属于此次修改范围。
目标与未完成验收见 [002 规格](../features/prealpha-2/002-rust-conveyor-integration.md)。

## 已取得的证据

- 原生门面先出现 “Missing native LogisticsData backend” 的 RED；
  随后独立 Godot 进程输出 `PROJECT_FACTORY_RUST_CONVEYOR_PASS`。
  入口为 `scripts/check_rust_conveyor.gd`，覆盖实际坡道速度、身份、
  组合检查点恢复/拒绝、继续演化、只读采样、载矿旋转及拆除。
- Apple M4 Pro、Godot 4.7.2、release 绑定、无头挂载完整 `FactoryGame`，
  使用既有压力生成器的 16×6×16 布局：1,124 条带、4 条坡道、
  2,248 件初始矿石、4 个 Rust 逻辑段。预热 60 tick 后测量 120 tick，
  推进 p95 0.068 ms，核心 p95 0.026416 ms，
  范围采样 p95 7.962 ms，完整场景提交 CPU 帧 p95 21.589 ms。
  该结果包含真实场景查询、三维映射及批量表现提交；无头不包含 GPU 光栅化。
  原始样本由测量工具输出，不在此手抄全部日志。

## 待验证及限制

编辑仍为显式全量重建，显示仅使用已提交 tick；不是本规格的最终性能验收。
上述小规模不能代替 10k、100k、百万压力及磁盘读档/挂载耗时。
旧后端与 Rust 的坡道/环路规则不同，不以该切片数字证明同规则加速。

独立宿主审查已完成，结论 Request Changes。发现待处理：

- **Critical**：载矿重新连接后压缩线路可能把两个入口/出口物品导入同一位置；
  旧实例已丢弃时会使全后端停止。需先验证编辑并保留不能立即合并的边界。
- **Important**：快照只校验段长度和连边，缺少完整端口/设备以及逐格几何绑定。
- **Important**：带到带合流成交未更新实际入口方向，导致合流前半格绘制错误。
- **Important**：直接库存边应保持整批库存和旧 tick 资格；当前逐件及结算顺序不符。
- **Important**：失败 tick 前修改了矿机相位，多 tick advance 的时钟/身份也未逐次提交。
- **Important**：测量窗口箱子基线在第一 tick 后采集，少计算该 tick 吞吐。

尚未完成全部游戏验证和实时视觉验收：
此前无头编辑器导入因系统 Godot 用户数据目录写权限失败；
本记录不把独立命令行脚本通过当作完整验证通过。

扩大到 32×12×32 时，初次坐标导入被 `InsufficientSpace` 正确拒绝：
长 5286.57106781186575972 米的逻辑段中，浮点全局坐标差将 0.25 米
间距舍入为 0.24999999999977263。新增补偿 gap 导入先 RED，
由局部片段距离构建批量输入；此处仍待新库重建后的扩大规模复验。

## 复现入口

先按 RustConveyor 的 `godot/install.sh` 安装 release 原生库，再执行：

```sh
godot --headless --path . -s res://scripts/check_rust_conveyor.gd --quit-after 10
godot --headless --path . -s res://scripts/pressure_native_benchmark.gd \
  -- 16 6 /tmp/new-pressure-report 120 60 rust
```

检查退出码、Godot 错误以及成功标记，不能仅依据引擎返回 0。
压力输出目录必须尚不存在；去掉 `--headless` 才能采集 GPU 帧截图。

## 2026-11-23: Independent Three-Fix Follow-Up

Read-only, tests-first review of the identity ceiling/regression, empty-view
sampling guard, and native verification markers. Only this dated append was
written; no implementation edits, tests, builds, benchmarks or editor runs.
Earlier conclusions above are preserved; this is not a re-review of other fixes.

- **Critical:** None found in this scope.
- **Important:** None found statically. The earlier identity-overflow finding
  is addressed in source, but runtime closure remains unverified.
- **Optional:** Add fake-engine coverage for `verify.sh:57-63`: missing contract
  PASS, each missing regression marker, nonzero exit and Godot errors must fail.
  `scripts/test_verify.py` currently creates no native-extension fixture.

Boundary proof: let `M = SnapshotValues.MAX_INTEGER = 9223372036854775807`.
[`RustTransport`](../../scripts/core/rust_belt_transport.gd) sets `L = M - 1`
before clock/import preparation and again after native restore. The newly
present `RustConveyor/godot/src/lib.rs:78-87` exports the positive-i64 setter;
`src/api.rs:265-275` rejects a limit below existing identities before mutation.
`src/simulation.rs:559-566` accepts an allocation only when `last + 1 <= L`.
Thus the last allocatable ID is `L`, and every host `last_identity() + 1` remains
at most `M`; `M` is a representable exhausted sentinel, never a new item ID.
Reapplying the ceiling after restore is necessary because the bridge restore
otherwise resets it to `i64::MAX`. Rejected ticks publish no success events;
host phase, inventory, clock and next-ID settlement occur only after success.

[`_identity`](../../scripts/check_rust_regressions.gd) exercises exhaustion,
unchanged host phase/inventory/tick/next-ID and checkpoint recovery.
`/tmp/pf_identity_red_20261123.log` contains the intended failure. It does not
exercise advancement of the separately loaded instance or last-ID success;
the Rust smoke source covers the native last-ID boundary, but was not run here.
No post-fix host identity GREEN evidence was found in the inspected logs.

[`LogisticsView`](../../scripts/world/logistics_view.gd) skips sampling exactly
when `ore_cells` is empty, while clearing item arrays and ending all render-pool
frames, so stale ore visuals retire and inventory decorations still refresh.
The supplied fullverify RED shows extra sample calls at range-test lines 85/91;
`/tmp/pf_range_view_green_20261123.log` reports 7/7 with zero failures/errors.
[`verify.sh`](../../scripts/verify.sh) requires the exact contract PASS line
and all 12 distinct regression PASS lines under `set -euo pipefail`, in addition
to the existing exit/error checks; a partial run cannot satisfy the gate.

Limits: source presence does not prove the installed binary exports the new
method. Latest fullverify is not completed; million-belt testing has not been
performed. Neither full verification, native runtime closure nor visual or
million-scale acceptance is claimed. The generic review skill's referenced
workflow files were unavailable; the repository quality-review workflow was used.

Final source recheck, 2026-11-23: a concurrent `_identity` addition at lines
29-41 now exercises the last valid-ID tick, `next_id == M`, and checkpoint
round-trip. This supersedes the last-ID success coverage gap above; no new
Critical/Important issue was found. Advancement of the separately loaded
exhausted instance and post-fix runtime GREEN remain unverified.

## 2026-11-23：最终功能复验与历史问题收口

本节对应同一功能分支的最终接入实现，保留前文各次审查的原范围与限制。
前文 reconnect、完整几何绑定、实际入口来源、直接库存整批资格、
失败 tick 结算、身份上限和测量边界问题均已修复。
等待接缝不能被静默合并，组合恢复比较设备/端口/几何与时钟；
宿主只在原生成交成功后提交设备相位、库存和身份。
长坡段按局部补偿距离导入，未通过扩大间距容差绕过原生校验。
原生核心及分发的独立复审已逐项关闭 Critical/Important，
对应记录保存在 RustConveyor 的
`docs/reports/2026-11-23-package-integration-independent-review.md` 和
`2026-11-23-distribution-review.md`。

最终 `scripts/verify.sh` 在隔离副本使用 Godot 4.7.2 和最新 release 原生库通过：
430 项 GdUnit4 用例零错误/失败，原生契约成功标记与 12 项不同宿主回归标记齐全。
导入、类型检查、两次真实跨进程启动、120 帧主场景运行、
原项目缓存不变和 diff 检查全部通过。
实际日志为 `/tmp/pf_native_full_final_20261123_v4.log`；
较早 v2 的异常退出和 v3 的脚本解析错误均不是成功证据。
此最终输出补齐前文身份 runtime GREEN 与完整验证缺口。

实时 Godot AI 已确认连接本项目，读取主场景层级并检查主菜单及世界截图、
运行日志；结束已停止游戏。最终完整验证之后再次扫描注册类，
全局类表无新增差异。原编辑器进程不能热重载原生库，
最终原生图形压力另用新启动的 Godot 进程验收。

## 2026-11-23：最终四尺度压力结果

Apple M4 Pro、macOS arm64、Godot 4.7.2、Forward Plus、release 原生库。
每例独立进程顺序运行：既有压力生成器构建→组合检查点→bank 保存和校验
→磁盘解码独立会话→完整线路审计→挂载真实 `FactoryGame`。
预热 120 tick，测量 300 tick（模拟时间 5 秒），每个 tick 提交真实附近表现。
下表为无头结果，不包含 GPU 光栅化；时间单位 ms，均为 p95。

| 实际带数 | 坡道 | 初始矿石 | 核心 | 含宿主推进 | 场景更新 CPU | 引擎帧间隔 | 全进程峰值 RSS |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1,124 | 4 | 2,248 | 0.025375 | 0.077 | 21.565 | 21.662 | 0.471 GiB |
| 10,572 | 10 | 21,144 | 0.027709 | 0.098 | 105.190 | 105.356 | 0.471 GiB |
| 103,208 | 25 | 206,416 | 0.030584 | 0.105 | 171.862 | 172.031 | 1.662 GiB |
| 1,016,188 | 62 | 2,032,376 | 0.035083 | 0.110 | 180.195 | 180.365 | 14.048 GiB |

四例均完整访问全部带格、出口可达、4 个 Rust 逻辑段、4 个生产端口和
1 个消费端口。各测量窗口实际生产 20 件、消费 20 件、跨逻辑段成交 30 次，
等于每模拟秒 4 件消费；不是所有带格交接的计数。
无头百万窗口墙钟 52.023803 秒，实际墙钟吞吐约 0.3844 件/秒。
此夹具是一条很长的压缩线路，不代表百万独立逻辑段或复杂分合流的成本。
每 tick 的物品移动距离尚无计数，不据此宣称所有物品持续自由运动。

| 阶段（秒） | 1,124 带 | 10,572 带 | 103,208 带 | 1,016,188 带 |
| --- | ---: | ---: | ---: | ---: |
| 生成 | 0.040453 | 0.298547 | 2.890441 | 29.603735 |
| 检查点导出 | 0.023743 | 0.145627 | 1.405233 | 14.251864 |
| bank 保存与校验 | 0.119681 | 0.813218 | 7.991910 | 80.740324 |
| 磁盘加载/解码 | 0.052270 | 0.384809 | 3.895029 | 38.686655 |
| 完整拓扑审计 | 0.002535 | 0.022394 | 0.226216 | 2.315672 |
| 场景挂载 | 0.031207 | 0.219937 | 1.997471 | 19.409509 |

### 无头百万尾延迟与工作量

| 阶段（ms） | p50 | p95 | p99 | 最大 | 超 16.667 ms 样本 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 宿主准备 | 0.032 | 0.041 | 0.049 | 0.119 | 0 |
| 绑定调用，含核心 | 0.040 | 0.054 | 0.060 | 0.090 | 0 |
| Rust 核心 | 0.025084 | 0.035083 | 0.041333 | 0.072042 | 0 |
| 成交结算 | 0.004 | 0.006 | 0.008 | 0.011 | 0 |
| 完整物流推进 | 0.090 | 0.110 | 0.146 | 0.194 | 0 |
| 候选查询 | 6.427 | 6.635 | 6.860 | 7.616 | 0 |
| 装饰更新 | 93.615 | 98.160 | 103.338 | 105.516 | 300 |
| 范围采样及返回转换 | 39.859 | 42.028 | 42.577 | 50.432 | 300 |
| 三维映射 | 3.872 | 4.103 | 4.243 | 5.255 | 0 |
| 表现提交 | 13.516 | 14.347 | 15.045 | 17.429 | 2 |
| 场景更新 CPU | 173.013 | 180.195 | 185.597 | 195.978 | 300 |
| 引擎帧间隔 | 173.182 | 180.365 | 185.766 | 196.159 | 300 |

百万每 tick 在带物品 2,032,372～2,032,375 件，
核心访问树节点 86～245 个；候选固定 11,569 格，
采样返回 8,096～8,098 件。窗口起点总矿石 2,032,384，
设备库存 9、在带 2,032,375；终点总矿石 2,032,404，
设备库存 29、在带 2,032,375。箱子 8→28，数量与实际成交一致。
在带数量的逐 tick 变化及累计交易由 `work_samples.json` 与耗时样本对应。

运输核心与宿主推进在本夹具下已经很小，整游戏仍未达到 60 FPS。
下一项性能瓶颈是装饰、范围采样/数据转换和表现提交；
本次没有测量这些阶段内部更细的原因，不从汇总擅自归因到单一函数。
RSS 是含生成、保存、加载、挂载及报告写入的整个进程峰值；
百万 Godot 静态内存峰值约 10.776 GiB，不能当作 Rust 堆内存大小，
也不能用两者相减得出准确的原生堆开销。

### 原始证据与适用限制

原始矩阵目录：`/tmp/pf_native_matrix_final_20261123/`。
每例保留 `performance.json`、`samples.json`、`work_samples.json`、
真实 bank 存档和完整日志；四例均有结果标记、无 Godot 错误，
计量一致性检查通过。来源文件为该目录的 `provenance.json`，
安装库与当时 Rust 构建输入指纹一致，
库 SHA-256 为 `059d1b50833eddf93a035792b2ac03e71362cc8b53c83965d90663bdcee38aa5`。
工作树未提交，不能仅用 HEAD 重现；测量命令与输入指纹保存在 provenance。
测量后修复了图形启动器的 Bash 3.2 空数组问题，
不改运输、采样或场景实现；无头数据对应文件中记录的原启动器。

场景更新 CPU 只量 `advance + refresh_from_data`；
引擎帧间隔另含中间引擎工作与调度，最后 tick 也量至下一次回调。
墙钟排除人口审计和报告写入，包含逐 tick 计量 bookkeeping。
绑定包含核心，两个阶段不能相加作为总耗时。
旧 GDScript 与 Rust 的坡道、交接资格和满环规则不同，
没有同规则/同实际工作量的基线，不能由本轮数字宣称加速倍数。

### 图形百万运行

修复启动器后，在新的 macOS 窗口进程重复同一百万生成、磁盘加载及挂载流程，
同样预热 120 tick、测量 300 tick；Forward Plus 渲染启用。
核心 p50/p95/p99/最大为 0.025458/0.039083/0.050042/0.057834 ms；
完整推进 p95 0.136 ms，场景更新 CPU p95 183.887 ms，
引擎帧间隔 p50/p95/p99/最大为 177.335/186.370/188.321/191.311 ms，
300/300 帧超过 16.667 ms。帧间隔包含引擎及 GPU 协作，不是纯 GPU 耗时。
装饰、范围采样、三维映射和表现提交 p95 分别为
99.545、42.530、4.195、15.279 ms。

窗口墙钟 53.685331 秒，生产/消费各 20 件、跨段成交 30 次，
人口起止与无头百万相同；墙钟消费约 0.3725 件/秒。
全进程峰值 RSS 14.135 GiB。
磁盘加载/解码 38.832869 秒、场景挂载 20.608421 秒，
其余分阶段值由原始报告维护。
`/tmp/pf_native_window_final_20261123_v2/` 保留原始日志、报告、样本与存档。
结果标记、300 项计量一致性检查、错误检查均通过，进程正常退出并停止游戏。
已人工检查 [最终截图](rust_conveyor_million_2026_11_23.png)，
可见附近多层带面、矿石、箭头和 HUD；截图只证明该视野的真实渲染。

启动器修复先在 `/bin/bash -uc` 重现空 `DISPLAY_ARGS` 导致
`unbound variable` 的 RED，再验证空参数和单个 `--headless` 参数均无损的 GREEN，
并通过 Bash 语法检查。第一次图形尝试尚未启动 Godot，不计入测量；
目录 `/tmp/pf_native_window_final_20261123/` 保留失败记录。

## 2026-11-23: Independent Final Documentation And Evidence Review

Verdict: **Approve within this bounded scope, with one Optional documentation
note. No Critical or Important finding.** Earlier Request Changes entries
remain historical evidence; this append does not rewrite or reopen them.

### Scope And Method

Independent reviewer, without implementation authorship. Read `AGENTS.md`
and `.trae/skills/code-review-and-quality/SKILL.md` first, then acceptance,
specifications and `scripts/check_native_pressure_report.py` before scoped
source inspection. Queried both dirty worktrees: PF
`feat/rust-conveyor-integration`, HEAD `393c219`; RC
`feat/package-integration`, HEAD `14476e0`.

Reviewed PF README, development instructions, 009 slope-rule succession,
002 integration status and this host record; RC README, host-api contract,
package-integration plan and acceptance record. Implementation inspection
was limited to the Bash 3.2 launcher correction and measurement definitions
needed to interpret evidence. Core and distribution algorithm closures in
RC's independent-review and distribution-review reports were read as
historical dispositions, not independently re-reviewed.

### Findings

- **Critical:** None in this scope.
- **Important:** None in this scope.
- **Optional:** RC `docs/specs/host-api.md:6,273` retains source-relative
  plan/acceptance links in both standalone bundle copies of `host-api.md`.
  Neither destination exists inside that bundle. Supply recipient-resolvable
  links or label them checkout-only. This continues the earlier distribution
  review's nonblocking navigation note; the contract and installation
  instructions themselves are present and usable.

### Evidence Checked

- Final PF log `/tmp/pf_native_full_final_20261123_v4.log` contains 430/430
  GdUnit4 cases, zero errors/failures, the native contract marker, all 12
  distinct regression markers, both startup gates and the final verification
  success line. Earlier v2/v3 outputs are not used as success evidence.
- Rust debug/release logs independently total 233 passes each, zero failures,
  ignored or filtered cases, including 44 public package tests. Inspected
  Clippy, MSRV 1.94.1 and release-workspace-build completion logs, plus the
  standalone crate/Godot consumer and custom-target acceptance logs.
  The fmt log is empty; its successful exit is parent-reported, not inferable
  from that file alone.
- Read all five retained pressure report/sample/work sets: four sequential
  headless cases and graphical million v2. Read-only JSON calculations
  reproduce every reported stage percentile, maximum and over-budget count.
  All sets have 300 timing/work rows for contiguous ticks 121 through 420,
  intervals at least as long as their paired CPU frames, interval sums
  matching wall time, valid population arithmetic and transaction deltas.
  These checks also cover the retained checker's accounting assertions.
- Four-scale counts, generation/save/load/audit/mount times and million
  workload ranges agree with this record. Each window records 20 produced,
  20 consumed and 30 logical-segment crossings, not voxel crossings.
  Million RSS values match system logs: 14.048 GiB headless and 14.135 GiB
  graphical, both full-process peaks. CPU frame versus engine interval,
  nested core/binding timing, excluded audits, unavailable movement distance,
  four-segment fixture and differing backend semantics are disclosed.
  No same-semantic speedup or 60 FPS conclusion is supported or claimed.
- Bash launcher line 42 guards the empty array before quoted expansion,
  preserving zero window flags or exactly one `--headless` flag without
  introducing an empty argument. RED/GREEN argv and `bash -n` results are
  parent-reported, not rerun here. Graphical v2 provenance omits `--headless`;
  its result and error gate pass. The saved review PNG is byte-identical to
  that run's PNG; screenshot content analysis remains parent-owned.
- Final package/bundle rebuild logs show successful completion. Inspected
  the 72-entry, 197005-byte crate and confirmed its README, host-api and plan
  bytes match authoritative checkout documents. Both bundle contract copies
  and its README likewise match their sources. Bundle build metadata agrees
  with measured native provenance. The parent's final native-hash,
  16-inventory/notice, eight-MPL-archive and ZIP testzip checks are not claimed
  as independent executions; ZIP size was inspected as 10266233 bytes.
  External Rust/Godot consumer evidence predates the docs-only repack.
  Final Cargo verification is a package-local build, not a repeated external
  consumer run; unchanged source/binary is the parent's stated boundary.
- All 111 local links/heading anchors in the nine scoped checkout documents
  resolve. Scoped tracked diff whitespace checks pass in both repositories.
  Authority statuses preserve default GDScript rules, explicitly accepted
  Rust slope semantics and unfinished local-edit/sub-tick/platform work.

### Limits

Only this append was written. No implementation edits, builds, tests,
benchmarks, Godot/editor operation, large-tree or binary hashing, commit or
push were performed. Parent-produced logs and metadata were inspected;
only small retained JSON and document/link comparisons were recalculated.
User logistics and vendored-addon changes were left untouched. Approval
does not extend to other platforms, registry publication, remote CI,
comparative performance or independently repeated visual/runtime acceptance.
