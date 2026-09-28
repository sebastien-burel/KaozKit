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

    /// Whether an entry is about someone else — « ma fille Clara », « la
    /// fille de Clara », "my wife", an entry titled « Enfants ». Those belong
    /// on that person's page in the wiki, not pinned into every conversation.
    public static func isAboutSomeoneElse(title: String, content: String) -> Bool {
        if relationTitles.contains(titleKey(title)) { return true }
        let text = "\(title) \(content)"
        return text.firstMatch(of: relation) != nil || text.firstMatch(of: relationOf) != nil
    }

    private static let relationTitles: Set<String> = [
        "enfants", "famille", "petits-enfants", "children", "family", "kids", "grandchildren"
    ]

    private static let relation = try! Regex(
        #"\b(ma|mon|mes|notre|nos|my|our)\s+(filles?|fils|enfants?|femme|mari|épouse|époux|compagnon|compagne|conjointe?|frères?|sœurs?|soeurs?|père|mère|parents|grand-père|grand-mère|grands-parents|petites?-filles?|petits?-fils|petits?-enfants|neveux?|nièces?|oncles?|tantes?|cousins?|cousines?|belle-mère|beau-père|belle-fille|gendre|beau-frère|belle-sœur|collègues?|associée?s?|daughters?|sons?|children|kids?|wife|husband|partner|brothers?|sisters?|father|mother|dad|mum|mom|grand(?:daughter|son|child|mother|father)(?:ren|s)?|nephews?|nieces?|uncles?|aunts?|cousins?|colleagues?)\b"#
    ).ignoresCase()

    /// The same relations said of a third person: « la fille de Clara »,
    /// « l'une des trois enfants de Sébastien », "the wife of".
    private static let relationOf = try! Regex(
        #"\b(filles?|fils|enfants?|femme|mari|épouse|époux|frères?|sœurs?|soeurs?|père|mère|parents|petites?-filles?|petits?-fils|petits?-enfants|neveux?|nièces?|daughters?|sons?|children|wife|husband|brothers?|sisters?|father|mother|grand(?:daughter|son|child)(?:ren|s)?)\s+(de|d'|d’|du|des|of)\b"#
    ).ignoresCase()

    private static let relativeDuration = try! Regex(
        #"\b(\d+|une?|deux|trois|quatre|cinq|six|sept|huit|neuf|dix|a|one|two|three|four|five|seven|eight|nine|ten)\s+(jours?|semaines?|mois|ans?|années?|days?|weeks?|months?|years?)\b"#
    ).ignoresCase()
}
