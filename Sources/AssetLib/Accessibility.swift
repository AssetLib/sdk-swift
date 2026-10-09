import Foundation

/// Optional artwork descriptions. The app decides whether an image is informative or decorative.
public struct AssetAccessibility: Codable, Sendable, Equatable {
    public let defaultLocale: String
    public let descriptions: [String: String]

    public init(defaultLocale: String, descriptions: [String: String]) throws {
        let localePattern = "^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*\\z"
        let keys = descriptions.keys.map { $0.lowercased() }
        guard (1...32).contains(descriptions.count), defaultLocale.utf16.count <= 63,
              matches(defaultLocale, localePattern), keys.contains(defaultLocale.lowercased()),
              Set(keys).count == keys.count,
              descriptions.allSatisfy({ locale, description in
                  locale.utf16.count <= 63 && matches(locale, localePattern) &&
                  description.utf16.count <= 1000 && description.unicodeScalars.contains { !Self.blankScalars.contains($0) }
              }) else { throw AssetLibError.invalid("Invalid artwork accessibility descriptions.") }
        self.defaultLocale = defaultLocale
        self.descriptions = descriptions
    }

    // Match ECMAScript trim across SDKs, including NBSP and BOM (excluding U+0085).
    private static let blankScalars = CharacterSet(charactersIn: "\u{0009}\u{000a}\u{000b}\u{000c}\u{000d}\u{0020}\u{00a0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200a}\u{2028}\u{2029}\u{202f}\u{205f}\u{3000}\u{feff}")

    enum CodingKeys: String, CodingKey { case defaultLocale, descriptions }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(defaultLocale: c.decode(String.self, forKey: .defaultLocale),
                      descriptions: c.decode([String: String].self, forKey: .descriptions))
    }

    /// Exact locale, progressively less specific language tags, then the explicit default.
    public func localizedDescription(locale: Locale = .current) -> String {
        localizedDescription(languageTag: locale.identifier.replacingOccurrences(of: "_", with: "-"))
    }

    public func localizedDescription(languageTag: String) -> String {
        let lookup = Dictionary(uniqueKeysWithValues: descriptions.map { ($0.key.lowercased(), $0.value) })
        var tag = languageTag.lowercased()
        while !tag.isEmpty {
            if let description = lookup[tag] { return description }
            guard let separator = tag.lastIndex(of: "-") else { break }
            tag = String(tag[..<separator])
        }
        // Construction and decoding guarantee the default locale exists.
        return lookup[defaultLocale.lowercased()]!
    }
}
