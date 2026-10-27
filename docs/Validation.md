# 验证记录

日期：2026-10-26。

## 当前 Linux 实例已执行

- 从 Swift 官方发布地址下载 Swift 6.0.3；使用 swiftlang 官方网站源码仓库的公开签名密钥验证发布包的 detached GPG 签名成功，再运行工具链。
- `scripts/check.sh`：17 个 XCTest 测试执行完毕，0 失败。尾部 Swift Testing 的“0 tests”是另一测试框架的空套件，不替代前面的 XCTest 结果。
- 手机与手表的全部 Swift 文件通过 `swiftc -frontend -parse`；仅验证语法，不验证 Apple SDK 类型或链接。
- 从官方源码构建 XcodeGen 成功，并实际生成 iPhone/Watch Xcode 工程、scheme、Info.plist 与 HealthKit entitlements。
- 配置中的 plist 已使用 Python plistlib 成功解析。

## 未验证

当前 Linux 没有 Apple SDK 和 Xcode，也没有连接用户的 Mac/iPhone/Watch。因此原生类型检查与模拟器构建、真机签名安装、HealthKit 权限、运动心率交付、WatchConnectivity、自动触发录音、Speech 离线模型、Apple FoundationModels、后台中断和功耗均未在用户设备上执行。

GitHub Actions 配置提供 Mac 无签名编译检查；仅有配置文件不代表远端构建已经运行或通过。真机验证必须按 Device_Test_Plan.md 执行。

## 结果解释

这是已实现且核心已测的原生原型，不能声称“全天实时运行”或“识别情绪准确”。当前实现明确限定前台手机触发录音，不预录、不补录过期事件，不使用云接口。

## UI 设计预览

`ui-preview.html` 是纯本地、明确标注模拟数据的设计参考，不是原生运行截图。已通过 Chromium/Playwright 检查导航、片段详情、本人感受选择、摘要依据、设置和390px宽度下无横向溢出，并导出 `UI-preview.png`。截图已人工查看。浏览器交互测试不能验证原生 SwiftUI 或传感器。

CI 使用 `macos-26`，官方 runner-images 文档确认该镜像有 Xcode 26 SDK，可覆盖 FoundationModels 条件编译分支；远端执行结果仍需实际 Actions 日志确认。

工程重复生成检查：再次运行 XcodeGen 后 `project.pbxproj` 字节一致。`scripts/setup-linux.sh` 在已安装且已验证的工具链上重跑成功。XcodeGen 源码及其 checkout 位于 `/workspace/tools`，仅为生成工程的构建依赖，不是此环境的第二个产品仓库。


## 2026-10-26 复查修复

修复中断录音不释放状态、转写重试重入、旧异步回调污染新任务、Watch 保存时重新启动、观察授权完成后复活、锁屏写入失败永久禁用以及否定词误匹配。

新增 `OperationSlot`、`WorkoutLifecycle` 与 `DeferredWriter`，由真实 iPhone/Watch 适配层调用；新增15项回归测试，覆盖任务占用、取消、重复/迟到回调、运动保存阶段、锁屏/写入中途锁定/解锁刷盘、真实存储错误与中英文否定。现共32项核心 XCTest 通过，0失败。手机/手表 Swift 文件通过语法检查。

这些测试验证共享状态逻辑和文字规则，不等同于 AVAudioRecorder、Speech、HealthKit、文件保护通知在真机上的集成验证。Apple SDK 编译、实际来电/锁屏、权限弹窗和手表生命周期仍须按 Device_Test_Plan.md 回归。未取得远端 Actions 成功结果。

锁屏不会降低文件保护；待保存数据仅暂存内存，进程被终止时不能保证保留。非锁屏原因的写入失败仍保守停止采集。词语规则仅处理有限否定表达，不是可靠情绪分类器。


## 双语与构建进度更新

新增手机/Watch 的简体中文、英文、跟随系统选项，170条双语应用文案和4条双语权限说明。语音识别按录制时的语言选择 zh-CN/en-US，旧录音保留中文识别兼容；摘要按当前语言生成，原始转写不改写。

当前38项核心测试通过（增加6项本地化回归），验证语言解析、资源实际加载、动态占位符、隐私文字不被模板二次替换、英文词间空格/否定、历史录音解码。双语资源键集合、占位符和 Localizer 调用点审计通过。

Mac 构建脚本新增5阶段进度、阶段耗时、15秒心跳，保留真实命令输出和错误码。4项脚本测试在伪造工具环境中通过，覆盖成功、测试失败、编译失败与较慢 Homebrew 安装；这不代表实际 Xcode 构建成功。真实双语布局、系统权限、本地识别及 Apple 模型仍需 Mac/真机验证。


## 2026-10-27 Mac 编译诊断修复

用户的 Xcode 26.3 构建确认 AppModel.swift 的录音失败嵌套闭包隐式调用 `describe(error)` 不合法。已改为显式 `self.describe(error)`。在 Linux 使用临时 API stand-ins 的 Swift 语言级类型检查中，修复前可复现该错误，修复后该错误消失；这不是 Apple SDK 编译验证。

HealthKit 查询 handler 显式声明 `@Sendable`，样本与错误回调声明为 `@MainActor @Sendable`。在跳到主 actor 前只提取 Sendable 的心率值和错误字符串，避免跨 actor 传递 SDK 样本对象。

原生构建脚本通过 tee 保存 `.build-logs/` 完整输出，显式保留 xcodebuild 和 tee 的退出状态；失败时摘出首条 error。4项工具替身脚本测试通过，覆盖日志留存、错误提取和失败退出码；38项核心测试及双语检查通过。Apple SDK 整体重新编译结果仍需用户 Mac 验证。


## 2026-10-27 v0.4 扩展

实现默认60分钟、可设1–180分钟录音；5bpm且5%的小幅触发；独立的大幅变化检测；录音内重要标记与时间定位播放；实际心率曲线；8类健康情境指标及可解释显著度。

新增15项核心测试，目前53项通过，覆盖小时分段覆盖、独立大幅检测、同文件时间关联及跨日摘要、曲线极值与缺口、旧档案解码、多日基线、过期/未来/非法指标、活动情境、睡眠去重及效率估算。Swift语法检查和双语资源审计通过。AppModel在临时平台stand-ins下通过语言级类型检查，不等于Apple SDK构建。

新增HealthKit权限、长音频AVAsset导出、Charts点击、血氧单位换算、实际睡眠源、整小时录音/转写与能耗尚需用户Mac和真机执行。此前用户确认的原生构建成功属于旧版本，不能替代本次新代码的编译验收。

## 2026-10-27：v0.5 虚拟人物、录音恢复与24小时上限

- 新增本地2D可定制人物，首页、回顾页和设置展示；SwiftUI 语法检查与中英文资源审计通过，真实布局和重启偏好保存待模拟器 / 设备验证。
- 最长录音改为1–1440分钟，默认60分钟；常用预设与小时 / 分钟自定义。24小时对应1920个45秒转写区间，边界覆盖测试通过；未进行24小时真实音频测试。
- 核心 XCTest **59项通过，0失败**（此前53项，新增6项恢复状态、终止、权限条件、原始截止时间、手动要求、多片段空档与旧数据兼容测试；原有时长测试扩展到24小时）。
- `scripts/tests/check-appmodel.py` 对实际 AppModel 源码运行 **8组平台替身场景**：前后台续录 / 原始时限 / 旧回调 / 多文件删除、来电无 shouldResume 手动继续、有 shouldResume 仍等待前台、路由断开与激活失败、锁屏待写和解锁、暂停时结束、磁盘失败释放占用、转写重试失败保留已有文字。全部通过。
- 平台替身只替代 imports / 偏好测试域及平台类型，使用实际 AppModel 编排；通知只复制基础值并在 MainActor 处理。它不验证 AVFoundation、HealthKit 或 UIKit 的实际实现，不等同于 Apple SDK 编译或真机测试。
- 双语审计 **282个应用键 / 语言，4个权限键 / 语言**通过；所有 iOS / Watch Swift 文件语法检查通过；XcodeGen 重新生成包含新视图的工程；`git diff --check`通过。
- 上次旧版用户确认 Xcode 26.3 编译成功仍有效，但**本版新增视图、录音类别、文件时长读取和中断恢复尚未在 Mac 编译或真实设备执行**。来电 / 音乐 / 耳机的系统路由、长录音、文件保护和电量温度按最新真机计划验证。
- 当前功能统一记录于 `docs/FUNCTIONAL_SPEC.md`，F01–F20；仓库 `AGENTS.md`要求后续功能变更同步维护规格、验证与双语资源。
