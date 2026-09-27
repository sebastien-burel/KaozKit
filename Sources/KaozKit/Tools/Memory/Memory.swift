import Foundation

/// A durable note the assistant chose to remember about the user or an ongoing
/// task. Memories persist across conversations and are injected into the
/// system prompt of future chats so the model stays consistent without having
/// to re-ask.
public struct Memory: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var title: String
    public var content: String
    public let createdAt: Date

    public init(id: UUID = UUID(), title: String, content: String, createdAt: Date = .now) {
        self.id = id
        self.title = title
        self.content = content
        self.createdAt = createdAt
    }

    /// What two titles share when they name the same entry: case, accents
    /// and spacing ignored, so « Âge Pia » and « age  pia » are one.
    public static func titleKey(_ title: String) -> String {
        title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// A title as stored: trimmed, first letter capitalised.
    public static func tidyTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return trimmed }
        return first.uppercased() + trimmed.dropFirst()
    }

    /// Whether the text states a span of time — « 21 jours », « 3 semaines »,
    /// "58 years" — true the day it is written, wrong soon after. What should
    /// be pinned instead is the date it derives from.
    public static func mentionsRelativeDuration(_ text: String) -> Bool {
        text.firstMatch(of: relativeDuration) != nil
    }

    private static let relativeDuration = try! Regex(
        #"\b(\d+|une?|deux|trois|quatre|cinq|six|sept|huit|neuf|dix|a|one|two|three|four|five|seven|eight|nine|ten)\s+(jours?|semaines?|mois|ans?|années?|days?|weeks?|months?|years?)\b"#
    ).ignoresCase()
}
