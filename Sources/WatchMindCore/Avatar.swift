import Foundation

/// A user-selected companion illustration; appearance never infers mood or health.
public struct AvatarConfiguration: Codable, Equatable, Sendable {
    public enum Style: String, CaseIterable, Codable, Sendable { case human, cat, robot }
    public enum Hair: String, CaseIterable, Codable, Sendable { case short, bob, curls, long, bald }
    public enum Accessory: String, CaseIterable, Codable, Sendable { case none, glasses, headphones, cap }
    public var name: String = ""
    public var style: Style = .human
    public var hair: Hair = .bob
    public var accessory: Accessory = .none
    public var skin: Int = 1
    public var outfit: Int = 0
    public var hairColor: Int = 0
    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = String((try c.decodeIfPresent(String.self, forKey: .name) ?? "").prefix(20))
        style = try c.decodeIfPresent(Style.self, forKey: .style) ?? .human
        hair = try c.decodeIfPresent(Hair.self, forKey: .hair) ?? .bob
        accessory = try c.decodeIfPresent(Accessory.self, forKey: .accessory) ?? .none
        skin = min(5, max(0, try c.decodeIfPresent(Int.self, forKey: .skin) ?? 1))
        outfit = min(5, max(0, try c.decodeIfPresent(Int.self, forKey: .outfit) ?? 0))
        hairColor = min(5, max(0, try c.decodeIfPresent(Int.self, forKey: .hairColor) ?? 0))
    }
    public static func preset(_ style: Style) -> AvatarConfiguration {
        var result = AvatarConfiguration(); result.style = style
        switch style {
        case .human: break
        case .cat: result.outfit = 2; result.skin = 0
        case .robot: result.outfit = 1; result.accessory = .headphones
        }
        return result
    }
}
