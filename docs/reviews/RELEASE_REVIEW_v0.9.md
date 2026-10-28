# WatchMind v0.9 全功能审查与上线评估

审查日期：2026-10-28（北京时间）。生产代码基线：`0c8a098`。本轮只增加审计探针、容量测量及报告，没有修复或更改App行为。

**后续状态：v0.10已修复R01–R12，原故障探针现纳入check.sh并全部通过，见[修复记录](REMEDIATION_v0.10.md)。以下失败结果为原始审查的历史证据，不代表当前仍失败；真实发布门槛仍适用。**

**结论：暂不建议公开上线。** 已逐项审查F01–F45；现有自动化基线通过，但新增负向测试复现了数据丢失、存储恢复、默认AI复盘不可用等缺陷。功能代码存在、纯Swift覆盖率高和HTML通过，都不能代替Apple编译、真机和模型供应商验收。可以继续内部开发；进入真实用户内测前先解决P1、完成原生构建与核心真机闭环。

## 1. 本轮实际执行的测试

| 检查 | 本轮结果 | 证据范围 |
| --- | --- | --- |
| `scripts/check.sh` | 通过 | 102项核心XCTest、26组实际AppModel+平台替身场景、8组实际URLSession传输回环、14项网关测试、双语 / 语法 / 空白 |
| 核心代码覆盖率 | 1334 / 1481行，90.07% | `swift test --enable-code-coverage`，仅Sources/WatchMindCore；不包含iOS / Watch、UI、AppModel替身执行或真实模型效果 |
| 中英资源审计 | 665个App键 / 每语言、4个权限键 / 每语言通过 | 文案完整性与占位符，不代表语音识别准确率 |
| 构建进度脚本 | 4项通过 | 构建工具替身，不是Xcode构建 |
| HTML v0.8 | 96组合及交互通过 | 模拟宽度 / 主题 / 字号 / 语言 / 四页；不覆盖v0.9原生AI工作台 |
| 历史HTML v0.3 | 指定系统Chromium后通过 | 历史模拟设计稿，不计入原生可用性 |
| 新增录音 / 存储负向审计 | **6项失败** | 实际AppModel与平台替身，见R01 / R02 / R03 / R11 |
| 新增AI负向审计 | **2项失败** | 实际核心时间编码、实际逐词结构与默认范围，见R04 / R06 |
| 新增健康负向审计 | **2项失败** | 实际核心同来源基线和DST窗口，见R08 / R09 |
| 新增睡眠缓存审计 | **1项失败** | 实际派生映射及AppModel刷新合并，见R10 |
| 新增额度费用审计 | **1项失败** | 实际网关+回环替身上游，见R05 |
| 容量探针 | 两组编码 / 解码往返通过 | 仅当前Linux机器纯核心JSON，不含音频、磁盘、健康集合、AI历史或设备内存验收 |
| Apple SDK编译 / 签名 / 原生UI / 真机 / 实际AI供应商 | **未执行，未通过验收** | Linux无Xcode及Apple SDK；无到Mac的执行连接，无真实模型凭据；不能以语法解析代替 |

新增审计共**12个失败的正确性检查**，不是12个独立P1；其中存储恢复与导出共属R02，非法与未来触发共属R11。另有2个UI静态问题R07 / R12。发现问题不应被既有绿色基线掩盖。

## 2. 已确认问题，按优先级排序

### R01 · P1：同一录音部分重试会覆盖已成功文字

位置：[AppModel.swift](../../iOS/AppModel.swift#L466)、[同文件结果覆盖](../../iOS/AppModel.swift#L487)。

复现：90秒同一文件，首次0–45秒成功、45–90秒失败；重试时前段失败、后段成功。期望两个已成功范围均保留，实际旧前段消失，只剩新后段。已有绿色测试只覆盖另一文件失败 / 整文件抛错，没有覆盖同文件不同分块部分失败。

补齐：按文件和成功时间区间合并；只有本次成功识别的区间可以替换旧结果，失败区间保留旧证据并明确状态。把此用例提升为常规回归，验证高光 / 记忆确认不会因此被错误撤销。

### R02 · P1：一次临时写盘失败后永久锁死，且无法导出抢救

位置：[写入异常](../../iOS/AppModel.swift#L217)、[恢复提前退出](../../iOS/AppModel.swift#L174)、[导出依赖可写](../../iOS/AppModel.swift#L678)。

复现：替身模拟磁盘写入失败，随后恢复存储、回前台；`canWriteArchive`仍为false，内存档案导出仍失败。错误提示让用户不要退出，却没有恢复保存或只读抢救路径。

补齐：区分“档案无法解码 / 不安全覆盖”和“暂时无法写入”；保留dirty快照、显式重试、恢复后持久化；只要已安全加载，允许独立于可写状态导出内存文字档案。必须测试磁盘满、临时I/O、锁定和坏档案四类状态，不能统一强行恢复覆盖。

### R03 · P1：删除音频与档案更新没有持久事务

位置：[单条删除](../../iOS/AppModel.swift#L692)、[全部清除](../../iOS/AppModel.swift#L703)。

复现：替身模拟音频删除成功后，下一次档案写入失败。持久档案仍引用已删除音频，重新启动无法恢复原一致状态。实际替身结果为`audio-deleted=true, durable-reference=true`。原子写JSON不能保证多个音频与元数据一起原子删除。

补齐：先持久化删除意图 / 墓碑，随后幂等删文件，最后完成引用清理；进程终止 / 半数删除失败 / 元数据写盘失败都应恢复。同类清理已有pending机制，可提炼复用，但要覆盖关联复盘 / 标记 / 高光与保留记忆的实际删除范围。

### R04 · P1：默认五分钟AI复盘会拒绝普通逐词语音

位置：[五分钟默认](../../iOS/AIReviewViews.swift#L183)、[逐词转写](../../iOS/AudioCapture.swift#L171)、[24000字符限制](../../Sources/WatchMindCore/AIReview.swift#L158)。

复现：按实际Speech逐词结构生成120词/分钟，附每5秒一个心率点。30秒输入约8258字符，60秒约15980字符；120秒和默认300秒直接`tooMuchEvidence`。这不是用户极端大输入，而是常规语音与默认设置不匹配。

补齐：连续词按真实时间和空档合并成句段，使用紧凑且可预览的证据协议；按模型上下文预算做分批 / 分层分析，或在选段前显示明确可分析容量。不能静默删词、填补空档或只分析开头却展示全段成功。增加正常中英五分钟 / 十分钟、多人短句、密集心率的端到端用例。

### R05 · P1（公开免费额度服务时）：成功次数不限制付费尝试成本

位置：[上游失败退款路径](../../server/gateway.py#L287)。

复现：每日成功结果限额2，替身上游每次已执行但返回无效内容，连续10次均502、上游调用10次、无429。现有行为符合“只计成功结果”的文档，但缺少公开运营需要的独立尝试费用保护。真实上游可能照常计费；并发上限不能防止顺序刷请求。

补齐：成功额度和计费尝试预算分开，增加每账号 / 来源速率与每日尝试限制、上游费用上限、熔断、告警和撤销；根据付费尝试而非结果格式控制最坏成本。**此项不阻止仅使用用户自备Key的首发范围，但阻止把当前网关直接公开为免费服务。**

### R06 · P2：0.1秒选段在发送时丢失精度

位置：[证据时间编码](../../Sources/WatchMindCore/AIReview.swift#L170)。

复现：选择同一秒内0.1–0.2秒，`.iso8601`编码后start/end都成为同一整秒字符串；预览及实际发送均丢失小数。内存范围正确不等于模型收到正确范围。

补齐：统一毫秒ISO8601或数值epoch，验证序列化 / 解码精度、跨秒边界和时间引用。示例输入必须标明模拟，不能将原始探针日期当作真实健康记录。

### R07 · P2：选段滑块读取值可能超出自己的范围

位置：[两个Slider Binding](../../iOS/AIReviewViews.swift#L174)。

代码验证：开始getter最大为length，Slider上限却是length−0.1；结束getter最小0，而下限是0.1。DatePicker可以直接将时间改到源录音边界外，绕过setter约束。原生警告 / 错位 / 崩溃表现未在Apple平台实测，不应先声称必然崩溃。

补齐：选择状态的统一约束模型，getter/setter使用相同边界；DatePicker与Slider相互同步且保留最小有效长度。补原生边界UI测试。

### R08 · P2：事件显著度混合设备来源基线

位置：[ContextAlgorithm.baseline](../../Sources/WatchMindCore/HealthContext.swift#L81)、[assess调用](../../Sources/WatchMindCore/HealthContext.swift#L103)。

复现：Watch历史HRV一直50ms，当前仍50ms；加入另一来源历史200ms。相同心率120 / 基线100的事件，显著度从55.17升至68.97、权重覆盖0.87，跨过65阈值，变成紫色重要事件。变化来自混合来源，不是本人相对该设备的HRV变化。

补齐：统一使用与当前reading可比的稳定来源标识；不能只依赖易重名的显示名。趋势页和AI已做部分来源保护，应统一共用基线策略，并测试换设备 / 多App写入。

### R09 · P2：14天历史窗口使用秒数，DST时越过日历边界

位置：[核心基线](../../Sources/WatchMindCore/HealthContext.swift#L81)、[趋势窗口](../../Sources/WatchMindCore/HealthReview.swift#L24)。

复现：America/New_York的2026-03-16回看14个日历日，固定减14×86400秒会纳入3月1日23:30（第15个日历日）；4个有效历史日加这个越界样本就错误满足至少5天。

补齐：用指定Calendar按.day减14，所有查询、保留、趋势 / AI基线统一“日历日”和“固定时长”的语义。补春秋DST、跨午夜与更换时区。

### R10 · P2：睡眠估算更新后保留旧半夜结果，污染基线

位置：[睡眠派生ID](../../iOS/HealthSource.swift#L118)、[刷新合并](../../iOS/AppModel.swift#L539)。

复现：同5夜先同步4小时，再同步完整8小时；结束时间改变会生成不同ID，合并保留10条估算。实际基线75，而每夜完整结果均100，预期基线100。SleepScorer自身的区间去重不等于缓存派生版本去重。

补齐：睡眠会话 / 夜间稳定ID与版本替换，或对本次查询覆盖的派生结果整体重算替换；不要把原始样本通用追加策略用于可修正派生数据。补缺失后补齐、删除原始睡眠与多来源同步。

### R11 · P2：重要Watch触发在验证前进入曲线和关联事件

位置：[accept前置分支](../../iOS/AppModel.swift#L276)、[Watch接收](../../iOS/WatchReceiver.swift)。

复现：活跃录音期间，超范围心率仍成为关联事件；另一个未来120秒的触发进入关联事件和曲线。验证在CaptureGate，但当前分支先写曲线和link后提前返回。后续`Int(bpm)`展示对极大数另有溢出风险（未做原生崩溃验收）。

补齐：在任何副作用前统一校验有限数值、合理范围、baseline、时间、会话和重复；实时触发与允许展示的历史数据走不同路径。不是让未来 / 错误值先存下来再由UI过滤。

### R12 · P2：健康拼图触控和VoiceOver信息不足

位置：[拼图按钮](../../iOS/WellbeingViews.swift#L106)。

代码验证：12列按钮仅16pt高；无障碍标签只有时间和心率点数，没有活动 / 心率 / 未知状态。读屏无法获知颜色代表的主要信息；视觉上正确不等于可操作。

补齐：最小44pt交互区域或等效可访问列表 / 分组导航、明确状态和来源标签、选择状态；真机VoiceOver和大字号验收。

## 3. F01–F45逐项测试 / 审查矩阵

“基线通过”只指下列指定层次。“原生待验收”贯穿所有UI / HealthKit / Watch / 音频功能，不用核心测试补作通过。

| 功能 | 代码 / 自动化证据 | 本轮结论与补充验收 |
| --- | --- | --- |
| F01 今天页 | DashboardSummaryTests、DashboardViews静态；HTML参考 | 日计数 / 最近来源核心通过；真实状态切换、VoiceOver原生待测 |
| F02 虚拟形象 | AvatarHealthCategoryTests、AvatarViews静态 | 旧配置 / 边界通过；绘制 / 保存 / 大字原生待测 |
| F03 观察权限 | CaptureGateTests、LifecycleTests、AppModel替身 | 会话令牌 / 前台规则核心通过；真实授权期间取消、HealthKit / 麦克风拒绝与撤销待测 |
| F04 Watch步行 | LifecycleTests、Watch静态 | 生命周期核心通过；运动保存 / 配对 / 断连 / 真实耗电待测 |
| F05 心率触发 | CoreTests、CaptureGateTests、录音负向探针 | 核心阈值基线通过；接收分支R11失败 |
| F06 录音时限 | RecordingTimelineTests、RecordingRecoveryTests | 1–1440分钟 / 截止时间核心通过；长录音与空间不足实测缺失 |
| F07 中断续录 | RecordingRecoveryTests、26组替身中相关场景 | 状态机通过；来电 / 音乐 / 蓝牙 / 锁屏需真机 |
| F08 本地转写 | 多文件替身场景、AudioCapture静态、负向探针 | **R01失败**；无逐45秒耐久检查点 / 可取消继续；Speech质量与长音频待测 |
| F09 心率曲线 | RecordingTimelineTests、HealthViews静态 | 降采样 / 断线核心通过；真实Charts点按、R11污染待修 |
| F10 录音定位 | RecordingTimelineTests、JournalNavigationTests | 片段 / 空档定位核心通过；AVAudioPlayer停止 / 跨路由待测 |
| F11 健康指标 | HealthContextTests、HealthSource静态 | 单位 / 有效范围基线通过；真实设备 / 地区 / 许可 / 同步待测；R10 |
| F12 多指标算法 | HealthContextTests、健康负向探针 | **R08 / R09失败**，需统一来源 / 时区 |
| F13 睡眠估算 | SleepScorerTests、睡眠缓存负向探针 | 区间 / 来源 / 主睡眠核心通过；**派生缓存R10失败** |
| F14 时间线与感受 | CoreTests、Views静态 | 数据 / 反馈路径审查；真实列表编辑 / 删除UI待测 |
| F15 文字线索 | NegationTests、CoreTests | 中英 / 否定 / 词线索基线通过；不等于情绪模型准确率 |
| F16 每日摘要 | CoreTests、IntegratedJournalTests、AppModel替身 | 规则与证据缓存通过；Apple模型质量 / 容量待测 |
| F17 双语 | LocalizationTests、资源审计 | 665键及占位符通过；原生VoiceOver / 截断 / Speech语言待测 |
| F18 模拟模式 | IntegratedJournalTests、DashboardSummaryTests、AppModel替身 | 真实 / 模拟数据隔离基线通过；原生进出模式待测 |
| F19 文件与删除 | DeferredWriterTests、AppModel替身、录音负向探针 | 锁定延后基线通过；**R02 / R03失败**；实际文件保护待测 |
| F20 构建 | test_setup_progress.py 4项、Swift语法、CI静态 | 工具替身通过；无本次Apple编译 / CI通过记录 |
| F21 人工标记 | JournalNavigationTests、AppModel替身 | 时间锚点 / 备注 / 引用基线通过；实际播放与触觉待测 |
| F22 处理中心 | ProcessingStage、JournalNavigationTests、替身 | 状态区分基线通过；长转写取消 / 恢复 / 真机连接待补 |
| F23 小时导航 | JournalNavigationTests | 午夜 / 重复小时 / 半小时DST通过；原生跳转待测 |
| F24 高光 | IntegratedJournalTests、AppModel替身 | 原话收藏 / 确认 / 来源撤销通过；R01会影响旧高光，需回归 |
| F25 本地检索 | IntegratedJournalTests | 分词 / 重音 / 空档 / 人物过滤基线通过；大档案搜索性能待测 |
| F26 回顾反思 | IntegratedJournalTests、AppModel替身 | 人工依据 / 缓存失效 / 独立反思通过；模型与原生编辑待测 |
| F27 来源记忆 | IntegratedJournalTests、AppModel替身 | 源更改 / 删除后停用通过；需让用户明确停用记忆文本仍保留 |
| F28 人物 | IntegratedJournalTests、AppModel替身 | 手动关联 / 删除保留源通过；不包含声纹验收 |
| F29 声音分类 | IntegratedJournalTests、替身 | 未知 / 阈值 / 人工窗口保护核心通过；SoundAnalysis准确率待测 |
| F30 音频清理 | IntegratedJournalTests、多个AppModel替身 | 完整成功 / 清理意图 / 失败保留通过；实际FS / 断电待测；别混同R03普通删除 |
| F31 覆盖区间 | Coverage、IntegratedJournalTests | 并集 / 当天交集 / 缺分母通过；不代表全天情绪覆盖 |
| F32 资源预算 | AppModel低功耗替身、静态 | 开始前延后通过；真实热状态 / 电量 / 长任务调度待测 |
| F33 信号拼图 | IntegratedJournalTests、HealthReview静态 | 缺失 / 日长核心通过；R12可访问性不足 |
| F34 趋势与安排 | IntegratedJournalTests、健康 / 睡眠负向探针 | 单来源保护部分通过；R09 / R10失败，建议依赖错误基线需回归 |
| F35 小调整计划 | AppModel替身、WellbeingViews静态 | 单活跃 / 结果 / 结束 / 删除通过；原生表单待测 |
| F36 首页摘要 | DashboardSummaryTests | 今日 / 所有者 / 最近来源 / 模拟隔离通过；原生交互待测 |
| F37 视觉可访问性 | 96组合模拟HTML、原生静态 | HTML通过不覆盖原生；R12与真机大字 / VoiceOver待办 |
| F38 导航 | 原生静态、模拟HTML | 无XCUITest或原生导航运行记录；补四Tab / 深层返回 / Sheet / 活跃录音回归 |
| F39 AI选段 | AIReviewTests、AI负向探针、UI静态 | 基础隔离通过；**R04失败、R06 / R07缺陷**；模型质量待联调 |
| F40 模型密钥 | 8组实际网络回环、AIReviewTests、AIService静态 | 网络边界通过；Keychain / Apple系统模型 / ATS本机 / 真实供应商未测 |
| F41 复盘存储 | 5组新增AppModel场景、容量探针 | 正常快照 / 删除 / 上限 / 导出通过；R02 / R03故障路径失败；无完整恢复 |
| F42 信号分类 | AvatarHealthCategoryTests、HealthContextTests、静态 | 分类覆盖通过；辅助选择真实后续事件待测，R08 / R09关联 |
| F43 多类人物 | AvatarHealthCategoryTests、AvatarViews静态 | 兼容 / 调色边界通过；三类绘制与辅助功能待原生验收 |
| F44 额度网关 | server14项、额度负向探针 | 基本限额 / 鉴权通过；**R05公开运营阻断**，服务未部署 |
| F45 发布隐私 | manifest / project / Settings静态、现有发布清单 | 缺AppIcon、用户可访问正式政策 / 支持、原生验收 / Archive / TestFlight与供应商合规材料 |

## 4. 存储与长时间运行的实测 / 能力缺口

容量脚本测的是当前Linux机器、链接当前核心对象、优化探针执行的JSON序列化。一次采样，不设虚构设备性能阈值；不含音频 / 磁盘 / 健康集合 / AI历史，也没有测iPhone内存峰值。

| 合成资料 | JSON大小 | 编码 | 解码 |
| --- | --- | --- | --- |
| 7天，每天30分钟，25200个Speech词段，60000心率点 | 5,779,805字节 | 413.4ms | 263.3ms |
| 30天，每天60分钟，216000个词段，60000心率点 | 18,708,205字节 | 1384.2ms | 660.1ms |

[LocalStore.save](../../iOS/LocalStore.swift#L34)同步编码整个档案，由MainActor的AppModel调用；这说明全量重写需要优化和设备性能门槛，不可直接声称iPhone会卡顿相同时间。先解决可恢复写入 / 删除事务，再评估分库、增量 / 后台持久化、查询分页与有界索引，迁移必须带校验、回退和故障恢复。

其余首发能力缺口：

- **转写任务**：逐45秒持久检查点、暂停 / 取消 / 继续、进度与处理范围；目前只在整个原文件结束后保存。正常1小时单文件中途终止，会丢失尚未落盘的全部转写工作，音频仍可重试。
- **存储不足**：采集前及运行中的可用空间门槛、低空间提示与可靠停止；音频和临时分段所需余量、孤儿文件清理 / 保留规则；不能在磁盘满后只显示永久不可恢复错误。
- **数据恢复**：当前只有文字JSON导出，不能恢复音频 / 全档案；需完成本地加密完整备份及验证恢复，或明确将无恢复列为首发限制并做好抢救导出。账号与云同步不是本机产品上线的必要条件。
- **AI证据语义**：增加单位、聚合窗口、估算标识，明确近5分钟步数 / 能量不能相加作日总量、睡眠分不是Apple官方分；保存非敏感服务端点快照，便于用户追溯自定义接口。没有调用真实模型证明解读质量，不能补出意图 / 情绪准确率。
- **录音入口与传感器限制**：真实路径仍依赖前台心率触发；手表高频心率仅来自真实步行会话，普通采样可能无法及时触发。建议补独立手动录音及无手表的可用路径，明确等待原因 / 数据新鲜度；不要用虚假全天运动实现常驻。
- **端侧模型**：Apple系统模型就绪 / 上下文上限需真机验证；第三方模型下载和本地推理引擎仍未实现，不作为已支持功能宣传。若首发限定Apple或用户自备Key，不必先完成所有模型路线。

## 5. 上线前必须完成的顺序

1. **修复关键数据与默认流程**：R01–R04优先，故障探针转绿并提升至常规CI；R06–R12同步修复并回归受影响摘要 / 高光 / 趋势。R05在公开免费服务前解决；未解决时不开放运营额度。
2. **建立Apple验收流水线**：Mac完整SDK构建两端、实际Archive / Validate；增加原生XCTest / XCUITest目标，覆盖权限、四Tab、选段、配置密钥、导出、空态和失败反馈。CI文件存在不等于本次已经构建通过。
3. **配对真机测试**：真实中文 / 英文、1分钟 → 90秒 → 1小时 → 用户设置的更长时限，来电 / 音乐 / 蓝牙 / 锁屏 / 后台 / 终止 / 低空间；测电量 / 温度 / 内存 / 数据完整性；Apple模型、Speech、SoundAnalysis、HealthKit均有证据后才能对外承诺。
4. **实际AI接口与质量评估**：非私密中英样本验证目标模型 / 端点 / 密钥 / 取消 / 计费，建立有时间引用的人工核对集，检查原话忠实性、缺失 / 否定 / 讽刺、不得推断他人真实意图。质量目标按产品场景定义，不能以单元测试代替。
5. **商店材料和用户信任**：补正式AppIcon资源；实际主体 / 隐私政策 / 支持联系的App入口及公开URL；供应商留存 / 训练 / 地区政策、录音知情 / 健康外发 / 删除范围、App Store隐私标签 / 年龄等级 / 正式截图 / 审核说明。仓库没有这些真实运营信息，不能代填。
6. **受控TestFlight**：完成上述适用阻断项再交付内测，收集用户同意下的可导出诊断（无录音 / 正文 / 密钥）、可追踪缺陷与回滚；费用、支持和隐私运营就绪后再公开。第三方下载模型、社交身份识别、云账号不应挤占本轮可靠性修复。

## 6. 可复现命令与审计约定

常规基线（当前通过）：

```sh
SWIFT_BIN=/path/to/swift ./scripts/check.sh
python3 scripts/tests/test_setup_progress.py
node scripts/check-design-preview.cjs
```

新增审计（当前故意保持红色，因为断言的是正确产品行为；不在check.sh内，也没有把缺陷当作预期成功）：

```sh
SWIFT_BIN=/path/to/swift python3 scripts/tests/review-capture-regressions.py
SWIFT_BIN=/path/to/swift python3 scripts/tests/review-ai-regressions.py
SWIFT_BIN=/path/to/swift python3 scripts/tests/review-health-regressions.py
SWIFT_BIN=/path/to/swift python3 scripts/tests/review-sleep-cache-regression.py
python3 scripts/tests/review-quota-budget-regression.py
```

这些命令现应返回1及具体FAIL；编译 / 工具错误不算缺陷复现，需要确认输出是预期的失败断言。修复后应返回0并进入常规回归，不能只删除探针或将失败列为允许。

```sh
SWIFT_BIN=/path/to/swift python3 scripts/tests/measure-archive-capacity.py
```

容量结果仅合成资料与当前机器；脚本不接触私人资料。全部新探针不调用真实模型，不花费上游额度，不检查或输出真实密钥。Apple / 真机缺失证据仍按[设备计划](../Device_Test_Plan.md)和[发布清单](../RELEASE_READINESS.md)完成。
