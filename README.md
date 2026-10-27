# WatchMind

端侧优先的 Apple Watch＋iPhone 身心记录原型：**心率小幅波动 → 可配置录音 → 本地转写 → 本人确认 → 每日回顾**。

**当前全部功能、验收条件与后续优化统一维护在 [功能文档](docs/FUNCTIONAL_SPEC.md)。**

## 先看 UI

- [界面设计图](docs/UI-preview.png)（v0.3 视觉参考，未覆盖新版人物、曲线和续录界面）
- [可交互设计预览 HTML](docs/ui-preview.html)：下载后用浏览器打开，全部为模拟数据，不录音、不连接传感器。原生运行效果需通过 Xcode 验收。

## 当前实现

- 原生 SwiftUI 四页手机界面、Watch 步行观察界面与明确标识的模拟数据模式。
- 可测试的心率波动检测：个人短期基线、升降触发、旧数据拒绝、冷却和跨设备事件去重。
- 手机前台且用户开启观察时，小幅变化触发录音；上限1分钟至24小时，默认60分钟；预设与小时 / 分钟自定义。按45秒片段本地转写，保留原始时间轴和部分失败状态。
- 可定制的本地虚拟人物：名称、发型 / 发色、肤色、服装颜色与眼镜 / 耳机，展示在首页和回顾页。
- 来电、锁屏和切后台时暂停并保留片段，符合条件时尝试续录；提供手动继续与结束转写，保留中断空档。
- 实际心率曲线、近期基线、大幅变化与多指标重要点；点击关联录音，从标记位置播放。
- 血氧、HRV、步数、环境/耳机音暴露、活动能量、睡眠腕温，以及本地睡眠估算分；显示来源、更新时间、缺失与过期。
- 心率必要触发＋可解释的多指标显著度，按各标记附近20秒实际文字生成回顾，不据此诊断情绪或疾病。
- 设备支持时使用 Apple FoundationModels 端侧摘要；否则提供明确标注的规则摘要，无云端接口。
- 本地文件保护、模拟/真实记录分离、录音状态、逐条/整体删除和异常中断处理。

**这是待真机验收的原生工程，不是已经验证可全天运行的产品。** 心率波动不能确定情绪；不预录就没有波动前的谈话。普通心率采样可能稀疏，后台不能保证自动开启麦克风。手机前台、权限和本次会话同意是录音前提。手表运动模式仅用于真实步行，会保存运动记录。

## 中文 / English

手机“设置 → 语言 / Language”支持“跟随系统、简体中文、English”，选择会保留并同步到可连接的 Watch。手表也提供语言选项。跟随系统按各设备的系统偏好解析，不支持的语言回退到英文。

界面、状态、感受标签和规则摘要支持中英文。新录音使用所选语言的离线识别（中文 zh-CN / 英文 en-US），音频保留语言信息，重试不会因后来切换界面语言而改用另一种语言。旧版录音按原来的中文识别。旧转写不会自动翻译；摘要切换语言后需重新生成。录音、转写、授权和摘要任务进行中暂不能切换手机语言。

权限说明提供两种资源，但系统权限弹窗与系统错误的语言由 iOS/watchOS 的系统或单独 App 语言设置决定，应用内切换不会强制改变系统弹窗。

The app supports Simplified Chinese, English, and following the system language. Choose a language in Settings → Language. New recordings use on-device recognition for that language; retries retain the recording's original language. Private transcripts are not automatically translated. Regenerate a summary after changing language. No cloud fallback is used.

## 在 Apple Silicon Mac（用户设备为 M3 Pro）上运行

需要兼容的完整 Xcode、iOS 17+/watchOS 10+设备与可用签名能力。端侧大模型需要 Xcode 26+ SDK 和运行时模型支持；不满足时仍可运行规则摘要。

```bash
git clone https://github.com/dunkle/watch_health.git
cd watch_health
./scripts/setup-mac.sh
open WatchMind.xcodeproj
```

构建脚本显示5个阶段：检查 Xcode、准备 XcodeGen、生成工程、核心测试、原生编译。每阶段显示耗时；长任务每15秒显示仍在运行。进度条表示已完成阶段数，**不代表 Xcode 编译百分比**。错误输出与退出码保留，失败不会显示完成。原生构建的完整输出保存在已忽略的 `.build-logs/` 目录；失败时脚本会直接摘出首条 `error:` 及附近内容。

为两个 target 设置自己的 Team、唯一 Bundle ID 及匹配的 Watch companion ID，再运行到配对 iPhone 和 Watch。详细步骤与验收：[真机运行计划](docs/Device_Test_Plan.md)。没有后端、云模型或 API Key 配置。

## 在 Linux 或 Mac 检查核心

Linux x86_64 云环境可运行 `./scripts/setup-linux.sh` 安装经签名验证的 Swift 6.0.3。已安装 Swift 6.0+ 时：

```bash
./scripts/check.sh
```

该脚本运行真正的核心单元测试、双语资源审计、AppModel 平台替身流程验证、Swift 语法检查与空白检查。**语法检查不等于 Apple SDK 类型检查。** GitHub Actions 配置了 Mac 上的核心测试与无签名 iPhone/Watch 模拟器构建；结果以实际 Actions 记录为准。

## 文档

- [完整功能文档（v0.5，持续维护）](docs/FUNCTIONAL_SPEC.md)
- [v0.4 历史规格：长录音、曲线与多指标](docs/PRD_v0.4_MultiSignal.md)
- [v0.3 初版目标：心率与语音](docs/PRD_v0.3_Heart_Voice.md)
- [v0.2 长期产品 PRD](docs/WatchMind_PRD_v0.2.md)
- [真机安装与验收](docs/Device_Test_Plan.md)
- [验证记录](docs/Validation.md)

## 工程结构

`Sources/WatchMindCore`：纯 Swift 检测、模型与证据逻辑；`Tests`：可在 Linux 运行的测试；`iOS`：传感器、音频、转写、摘要和手机界面；`Watch`：真实步行会话与事件传输；`project.yml`：XcodeGen 工程定义。

睡眠分为本地时长/效率估算，非Apple官方评分；音暴露为HealthKit可读记录，不是持续监听。血氧/HRV/腕温等可能稀疏或不可用。长录音仍要求前台；锁屏 / 来电 / 切后台会暂停，系统允许、解锁且回到前台时尝试恢复，否则手动继续。24小时是可选时限，包含中断等待，不是持续运行保证；耗电、空间和转写等待会增加。

本版本尚无备份恢复。音频由用户主动删除；卸载可能丢失所有本地记录。系统杀进程或重新启动后不会自动开麦；已存片段可重试转写。
