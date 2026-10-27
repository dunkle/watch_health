import SwiftUI
import WatchMindCore

struct RecordingDurationView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.locale) private var locale
    private var l: Localizer { Localizer(locale: locale) }
    private var locked: Bool { model.busy || model.observing || model.consenting }
    var body: some View {
        Form {
            Section(l("常用时长")) {
                ForEach([15, 30, 60, 120, 240, 480, 720, 1440], id: \.self) { minutes in
                    Button { model.recordingMinutes = minutes } label: {
                        HStack {
                            Text(minutes < 60 ? l("\(minutes) 分钟") : l("\(minutes / 60) 小时"))
                            Spacer()
                            if model.recordingMinutes == minutes { Image(systemName: "checkmark") }
                        }
                    }.disabled(locked)
                }
            }
            Section(l("自定义时长")) {
                Picker(l("小时"), selection: Binding(get: { model.recordingMinutes / 60 }, set: { value in
                    model.recordingMinutes = RecordingPolicy.minutes(value * 60 + (value == 24 ? 0 : model.recordingMinutes % 60))
                })) { ForEach(0...24, id: \.self) { Text(l("\($0) 小时")).tag($0) } }
                Picker(l("分钟"), selection: Binding(get: { model.recordingMinutes % 60 }, set: { value in
                    model.recordingMinutes = RecordingPolicy.minutes(model.recordingMinutes / 60 * 60 + value)
                })) { ForEach(0...59, id: \.self) { Text(l("\($0) 分钟")).tag($0) } }
                    .disabled(locked || model.recordingMinutes == RecordingPolicy.maximumMinutes)
                Text(l("当前上限：\(model.recordingMinutes) 分钟"))
            }.disabled(locked)
            Section {
                Text(l("默认1小时，可选1分钟至24小时。中断等待计入本次时限；恢复不会重新计时，24小时不是持续录音保证。"))
                Text(l("24小时音频按64kbps估算约0.7GB，转写另需时间和临时空间。空间不足或系统限制可能提前停止。"))
                Text(l("音乐允许时可共存；来电或其他独占音频仍可能打断。耳机断开后需确认并手动继续，避免悄悄更换录音场景。"))
            }.font(.caption).foregroundStyle(.secondary)
        }.navigationTitle(l("最长录音时间"))
    }
}
