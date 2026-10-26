# WatchMind

端侧优先的 Apple Watch＋iPhone 身心记录原型：**心率波动 → 短语音 → 本地转写 → 本人确认 → 每日回顾**。

## 当前实现

- 原生 SwiftUI 四页手机界面、Watch 步行观察界面与明确标识的模拟数据模式。
- 可测试的心率波动检测：个人短期基线、升降触发、旧数据拒绝、冷却和跨设备事件去重。
- 手机前台且用户开启观察时，触发最多30秒录音；本地 Speech 转写，保留分段时间与原始音频。
- 心率事件附近文字、待确认的词语线索、本人感受标注与证据回看。
- 设备支持时使用 Apple FoundationModels 端侧摘要；否则提供明确标注的规则摘要，无云端接口。
- 本地文件保护、模拟/真实记录分离、录音状态、逐条/整体删除和异常中断处理。

**这是待真机验收的原生工程，不是已经验证可全天运行的产品。** 心率波动不能确定情绪；不预录就没有波动前的谈话。普通心率采样可能稀疏，后台不能保证自动开启麦克风。手机前台、权限和本次会话同意是录音前提。手表运动模式仅用于真实步行，会保存运动记录。

## 在 M1 Mac 上运行

需要兼容的完整 Xcode、iOS 17+/watchOS 10+设备与可用签名能力。端侧大模型需要 Xcode 26+ SDK 和运行时模型支持；不满足时仍可运行规则摘要。

```bash
git clone https://github.com/dunkle/watch_health.git
cd watch_health
./scripts/setup-mac.sh
open WatchMind.xcodeproj
```

为两个 target 设置自己的 Team、唯一 Bundle ID 及匹配的 Watch companion ID，再运行到配对 iPhone 和 Watch。详细步骤与验收：[真机运行计划](docs/Device_Test_Plan.md)。没有后端、云模型或 API Key 配置。

## 在 Linux 或 Mac 检查核心

安装 Swift 6.0+ 后：

```bash
./scripts/check.sh
```

该脚本运行真正的核心单元测试、Swift 语法检查与空白检查。**语法检查不等于 Apple SDK 类型检查。** GitHub Actions 配置了 Mac 上的核心测试与无签名 iPhone/Watch 模拟器构建；结果以实际 Actions 记录为准。

## 文档

- [v0.3 当前目标：心率与语音](docs/PRD_v0.3_Heart_Voice.md)
- [v0.2 长期产品 PRD](docs/WatchMind_PRD_v0.2.md)
- [真机安装与验收](docs/Device_Test_Plan.md)
- [验证记录](docs/Validation.md)

## 工程结构

`Sources/WatchMindCore`：纯 Swift 检测、模型与证据逻辑；`Tests`：可在 Linux 运行的测试；`iOS`：传感器、音频、转写、摘要和手机界面；`Watch`：真实步行会话与事件传输；`project.yml`：XcodeGen 工程定义。

本版本尚无备份恢复。音频由用户主动删除；卸载可能丢失所有本地记录。不会自动恢复被终止的录音会话。
