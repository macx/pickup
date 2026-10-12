import Foundation

/// A contact reduced to what dialing needs. Pure value types so the matching logic is unit-testable
/// without `CNContactStore`. Kept in memory only.
struct ContactEntry: Equatable, Sendable, Identifiable {
    struct Phone: Equatable, Sendable {
        /// Already localized (e.g. "mobile", "Mobil"); nil when the contact has no label.
        var label: String?
        var number: String
    }

    var id: String
    var name: String
    var organization: String
    var phones: [Phone]
    var imageData: Data?
    /// Folded words of name and organisation (precomputed for fast prefix search).
    let nameWords: [String]
    let foldedName: String

    init(id: String, name: String, organization: String = "", phones: [Phone], imageData: Data? = nil) {
        self.id = id
        self.name = name
        self.organization = organization
        self.phones = phones
        self.imageData = imageData
        self.nameWords = ContactSearch.words(name + " " + organization)
        self.foldedName = ContactSearch.fold(name)
    }
}

/// One selectable row: a single number of a contact.
struct ContactSearchResult: Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var label: String?
    var number: String
    var imageData: Data?
}

enum ContactSearch {
    /// Case- and diacritic-insensitive form ("Günter" -> "gunter").
    static func fold(_ string: String) -> String {
        var folded = string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        // Letters that Unicode folding keeps (stroked/ligature forms) but people type as plain letters.
        for (from, to) in [("ø", "o"), ("ł", "l"), ("đ", "d"), ("æ", "ae"), ("œ", "oe"), ("ß", "ss"), ("ı", "i")] {
            folded = folded.replacingOccurrences(of: from, with: to)
        }
        return folded
    }

    /// Folded alphanumeric words ("IT-P GmbH" -> ["it", "p", "gmbh"]).
    static func words(_ string: String) -> [String] {
        fold(string).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    static func digits(_ string: String) -> String {
        string.filter { $0.isASCII && $0.isNumber }
    }

    /// True for input that can only be a phone number search (digits and number punctuation).
    static func isNumericQuery(_ query: String) -> Bool {
        let allowed = Set("+-() .*#/")
        return query.contains(where: \.isNumber) && query.allSatisfy { $0.isNumber || allowed.contains($0) }
    }

    /// Minimum digits before number search starts (avoids matching nearly everything).
    static let minimumDigits = 3

    /// Live search. Names/organisations: every query word must be a word prefix. Numbers: digit
    /// substring (national and international notation both match). Name hits are ordered by where
    /// they match (first name word, other word, organisation), then alphabetically.
    static func search(_ query: String, in entries: [ContactEntry], limit: Int = 60) -> [ContactSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        return isNumericQuery(trimmed)
            ? searchNumbers(trimmed, in: entries, limit: limit)
            : searchNames(trimmed, in: entries, limit: limit)
    }

    private static func searchNames(_ query: String, in entries: [ContactEntry], limit: Int) -> [ContactSearchResult] {
        let tokens = words(query)
        guard !tokens.isEmpty else { return [] }
        var hits: [(score: Int, entry: ContactEntry)] = []
        for entry in entries where !entry.phones.isEmpty {
            guard tokens.allSatisfy({ token in entry.nameWords.contains { $0.hasPrefix(token) } }) else { continue }
            let nameWordCount = words(entry.name).count
            let first = entry.nameWords.first.map { $0.hasPrefix(tokens[0]) } ?? false
            let inName = tokens.allSatisfy { token in entry.nameWords.prefix(nameWordCount).contains { $0.hasPrefix(token) } }
            hits.append((first ? 0 : (inName ? 1 : 2), entry))
        }
        hits.sort { ($0.score, $0.entry.foldedName) < ($1.score, $1.entry.foldedName) }
        return hits.flatMap { hit in
            hit.entry.phones.enumerated().map { index, phone in
                ContactSearchResult(id: "\(hit.entry.id)|\(index)", name: hit.entry.name, label: phone.label,
                                    number: phone.number, imageData: hit.entry.imageData)
            }
        }.prefix(limit).map { $0 }
    }

    private static func searchNumbers(_ query: String, in entries: [ContactEntry], limit: Int) -> [ContactSearchResult] {
        let allDigits = digits(query)
        guard allDigits.count >= minimumDigits else { return [] }
        let candidates = numberCandidates(query: query, digits: allDigits)
        var hits: [(position: Int, name: String, result: ContactSearchResult)] = []
        for entry in entries {
            for (index, phone) in entry.phones.enumerated() {
                var n = digits(phone.number)
                if phone.number.hasPrefix("00") || phone.number.hasPrefix("+00") { n = String(n.dropFirst(2)) }
                // Stored numbers are compared in the same two notations as the query.
                let stored = numberCandidates(query: phone.number, digits: n)
                let positions = candidates.compactMap { c in
                    stored.compactMap { n in n.range(of: c).map { n.distance(from: n.startIndex, to: $0.lowerBound) } }.min()
                }
                guard let best = positions.min() else { continue }
                hits.append((best, entry.foldedName, ContactSearchResult(
                    id: "\(entry.id)|\(index)", name: entry.name, label: phone.label,
                    number: phone.number, imageData: entry.imageData)))
            }
        }
        hits.sort { ($0.position, $0.name) < ($1.position, $1.name) }
        return hits.prefix(limit).map(\.result)
    }

    /// Digit strings a number can be searched by: as given, nationally (`0` + national part), and the
    /// bare national part. "+49 170 123" -> ["49170123", "0170123", "170123"]; "0170 123" -> ["0170123", "170123"].
    static func numberCandidates(query: String, digits d: String) -> [String] {
        var raw = d
        let international = query.hasPrefix("+") || query.hasPrefix("00")
        if query.hasPrefix("00") { raw = String(raw.dropFirst(2)) }
        var result = [raw]
        if international, let (_, national) = PhoneNumberFormat.splitCountryCode(raw), !national.isEmpty {
            result += ["0" + national, national]
        } else if raw.hasPrefix("0") {
            result.append(String(raw.dropFirst()))
        }
        return result.filter { !$0.isEmpty }
    }
}
