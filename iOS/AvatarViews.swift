import SwiftUI
import WatchMindCore

struct AvatarView: View {
    @Environment(\.locale) private var locale
    let configuration: AvatarConfiguration
    var size: CGFloat = 120
    private let skinColors: [Color] = [Color(red: 1, green: 0.86, blue: 0.72), Color(red: 0.89, green: 0.67, blue: 0.48),
        Color(red: 0.65, green: 0.43, blue: 0.29), Color(red: 0.39, green: 0.25, blue: 0.20), Color(red: 0.97, green: 0.76, blue: 0.68), Color(red: 0.29, green: 0.19, blue: 0.16)]
    private var skin: Color { skinColors[min(5, max(0, configuration.skin))] }
    private var outfit: Color { [Color.teal, .indigo, .orange, .pink, .purple, .blue][min(5, max(0, configuration.outfit))] }
    private var hair: Color { [Color(red: 0.20, green: 0.17, blue: 0.16), Color.brown, Color(red: 0.79, green: 0.61, blue: 0.32), Color.gray, Color(red: 0.61, green: 0.28, blue: 0.19), Color.purple][min(5, max(0, configuration.hairColor))] }
    var body: some View {
        ZStack {
            Circle().fill(outfit.opacity(0.12))
            switch configuration.style {
            case .human: human
            case .cat: cat
            case .robot: robot
            }
            accessories
        }.frame(width: 120, height: 120).clipShape(Circle())
            .scaleEffect(size / 120).frame(width: size, height: size)
            .accessibilityLabel(Text(Localizer(locale: locale)("虚拟人物形象")))
    }
    private var human: some View {
        ZStack {
            if configuration.hair == .bob || configuration.hair == .long {
                RoundedRectangle(cornerRadius: 26).fill(hair)
                    .frame(width: 65, height: configuration.hair == .long ? 96 : 76).offset(y: configuration.hair == .long ? 0 : -8)
            }
            Capsule().fill(skin).frame(width: 14, height: 25).rotationEffect(.degrees(25)).offset(x: -30, y: 32)
            Capsule().fill(skin).frame(width: 14, height: 25).rotationEffect(.degrees(-25)).offset(x: 30, y: 32)
            RoundedRectangle(cornerRadius: 23).fill(outfit).frame(width: 57, height: 46).offset(y: 34)
            Capsule().fill(skin).frame(width: 16, height: 24).offset(y: 10)
            Ellipse().fill(skin).frame(width: 57, height: 61).offset(y: -13)
            if configuration.hair != .bald {
                Ellipse().fill(hair).frame(width: 61, height: configuration.hair == .short ? 26 : 30).offset(y: -36)
            }
            if configuration.hair == .curls {
                ForEach(0..<5) { index in
                    Circle().fill(hair).frame(width: 24, height: 24)
                        .offset(x: CGFloat(index - 2) * 12, y: -38 - (index % 2 == 0 ? 0 : 5))
                }
            }
            eyes
            Path { path in
                path.move(to: CGPoint(x: 53, y: 57))
                path.addQuadCurve(to: CGPoint(x: 67, y: 57), control: CGPoint(x: 60, y: 65))
            }.stroke(Color.black.opacity(0.6), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            Image(systemName: "leaf.fill").font(.system(size: 13)).foregroundStyle(.white.opacity(0.9)).offset(y: 34)
        }
    }
    private var eyes: some View {
        HStack(spacing: 18) {
            Capsule().fill(Color.black.opacity(0.75)).frame(width: 4, height: 6)
            Capsule().fill(Color.black.opacity(0.75)).frame(width: 4, height: 6)
        }.offset(y: -13)
    }
    private var cat: some View {
        ZStack {
            Ellipse().fill(outfit).frame(width: 62, height: 64).offset(y: 30)
            Image(systemName: "triangle.fill").font(.system(size: 35)).foregroundStyle(skin).rotationEffect(.degrees(-25)).offset(x: -27, y: -34)
            Image(systemName: "triangle.fill").font(.system(size: 35)).foregroundStyle(skin).rotationEffect(.degrees(25)).offset(x: 27, y: -34)
            RoundedRectangle(cornerRadius: 29).fill(skin).frame(width: 78, height: 68).offset(y: -10)
            eyes
            Image(systemName: "heart.fill").font(.system(size: 9)).foregroundStyle(.brown).offset(y: 1)
            HStack(spacing: 48) {
                Image(systemName: "line.3.horizontal"); Image(systemName: "line.3.horizontal")
            }.font(.system(size: 13)).foregroundStyle(.brown.opacity(0.6)).offset(y: 2)
            Circle().fill(Color.yellow).frame(width: 10, height: 10).offset(y: 33)
        }
    }
    private var robot: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(outfit).frame(width: 64, height: 50).offset(y: 33)
            Capsule().fill(outfit).frame(width: 5, height: 18).offset(y: -48)
            Circle().fill(outfit).frame(width: 12, height: 12).offset(y: -57)
            RoundedRectangle(cornerRadius: 21).fill(Color.gray.opacity(0.8)).frame(width: 78, height: 66).offset(y: -12)
            RoundedRectangle(cornerRadius: 15).fill(Color(red: 0.12, green: 0.20, blue: 0.23)).frame(width: 65, height: 48).offset(y: -13)
            HStack(spacing: 17) {
                RoundedRectangle(cornerRadius: 3).fill(Color.mint).frame(width: 9, height: 13)
                RoundedRectangle(cornerRadius: 3).fill(Color.mint).frame(width: 9, height: 13)
            }.offset(y: -15)
            Capsule().fill(Color.mint).frame(width: 20, height: 3).offset(y: 1)
            Image(systemName: "sparkle").font(.system(size: 18)).foregroundStyle(.white).offset(y: 33)
        }
    }
    @ViewBuilder private var accessories: some View {
        switch configuration.accessory {
        case .none: EmptyView()
        case .glasses:
            HStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 5).stroke(.black.opacity(0.7), lineWidth: 2).frame(width: 23, height: 17)
                RoundedRectangle(cornerRadius: 5).stroke(.black.opacity(0.7), lineWidth: 2).frame(width: 23, height: 17)
            }.offset(y: -13)
        case .headphones:
            ZStack {
                RoundedRectangle(cornerRadius: 30).trim(from: 0.45, to: 1)
                    .stroke(outfit, lineWidth: 5).frame(width: 86, height: 65).offset(y: -17)
                HStack { Capsule().fill(outfit).frame(width: 9, height: 24); Spacer(); Capsule().fill(outfit).frame(width: 9, height: 24) }
                    .frame(width: 88).offset(y: -12)
            }
        case .cap:
            ZStack {
                UnevenRoundedRectangle(topLeadingRadius: 23, topTrailingRadius: 23).fill(outfit).frame(width: 65, height: 25)
                Capsule().fill(outfit).frame(width: 80, height: 8).offset(x: 5, y: 12)
            }.offset(y: -41)
        }
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
            Section(l("伙伴风格")) {
                Picker(l("形象类型"), selection: $model.avatar.style) {
                    Text(l("人物")).tag(AvatarConfiguration.Style.human)
                    Text(l("小猫")).tag(AvatarConfiguration.Style.cat)
                    Text(l("机器人")).tag(AvatarConfiguration.Style.robot)
                }.pickerStyle(.segmented)
                Text(l("选择喜欢的伙伴，不绑定性别或身体状态。所有形象均由本机绘制。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(l("外观")) {
                if model.avatar.style == .human {
                Picker(l("发型"), selection: $model.avatar.hair) {
                    Text(l("短发")).tag(AvatarConfiguration.Hair.short)
                    Text(l("齐耳发")).tag(AvatarConfiguration.Hair.bob)
                    Text(l("卷发")).tag(AvatarConfiguration.Hair.curls)
                    Text(l("长发")).tag(AvatarConfiguration.Hair.long)
                    Text(l("光头")).tag(AvatarConfiguration.Hair.bald)
                }
                }
                Picker(l("配饰"), selection: $model.avatar.accessory) {
                    Text(l("无配饰")).tag(AvatarConfiguration.Accessory.none)
                    Text(l("眼镜")).tag(AvatarConfiguration.Accessory.glasses)
                    Text(l("耳机")).tag(AvatarConfiguration.Accessory.headphones)
                    Text(l("帽子")).tag(AvatarConfiguration.Accessory.cap)
                }
                if model.avatar.style != .robot {
                swatches(model.avatar.style == .human ? l("肤色") : l("毛色"), selection: $model.avatar.skin,
                         colors: [Color(red: 1, green: 0.86, blue: 0.72), Color(red: 0.89, green: 0.67, blue: 0.48),
                                  Color(red: 0.65, green: 0.43, blue: 0.29), Color(red: 0.39, green: 0.25, blue: 0.20), Color(red: 0.97, green: 0.76, blue: 0.68), Color(red: 0.29, green: 0.19, blue: 0.16)])
                }
                if model.avatar.style == .human && model.avatar.hair != .bald {
                    swatches(l("发色"), selection: $model.avatar.hairColor, colors: [.black, .brown, .yellow, .gray, .red, .purple])
                }
                swatches(l("服装颜色"), selection: $model.avatar.outfit, colors: [.teal, .indigo, .orange, .pink, .purple, .blue])
            }
            Button(l("恢复默认形象")) { model.avatar = AvatarConfiguration() }
        }.navigationTitle(l("我的虚拟形象"))
    }
    private func swatches(_ title: String, selection: Binding<Int>, colors: [Color]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 8) {
                ForEach(colors.indices, id: \.self) { index in
                    Button { selection.wrappedValue = index } label: {
                        Circle().fill(colors[index]).frame(width: 32, height: 32)
                            .overlay { if selection.wrappedValue == index { Image(systemName: "checkmark").foregroundStyle(.white).shadow(radius: 2) } }
                            .overlay(Circle().stroke(.gray.opacity(0.3))).frame(minWidth: 44, minHeight: 44)
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
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppTheme.radius))
    }
}
