import Foundation

public enum AppLanguage: String, CaseIterable, Hashable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    public static func resolve(preferredLanguages: [String]) -> AppLanguage {
        for identifier in preferredLanguages {
            let base = identifier.lowercased().split(separator: "-").first ?? ""
            if base == "zh" { return .simplifiedChinese }
            if base == "en" { return .english }
        }
        return .english
    }
    public var resolved: AppLanguage {
        self == .system ? Self.resolve(preferredLanguages: Locale.preferredLanguages) : self
    }
    public var locale: Locale { Locale(identifier: resolved == .simplifiedChinese ? "zh_CN" : "en_US") }
    public var speechLocaleIdentifier: String { resolved == .simplifiedChinese ? "zh-CN" : "en-US" }
}

/// Keeps interpolated values out of the lookup key. Substitution never reinterprets user text.
public struct LocalizedMessage: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    public let key: String
    public let arguments: [String]
    public init(_ key: String) { self.key = key; arguments = [] }
    public init(stringLiteral value: String) { self.init(value) }
    public init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key; arguments = stringInterpolation.arguments
    }
    public struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [String] = []
        public init(literalCapacity: Int, interpolationCount: Int) {}
        public mutating func appendLiteral(_ literal: String) { key += literal }
        public mutating func appendInterpolation<T>(_ value: T) {
            key += "{\(arguments.count)}"; arguments.append(String(describing: value))
        }
    }
}

public struct Localizer {
    public let language: AppLanguage
    public var locale: Locale { language.locale }
    public init(language: AppLanguage) { self.language = language.resolved }
    public init(locale: Locale) { self.init(language: .resolve(preferredLanguages: [locale.identifier.replacingOccurrences(of: "_", with: "-")])) }
    public func callAsFunction(_ message: LocalizedMessage) -> String {
        let template = key(message.key)
        guard !message.arguments.isEmpty,
              let pattern = try? NSRegularExpression(pattern: #"\{(\d+)\}"#) else { return template }
        let source = template as NSString
        var result = ""; var end = 0
        for match in pattern.matches(in: template, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: end, length: match.range.location - end))
            let index = Int(source.substring(with: match.range(at: 1))) ?? -1
            result += message.arguments.indices.contains(index) ? message.arguments[index] : source.substring(with: match.range)
            end = NSMaxRange(match.range)
        }
        return result + source.substring(from: end)
    }
    public func key(_ key: String) -> String {
        guard let path = Bundle.module.path(forResource: language.rawValue, ofType: "lproj"), let bundle = Bundle(path: path) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }
    public func date(_ date: Date, includeDate: Bool = false, seconds: Bool = false) -> String {
        let formatter = DateFormatter(); formatter.locale = locale
        formatter.dateStyle = includeDate ? .medium : .none
        formatter.timeStyle = seconds ? .medium : .short
        return formatter.string(from: date)
    }
}
