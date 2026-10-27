import SwiftUI
import WatchMindCore

struct SessionStatusBar: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.locale) private var locale
    private var l: Localizer { Localizer(locale: locale) }
    @State private var showProcessing = false
    var body: some View {
        VStack(spacing: 0) {
            if model.demoMode {
                HStack {
                    Label(l("模拟体验 · 不采集真实数据"), systemImage: "sparkles")
                    Spacer()
                    Button(l("退出")) { model.exitDemo() }.frame(minHeight: 44)
                }.font(.caption.weight(.medium)).padding(.horizontal, 20)
                    .foregroundStyle(AppTheme.warning).background(AppTheme.warning.opacity(0.10))
            }
            if let recording = model.currentRecording {
                VStack(spacing: 9) {
                    HStack(spacing: 12) {
                        Image(systemName: model.recordingPaused ? "pause.circle.fill" : "record.circle.fill")
                            .font(.title2).foregroundStyle(model.recordingPaused ? AppTheme.warning : AppTheme.recording)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.recordingPaused ? l("录音已暂停") : l("正在留住这一刻")).font(.subheadline.bold())
                            Text(l("上限 \(Int((recording.maximumDuration ?? 3600) / 60)) 分钟 · 中断计时不重置"))
                                .font(.caption).foregroundStyle(AppTheme.muted)
                        }
                        Spacer(minLength: 0)
                        Button { model.markMoment() } label: { Image(systemName: "bookmark.circle.fill").font(.title).frame(minWidth: 44, minHeight: 44) }
                            .disabled(!model.canWriteArchive).accessibilityLabel(l("标记此刻"))
                        Menu {
                            if model.recordingPaused { Button(l("继续录音")) { model.resumeRecording() } }
                            Button(l("结束并转写")) { model.stopRecording() }
                            Button(l("结束观察")) { model.stop() }
                        } label: { Image(systemName: "ellipsis.circle").font(.title2).frame(minWidth: 44, minHeight: 44) }
                            .accessibilityLabel(l("录音操作"))
                    }
                    if model.recordingPaused {
                        HStack(alignment: .top) {
                            Text(l.key(recording.note)).font(.caption).foregroundStyle(AppTheme.muted)
                            Spacer(minLength: 8)
                            Button(l("继续录音")) { model.resumeRecording() }.font(.subheadline.bold()).frame(minHeight: 44)
                        }
                    }
                    if let start = recording.captureStarted {
                        SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
                            ProgressView(value: min(max(0, context.date.timeIntervalSince(start)), recording.maximumDuration ?? 3600), total: recording.maximumDuration ?? 3600)
                                .accessibilityLabel(l("本次会话已用时间"))
                        }
                    }
                    if let id = model.lastMarkedID, let marker = model.markers.first(where: { $0.id == id && $0.recordingID == recording.id }) {
                        Text(l("已标记 \(l.date(marker.date, seconds: true)) · 可在片刻页补充备注"))
                            .font(.caption).foregroundStyle(AppTheme.accent).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(.horizontal, 20).padding(.vertical, 12).background(AppTheme.surface)
            } else if model.transcriptionID != nil {
                HStack(spacing: 12) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 4) {
                        Text(l("正在本机整理声音")).font(.subheadline.bold())
                        if model.transcriptionTotal > 0 { Text(l("当前已处理分段：\(model.transcriptionCompleted)/\(model.transcriptionTotal)")).font(.caption).foregroundStyle(AppTheme.muted) }
                    }
                    Spacer()
                    Button { showProcessing = true } label: { Image(systemName: "arrow.up.right.circle").font(.title2).frame(minWidth: 44, minHeight: 44) }
                        .accessibilityLabel(l("查看处理中心"))
                }.padding(.horizontal, 20).padding(.vertical, 12).background(AppTheme.surface)
            } else if model.storagePaused {
                Label(l("设备锁定，暂缓写入；解锁后自动重试保存。"), systemImage: "lock.fill")
                    .font(.caption).padding(12).frame(maxWidth: .infinity).background(AppTheme.warning.opacity(0.10))
            }
        }.overlay(alignment: .bottom) { if model.currentRecording != nil || model.transcriptionID != nil { AppTheme.border.frame(height: 1) } }
            .sheet(isPresented: $showProcessing) {
                NavigationStack { ProcessingCenterView().toolbar { ToolbarItem(placement: .topBarTrailing) { Button(l("完成")) { showProcessing = false } } } }
            }
    }
}

struct DashboardContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var typeSize
    let onStart: () -> Void
    let onReview: () -> Void
    private var l: Localizer { Localizer(locale: locale) }
    private var summary: DashboardSummary { .build(day: Date(), episodes: model.episodes, markers: model.markers, clips: model.journal.clips, isDemo: model.demoMode) }
    var body: some View {
        header
        ObservationHero(onStart: onStart)
        if summary.needsReview > 0 {
            NavigationLink { ProcessingCenterView() } label: {
                FeatureRoute(title: l("有 \(summary.needsReview) 段录音需要核对"), detail: l("查看失败、跳过、延后或待清理的任务"), icon: "tray.and.arrow.down")
            }.buttonStyle(.plain)
        }
        SectionHeading(title: l("今天留下的片刻"), detail: l("身体信号、主动标记和确认高光，分别记录。"))
        LazyVGrid(columns: typeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
            countTile(l("心率事件"), value: summary.heartEvents, icon: "waveform.path.ecg")
            countTile(l("主动标记"), value: summary.manualMarkers, icon: "bookmark")
            countTile(l("确认高光"), value: summary.confirmedHighlights, icon: "quote.bubble")
        }
        DisclosureGroup {
            HeartCurveView(day: Date())
        } label: {
            Label(l("展开今天的心率曲线"), systemImage: "waveform.path.ecg").font(.subheadline.weight(.semibold)).frame(minHeight: 44)
        }
        if let moment = summary.latest {
            latest(moment)
        } else {
            AppCard {
                Image(systemName: "quote.bubble").font(.title).foregroundStyle(AppTheme.accent)
                Text(l("今天的故事，慢慢开始。")).font(.headline)
                Text(l("变化发生时记录之后的声音。你也可以标记重要时刻，之后回到原话核对。"))
                    .font(.subheadline).foregroundStyle(AppTheme.muted)
                if !model.demoMode && !model.busy && !model.observing {
                    Button(l("先看看模拟的一天")) { model.loadDemo() }.font(.subheadline.bold()).frame(minHeight: 44).disabled(!model.canWriteArchive)
                }
            }
        }
        if summary.hasTodayEvidence {
            Button(action: onReview) {
                FeatureRoute(title: l("把今天的片刻串起来"), detail: l("生成有来源的回顾，也留一点空间给本人感受"), icon: "sparkles")
            }.buttonStyle(.plain)
        }
        SectionHeading(title: l("让记录帮上忙"))
        NavigationLink { HealthOverviewView() } label: {
            FeatureRoute(title: l("身体与日常"), detail: l("看真实趋势，再决定今天怎样安排"), icon: "heart.text.clipboard")
        }.buttonStyle(.plain)
        NavigationLink { JournalLibraryView() } label: {
            FeatureRoute(title: l("找回一句话"), detail: l("搜索原话、收藏高光，整理人物与记忆"), icon: "text.magnifyingglass")
        }.buttonStyle(.plain)
        Label(l("变化是线索，感受由你确认。所有缺失都会保留为未知。"), systemImage: "lock.shield")
            .font(.caption).foregroundStyle(AppTheme.muted).padding(.top, 4)
    }
    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(Date(), format: .dateTime.month().day().weekday()).font(.subheadline).foregroundStyle(AppTheme.muted)
                Text(l("身体变化时，\n留住真实片刻。")).font(.largeTitle.weight(.semibold)).tracking(-0.8).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            NavigationLink { AvatarSettingsView() } label: { AvatarView(configuration: model.avatar, size: typeSize.isAccessibilitySize ? 48 : 64) }
                .accessibilityLabel(l("定制我的形象"))
        }.padding(.top, 10)
    }
    private func countTile(_ title: String, value: Int, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).foregroundStyle(AppTheme.accent)
            Text("\(value)").font(.title.weight(.semibold).monospacedDigit())
            Text(title).font(.caption).foregroundStyle(AppTheme.muted)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 20))
            .accessibilityElement(children: .combine)
    }
    @ViewBuilder private func latest(_ moment: DashboardMoment) -> some View {
        switch moment.source {
        case .heart:
            if let event = model.visible.first(where: { $0.id == moment.id }) { NavigationLink { EpisodeDetail(id: event.id) } label: { EpisodeCard(event: event) }.buttonStyle(.plain) }
        case .manual:
            if let marker = model.visibleMarkers.first(where: { $0.id == moment.id }) { NavigationLink { MarkerDetail(id: marker.id) } label: { MarkerRow(marker: marker) }.buttonStyle(.plain) }
        case .highlight:
            NavigationLink { ClipDetailView(id: moment.id) } label: {
                AppCard {
                    HStack { StatusPill(text: l("本人确认的高光"), icon: "quote.bubble.fill"); Spacer(); Text(l.date(moment.date)).font(.caption).foregroundStyle(AppTheme.muted) }
                    Text(moment.text).font(.title3.weight(.medium)).lineLimit(4).foregroundStyle(AppTheme.ink)
                    Label(l("回到原话核对"), systemImage: "arrow.up.right").font(.caption).foregroundStyle(AppTheme.accent)
                }
            }.buttonStyle(.plain)
        }
    }
}

struct ObservationHero: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var typeSize
    let onStart: () -> Void
    private var l: Localizer { Localizer(locale: locale) }
    private var fresh: Bool { model.latestBPM != nil && model.latestSampleAt.map { abs($0.timeIntervalSinceNow) < 60 } == true && !model.demoMode }
    var body: some View {
        AppCard {
            ViewThatFits(in: .horizontal) {
                HStack { status; Spacer(); privacy }
                VStack(alignment: .leading, spacing: 8) { status; privacy }
            }
            if model.demoMode {
                Text(l("先体验，再决定怎样记录。")).font(.title2.weight(.semibold))
                Text(l("这里的曲线与片刻都是模拟内容，不会开启麦克风。"))
                    .font(.subheadline).foregroundStyle(AppTheme.muted)
                Button(l("退出模拟，回到我的一天")) { model.exitDemo() }.buttonStyle(PrimaryActionStyle())
            } else {
                if fresh, let bpm = model.latestBPM, let date = model.latestSampleAt {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(Int(bpm))").font(typeSize.isAccessibilitySize ? .largeTitle : .system(size: 60, weight: .light, design: .rounded))
                        Text(l("次/分")).foregroundStyle(AppTheme.muted)
                        Spacer()
                        Image(systemName: "heart.fill").font(.title2).foregroundStyle(AppTheme.recording)
                    }
                    Text(l("最近样本 \(l.date(date, seconds: true)) · 不保证连续实时")).font(.caption).foregroundStyle(AppTheme.muted)
                } else {
                    Text(model.observing ? l("正在等待新鲜的身体线索。") : l("让变化有上下文，\n让回顾有依据。"))
                        .font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    Text(model.observing ? l("有数据才解释，有录音才引用。等待期间不推断心情。") : l("开启观察后，心率波动可记录之后的声音。随时停止，之后再回到原话。"))
                        .font(.subheadline).foregroundStyle(AppTheme.muted)
                }
                if !model.canWriteArchive {
                    Text(l("本地档案暂不可写，请先检查保存状态。"))
                        .font(.caption).foregroundStyle(AppTheme.warning)
                }
                action
                if model.observing {
                    HStack {
                        Label(l("前台可触发 · 没有触发前语音"), systemImage: "iphone")
                        Spacer(minLength: 8)
                        Button(l("结束观察")) { model.stop() }.frame(minHeight: 44)
                    }.font(.caption).foregroundStyle(AppTheme.muted)
                } else {
                    Text(l("变化触发 · 原话可查 · 本机处理")).font(.caption).foregroundStyle(AppTheme.muted)
                }
            }
        }
    }
    private var status: some View {
        StatusPill(text: model.demoMode ? l("模拟体验") : model.recordingPaused ? l("录音已暂停") : model.recordingID != nil ? l("正在录音") : model.observing ? l("观察已开启") : l("由你决定何时开始"),
                   icon: model.recordingID != nil ? "mic.fill" : "leaf", color: model.recordingID != nil ? AppTheme.recording : AppTheme.accent)
    }
    private var privacy: some View { Label(l("留在本机"), systemImage: "lock.fill").font(.caption).foregroundStyle(AppTheme.muted) }
    @ViewBuilder private var action: some View {
        if !model.canWriteArchive {
            NavigationLink { ProcessingCenterView() } label: { Label(l("检查本地档案"), systemImage: "externaldrive.badge.exclamationmark") }.buttonStyle(PrimaryActionStyle())
        } else if model.recordingPaused {
            Button(l("继续录音")) { model.resumeRecording() }.buttonStyle(PrimaryActionStyle())
        } else if model.recordingID != nil {
            Button(l("标记此刻")) { model.markMoment() }.buttonStyle(PrimaryActionStyle()).disabled(!model.canWriteArchive)
        } else if model.busy {
            NavigationLink { ProcessingCenterView() } label: { Label(l("查看文字整理进度"), systemImage: "text.badge.checkmark") }.buttonStyle(PrimaryActionStyle())
        } else if model.observing {
            NavigationLink { HealthMetricsView() } label: { Label(l("查看身体线索"), systemImage: "waveform.path.ecg") }.buttonStyle(PrimaryActionStyle())
        } else {
            Button(action: onStart) { HStack { if model.consenting { ProgressView().tint(.white) }; Label(model.consenting ? l("正在请求权限…") : l("开启今天的观察"), systemImage: "waveform") } }
                .buttonStyle(PrimaryActionStyle()).disabled(model.consenting || !model.canWriteArchive)
        }
    }
}
