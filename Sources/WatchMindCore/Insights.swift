import Foundation

public enum Insights {
    /// Lexical hints are explicitly tentative. They are not inferred mental states.
    public static func cues(in text: String, language: AppLanguage = .simplifiedChinese) -> [String] {
        let l = Localizer(language: language)
        let groups: [(String, [String])] = [
            ("可能涉及压力", ["担心", "紧张", "压力", "焦虑", "来不及", "worried", "stressed"]),
            ("可能涉及愉快", ["开心", "高兴", "期待", "喜欢", "happy", "excited"]),
            ("可能涉及疲劳", ["好累", "很累", "有点累", "太累", "累了", "疲惫", "疲劳", "好困", "很困", "困了", "tired", "exhausted"])
        ]
        let source = text.lowercased() as NSString
        return groups.filter { _, terms in
            terms.contains { term in
                let english = term.unicodeScalars.allSatisfy { $0.isASCII }
                let literal = NSRegularExpression.escapedPattern(for: term)
                let pattern = english ? "(?<![a-z])" + literal + "(?![a-z])" : literal
                guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
                return regex.matches(in: source as String, range: NSRange(location: 0, length: source.length)).contains { match in
                    let prefix = source.substring(to: match.range.location)
                    let negation = english
                        ? #"(?:\b(?:not|never|no)|\b[a-z]+n't)\s+(?:(?:really|very|particularly|so|that)\s+){0,3}$"#
                        : #"(?:不|没(?:有)?|无|未|并非)(?:再|太|很|那么|特别|非常|感到|觉得|什么|任何|一点(?:也)?|怎么|了|有|的|[ \t]){0,3}$"#
                    // Suppress ambiguous negation; do not invent the opposite feeling.
                    return prefix.range(of: negation, options: .regularExpression) == nil
                }
            }
        }.map { l.key($0.0) }
    }
    public static func excerpts(_ event: Episode, radius: TimeInterval = 20) -> [TranscriptSegment] {
        guard let start = event.captureStarted else { return [] }
        let relative = event.trigger.date.timeIntervalSince(start)
        return event.segments.filter { $0.offset + $0.duration >= relative - radius && $0.offset <= relative + radius }
    }
    public static func events(on day: Date, from all: [Episode], calendar: Calendar = .current) -> [Episode] {
        all.filter { calendar.isDate($0.trigger.date, inSameDayAs: day) }.sorted { $0.trigger.date < $1.trigger.date }
    }
    public static func report(day: Date, events: [Episode], language: AppLanguage = .simplifiedChinese) -> DailyReport {
        let l = Localizer(language: language)
        let ready = events.filter { $0.status == .ready && !$0.transcript.isEmpty }
        let feelings = events.compactMap(\.feeling).map { l.key($0) }
        let contexts = ready.map { "• \($0.transcript)" }.joined(separator: "\n")
        let text = l("今天记录了 \(events.count) 次心率波动，其中 \(ready.count) 次有可用语音。\n")
            + (feelings.isEmpty ? l("尚无本人确认的感受，不能据此判断心情。") : l("本人标记的感受：\(feelings.joined(separator: l("、")))。"))
            + (contexts.isEmpty ? l("\n暂无可总结的语音上下文。") : l("\n语音回顾：\n\(contexts)"))
            + l("\n这些记录只覆盖触发后的短片段；运动、环境和谈话都可能伴随心率变化，不能确定因果。")
        return DailyReport(day: day, text: text, engine: l("本地规则摘要（非大模型）"), episodeIDs: events.map(\.id), language: l.language.rawValue)
    }
}
