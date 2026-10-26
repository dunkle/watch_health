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
