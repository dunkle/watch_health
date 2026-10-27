import SwiftUI
import WatchMindCore

struct AvatarView: View {
    @Environment(\.locale) private var locale
    let configuration: AvatarConfiguration
    var size: CGFloat = 120
    private var skin: Color { [Color(red: 1, green: 0.86, blue: 0.72), Color(red: 0.89, green: 0.67, blue: 0.48),
                               Color(red: 0.65, green: 0.43, blue: 0.29), Color(red: 0.39, green: 0.25, blue: 0.20)][min(3, max(0, configuration.skin))] }
    private var outfit: Color { [Color.teal, .indigo, .orange, .pink][min(3, max(0, configuration.outfit))] }
    private var hair: Color { [Color(red: 0.20, green: 0.17, blue: 0.16), Color.brown, Color(red: 0.79, green: 0.61, blue: 0.32), Color.gray][min(3, max(0, configuration.hairColor))] }
    var body: some View {
        ZStack {
            Circle().fill(outfit.opacity(0.12))
            if configuration.hair == .bob {
                RoundedRectangle(cornerRadius: 26).fill(hair).frame(width: 65, height: 76).offset(y: -8)
            }
            Capsule().fill(skin).frame(width: 14, height: 25).rotationEffect(.degrees(25)).offset(x: -30, y: 32)
            Capsule().fill(skin).frame(width: 14, height: 25).rotationEffect(.degrees(-25)).offset(x: 30, y: 32)
            RoundedRectangle(cornerRadius: 23).fill(outfit).frame(width: 57, height: 46).offset(y: 34)
            Capsule().fill(skin).frame(width: 16, height: 24).offset(y: 10)
            Circle().fill(skin).frame(width: 57, height: 61).offset(y: -13)
            Ellipse().fill(hair).frame(width: 61, height: configuration.hair == .short ? 26 : 30).offset(y: -36)
            if configuration.hair == .curls {
                ForEach(0..<5) { index in
                    Circle().fill(hair).frame(width: 24, height: 24)
                        .offset(x: CGFloat(index - 2) * 12, y: -38 - (index % 2 == 0 ? 0 : 5))
                }
            }
            HStack(spacing: 18) {
                Capsule().fill(Color.black.opacity(0.75)).frame(width: 4, height: 6)
                Capsule().fill(Color.black.opacity(0.75)).frame(width: 4, height: 6)
            }.offset(y: -13)
            Path { path in
                path.move(to: CGPoint(x: 53, y: 57))
                path.addQuadCurve(to: CGPoint(x: 67, y: 57), control: CGPoint(x: 60, y: 65))
            }.stroke(Color.black.opacity(0.6), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            if configuration.accessory == .glasses {
                HStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 5).stroke(.black.opacity(0.7), lineWidth: 2).frame(width: 23, height: 17)
                    RoundedRectangle(cornerRadius: 5).stroke(.black.opacity(0.7), lineWidth: 2).frame(width: 23, height: 17)
                }.offset(y: -13)
            } else if configuration.accessory == .headphones {
                RoundedRectangle(cornerRadius: 30).trim(from: 0.45, to: 1)
                    .stroke(outfit, lineWidth: 5).frame(width: 67, height: 65).offset(y: -17)
                HStack { Capsule().fill(outfit).frame(width: 9, height: 24); Spacer(); Capsule().fill(outfit).frame(width: 9, height: 24) }
                    .frame(width: 72).offset(y: -12)
            }
            Image(systemName: "leaf.fill").font(.system(size: 13)).foregroundStyle(.white.opacity(0.9)).offset(y: 34)
        }.frame(width: 120, height: 120).clipShape(Circle())
            .scaleEffect(size / 120).frame(width: size, height: size)
            .accessibilityLabel(Text(Localizer(locale: locale)("虚拟人物形象")))
    }
}

struct AvatarSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.locale) private var locale
    private var l: Localizer { Localizer(locale: locale) }
    var body: some View {
        Form {
            Section {
                HStack { Spacer(); AvatarView(configuration: model.avatar, size: 160); Spacer() }.padding(.vertical)
                TextField(l("给形象取个名字"), text: $model.avatar.name)
                    .onChange(of: model.avatar.name) { _, name in
                        if name.count > 20 { model.avatar.name = String(name.prefix(20)) }
                    }
                Text(l("形象保存在本机，用于陪伴展示；表情不代表系统识别出了你的心情。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(l("外观")) {
                Picker(l("发型"), selection: $model.avatar.hair) {
                    Text(l("短发")).tag(AvatarConfiguration.Hair.short)
                    Text(l("齐耳发")).tag(AvatarConfiguration.Hair.bob)
                    Text(l("卷发")).tag(AvatarConfiguration.Hair.curls)
                }
                Picker(l("配饰"), selection: $model.avatar.accessory) {
                    Text(l("无配饰")).tag(AvatarConfiguration.Accessory.none)
                    Text(l("眼镜")).tag(AvatarConfiguration.Accessory.glasses)
                    Text(l("耳机")).tag(AvatarConfiguration.Accessory.headphones)
                }
                swatches(l("肤色"), selection: $model.avatar.skin,
                         colors: [Color(red: 1, green: 0.86, blue: 0.72), Color(red: 0.89, green: 0.67, blue: 0.48),
                                  Color(red: 0.65, green: 0.43, blue: 0.29), Color(red: 0.39, green: 0.25, blue: 0.20)])
                swatches(l("发色"), selection: $model.avatar.hairColor, colors: [.black, .brown, .yellow, .gray])
                swatches(l("服装颜色"), selection: $model.avatar.outfit, colors: [.teal, .indigo, .orange, .pink])
            }
            Button(l("恢复默认形象")) { model.avatar = AvatarConfiguration() }
        }.navigationTitle(l("我的虚拟形象"))
    }
    private func swatches(_ title: String, selection: Binding<Int>, colors: [Color]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
            HStack(spacing: 18) {
                ForEach(colors.indices, id: \.self) { index in
                    Button { selection.wrappedValue = index } label: {
                        Circle().fill(colors[index]).frame(width: 32, height: 32)
                            .overlay { if selection.wrappedValue == index { Image(systemName: "checkmark").foregroundStyle(.white).shadow(radius: 2) } }
                            .overlay(Circle().stroke(.gray.opacity(0.3)))
                    }.buttonStyle(.plain)
                        .accessibilityLabel(l("\(title)选项 \(index + 1)"))
                        .accessibilityAddTraits(selection.wrappedValue == index ? [.isSelected] : [])
                }
            }.padding(.vertical, 4)
        }
    }
}

struct CompanionView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.locale) private var locale
    private var l: Localizer { Localizer(locale: locale) }
    var body: some View {
        HStack(spacing: 18) {
            AvatarView(configuration: model.avatar, size: 94)
            VStack(alignment: .leading, spacing: 8) {
                Text(model.avatar.name.isEmpty ? l("你的记录伙伴") : model.avatar.name).font(.headline)
                Text(model.recordingPaused ? l("记录暂歇，回来后可以继续。") : model.recordingID != nil ? l("正在为你留住此刻。") : l("一起慢慢了解你的日常。"))
                    .font(.subheadline).foregroundStyle(.secondary)
                NavigationLink(l("定制我的形象")) { AvatarSettingsView() }.font(.caption.bold())
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 26))
    }
}
