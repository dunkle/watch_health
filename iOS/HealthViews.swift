import SwiftUI
import Charts
import WatchMindCore

struct HeartCurveView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.locale) private var locale
    @State private var selectedMarker: UUID?
    var day = Date()
    private var l: Localizer { Localizer(locale: locale) }
    private var points: [PlotPoint] {
        HeartTimeline.plot(model.heartPoints.filter { $0.isDemo == model.demoMode && Calendar.current.isDate($0.sample.date, inSameDayAs: day) })
    }
    private var markers: [Episode] {
        model.visible.filter { $0.isImportant && Calendar.current.isDate($0.trigger.date, inSameDayAs: day) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l("心率波动曲线")).font(.headline)
            if points.isEmpty && markers.isEmpty {
                Text(l("等待实际心率样本；不会用模拟曲线填补缺失数据。"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(points) { item in
                        LineMark(x: .value("Time", item.point.sample.date), y: .value("bpm", item.point.sample.bpm),
                                 series: .value("Segment", "heart-\(item.section)"))
                            .foregroundStyle(.teal).interpolationMethod(.linear)
                        PointMark(x: .value("Time", item.point.sample.date), y: .value("bpm", item.point.sample.bpm))
                            .foregroundStyle(.teal.opacity(0.6)).symbolSize(7)
                        if let baseline = item.point.baseline {
                            LineMark(x: .value("Time", item.point.sample.date), y: .value("bpm", baseline),
                                     series: .value("Segment", "baseline-\(item.section)"))
                                .foregroundStyle(.gray.opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        }
                    }
                    ForEach(markers) { marker in
                        PointMark(x: .value("Time", marker.trigger.date), y: .value("bpm", marker.trigger.bpm))
                            .foregroundStyle(marker.trigger.isLargeChange ? .orange : .purple).symbolSize(70)
                    }
                }
                .frame(height: 200).chartLegend(.hidden)
                .chartYScale(domain: .automatic(includesZero: false))
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onTapGesture { location in
                                guard let anchor = proxy.plotFrame else { return }
                                let x = location.x - geometry[anchor].origin.x
                                guard let date: Date = proxy.value(atX: x),
                                      let nearest = markers.min(by: { abs($0.trigger.date.timeIntervalSince(date)) < abs($1.trigger.date.timeIntervalSince(date)) }),
                                      let position = proxy.position(forX: nearest.trigger.date), abs(position - x) <= 24 else { return }
                                selectedMarker = nearest.id
                            }
                    }
                }
                Text(l("实线：心率；虚线：近期基线。橙点为大幅变化，紫点为多指标显著事件，点击点附近查看录音。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(l("曲线保留近7天、最多60000点；采样间隔超过90秒会断开，不表示连续监测。"))
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(18).background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppTheme.radius))
            .navigationDestination(item: $selectedMarker) { id in EpisodeDetail(id: id) }
    }
}

struct HealthMetricsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.locale) private var locale
    private var l: Localizer { Localizer(locale: locale) }
    var body: some View {
        List {
            Section {
                Button { Task { await model.refreshMetrics() } } label: {
                    HStack { if model.refreshingMetrics { ProgressView() }; Text(l("刷新健康指标")) }
                }.disabled(model.refreshingMetrics || model.demoMode)
                Text(l("健康数据读取不启动麦克风。无可读样本可能源于权限、设备、地区、佩戴或同步延迟，不能判断为正常值。"))
                    .font(.caption)
            }
            ForEach(HealthCategory.allCases, id: \.self) { category in
                Section {
                    Text(l.key(category.summary)).font(.caption).foregroundStyle(.secondary)
                    if category.includesHeart {
                        NavigationLink {
                            HeartCurveView(day: model.selectedDay).padding().navigationTitle(l("心率波动曲线"))
                        } label: {
                            Label(l("心率波动曲线"), systemImage: "waveform.path.ecg")
                        }
                    }
                    ForEach(category.metricKinds, id: \.self) { kind in
                        MetricRow(kind: kind, reading: ContextAlgorithm.latest(kind, in: model.visibleMetrics, at: Date()), at: Date())
                    }
                } header: {
                    Label(l.key(category.title), systemImage: category.symbol)
                }
            }
            Section(l("算法说明")) {
                Text(l("心率是必要触发条件。其他指标只影响事件显著度与情境，不直接判定情绪或疾病，也不单独打开麦克风。"))
                Text(l("个人基线使用过去14天、至少5个有数据日的每日中位数；缺失或过期指标不补零、不参与评分。"))
                Text(l("步数与能量使用近5分钟健康聚合，可能因样本跨度低估，只用于运动情境。环境音和耳机音为历史音暴露，不是本应用持续监听。"))
                Text(l("睡眠估算分使用主睡眠时长与可用的在床效率，目标8小时；不是Apple官方睡眠评分，不用于医疗判断。腕温只使用睡眠期间可读样本。"))
            }
        }.navigationTitle(l("健康指标"))
    }
}

struct MetricRow: View {
    @Environment(\.locale) private var locale
    let kind: MetricKind
    let reading: MetricReading?
    let at: Date
    private var l: Localizer { Localizer(locale: locale) }
    private func sourceLabel(_ source: String) -> String {
        switch source {
        case "local-duration-only": return l("本地：仅睡眠时长")
        case "local-duration-efficiency": return l("本地：睡眠时长与效率")
        case "HealthKit 5m aggregate": return l("Apple健康：近5分钟聚合")
        case "demo": return l("模拟数据")
        default: return source
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(l.key(kind.title)); Spacer()
                if let reading { Text(String(format: "%.1f", locale: l.locale, reading.value) + " " + kind.unit).monospacedDigit() }
                else { Text("—").foregroundStyle(.secondary) }
            }
            if let reading {
                Text(l.date(reading.date, includeDate: true)).font(.caption).foregroundStyle(.secondary)
                Text(reading.isFresh(at: at) ? l("可作当前情境") : l("历史数据，不作为当前信号"))
                    .font(.caption2).foregroundStyle(reading.isFresh(at: at) ? Color.teal : Color.gray)
                Text(sourceLabel(reading.source)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            } else { Text(l("无可读样本 / 不可用")).font(.caption).foregroundStyle(.secondary) }
        }.padding(.vertical, 4)
    }
}

struct AssessmentView: View {
    @Environment(\.locale) private var locale
    let assessment: EventAssessment
    let at: Date
    private var l: Localizer { Localizer(locale: locale) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l("事件显著度（非健康分数）")).font(.headline)
            if assessment.score.isFinite, (0...100).contains(assessment.score),
               assessment.coverage.isFinite, (0...1).contains(assessment.coverage) {
                Text("\(Int(assessment.score))/100").font(.title2)
                Text(l("有效指标权重覆盖：\(Int(assessment.coverage * 100))%；不是情绪置信度。"))
                    .font(.caption).foregroundStyle(.secondary)
            } else { Text(l("历史显著度数据不可用，不用于身体状态判断。")) }
            if assessment.activeMovement { Text(l("可能伴随活动；心率显著度已适度降低，仍保留录音与标记。")) }
            Text(l("参与辅助评分：\(assessment.contributing.map { l.key($0.title) }.joined(separator: l("、")))"))
                .font(.caption)
            Text(l("无足够个人基线的指标只展示，不用于个体偏离评分。以下是触发时的数据快照。"))
                .font(.caption).foregroundStyle(.secondary)
            ForEach(assessment.readings) { reading in MetricRow(kind: reading.kind, reading: reading, at: at) }
            Text(l("缺失或过期：\(assessment.unavailable.map { l.key($0.title) }.joined(separator: l("、")))"))
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppTheme.radius))
    }
}
