# 2026-11-25：保存不再重建工厂

基线：ProjectFactory `d3a941f` 的工作树变更。
范围：[003 保存边界](../features/prealpha-2/003-save-without-reconstruction.md)、
`scripts/save_game_store.gd` 与存档集成回归。
RustConveyor 源码、运输算法、存档字段及格式版本未修改。

## 变更与失败边界

取消保存前和写盘读回后的完整快照恢复。
保存仅检查区块写入容器、坐标及记录长度；全部文件仍磁盘读回、
解压并验证文件头、长度和 SHA-256，成功后才原子切换 bank／命名索引。
实际加载保留原完整规则恢复，失败不替换活动游戏。
文件边界合法但物流语义非法的状态现在可保存，在实际加载时拒绝。

## 回归与独立审查

先修改验收再执行 RED，关闭 fail-fast 后完整运行存档套件：
五个相关测试按旧恢复次数和保存语义拒绝行为失败，无解析错误。
实现后 GREEN 通过；独立 subagent 先读规格和测试，再审实现，
未发现 Critical，Important 为表达式临时读回缓冲区可能跨文件保留。
已改为显式变量，并在每个文件检查后清空；该发现来自静态生命周期检查，
未将其描述为已经实测的内存泄漏。

Optional 的文件损坏覆盖也已补齐：完整文件头下篡改会话／区块 SHA，
以及删除新 bank 的区块，均拒绝提交，上一成功档仍能加载。
最终定向回归为 11 项通过，无 errors／failures／skipped／orphans。
首轮完整验证为处理审查问题主动中止，不计为通过；
最终完整 `verify.sh` 退出码为零：451 项游戏用例全部通过，
无 errors／failures／flaky／skipped／orphans；Python 工具回归、
导入、业务类型检查、Rust 契约／12 项宿主回归／显示、
前后两次跨进程启动、120 帧主场景、原编辑器缓存和 diff 检查均通过。
新的独立 subagent 定向复审确认 I1／O1 关闭，
Critical／Important／Optional 均无新增项。
权威文档生效及旧条款替代标识经另一独立 subagent 收尾审查，
Critical／Important／Optional 均为零，引用与 diff 检查通过。

## 场景与有界计时

Godot AI 确认连接 ProjectFactory 4.7.2，读取主场景；
脚本通过编辑器 patch 无诊断、热加载成功，修改后扫描完成。
从原编辑器启动时游戏运行桥未就绪，未据此声称菜单通过；
停止游戏后，在包含最终源码与现有正式原生库的隔离图形项目补验。

两后端均完成真实视口鼠标事件触发的新游戏命名、命名保存、
磁盘读取、编辑后选择不提前加载、确认恢复和保存退出。
断言保存恢复计数为零，两次实际加载之后退出保存不再增加恢复次数。
名称通过 LineEdit 设置，未声称完成操作系统键盘输入验收。
71 次实际绘制，八张主菜单／选择／恢复／返回截图已逐张检查；
恢复画面与状态均保留四条传送带和八颗矿石，图形进程正常退出。

同一夹具含 16,384 格基础地面，定向计时仅量 `SaveGameStore.save_game()`，
不含快照导出或场景挂载。单次 GDScript 保存 8.116 ms，
Rust 保存 5.185 ms，完整恢复次数均为零。
这是有界功能计时，不是三轮配对性能验收，未重测百万档或外推其秒数。
原始临时输出为 `green-final-tests.log`、`menu-visual.log` 与 `menu-output/`。
最终完整日志为 `final-full-verify.log`，
独立初审及复审分别为 `independent-review.md`、`final-independent-review.md`。
文档收尾审查为 `doc-closeout-review.md`。
