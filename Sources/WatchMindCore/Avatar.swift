import Foundation

/// User-created illustration only; its expression never claims to infer the user's mood.
public struct AvatarConfiguration: Codable, Equatable, Sendable {
    public enum Hair: String, CaseIterable, Codable, Sendable { case short, bob, curls }
    public enum Accessory: String, CaseIterable, Codable, Sendable { case none, glasses, headphones }
    public var name: String = ""
    public var hair: Hair = .bob
    public var accessory: Accessory = .none
    public var skin: Int = 1
    public var outfit: Int = 0
    public var hairColor: Int = 0
    public init() {}
}
