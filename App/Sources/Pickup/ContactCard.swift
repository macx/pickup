import AppKit
import UniformTypeIdentifiers

/// "Add to Contacts…" for a number without a contact: a vCard handed to the app that opens vCards
/// on this Mac (Contacts, or e.g. Cardhop when the user made it the default).
enum ContactCard {
    /// A vCard 3.0 with the number and, if the phone sent one, the name. Name and number come from the
    /// phone (untrusted): both are escaped, so they cannot add lines or properties to the card.
    static func vCard(name: String?, number: String) -> String {
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let (given, family) = split(name)
        let lines = [
            "BEGIN:VCARD",
            "VERSION:3.0",
            "N:\(escape(family));\(escape(given));;;",
            "FN:\(escape(name))",
            "TEL;TYPE=VOICE:\(escape(number))",
            "END:VCARD",
        ]
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// RFC 2426 text escaping; other control characters are dropped.
    static func escape(_ text: String) -> String {
        var result = ""
        for character in text {
            switch character {
            case "\\": result += "\\\\"
            case ",": result += "\\,"
            case ";": result += "\\;"
            case "\n", "\r", "\r\n": result += "\\n"
            default:
                if character.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                    result.append(character)
                }
            }
        }
        return result
    }

    /// "Jane Doe" → ("Jane", "Doe"); a single word is the given name.
    static func split(_ name: String) -> (given: String, family: String) {
        guard let space = name.lastIndex(of: " ") else { return (name, "") }
        return (String(name[..<space]).trimmingCharacters(in: .whitespaces), String(name[name.index(after: space)...]))
    }

    /// Name of the app that opens vCards, e.g. "Contacts" or "Cardhop"; nil if there is none.
    static var appName: String? {
        guard let url = NSWorkspace.shared.urlForApplication(toOpen: .vCard) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    /// Writes the card to a private temporary folder and opens it with the vCard app. The file is
    /// removed again after a few minutes. Returns false if that failed.
    @MainActor
    static func open(name: String?, number: String) -> Bool {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Pickup-\(UUID().uuidString)", isDirectory: true)
        let file = folder.appendingPathComponent(fileName(name: name, number: number))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(vCard(name: name, number: number).utf8).write(to: file, options: .atomic)
        } catch {
            return false
        }
        guard NSWorkspace.shared.open(file) else {
            try? FileManager.default.removeItem(at: folder)
            return false
        }
        Task {
            try? await Task.sleep(for: .seconds(300))
            try? FileManager.default.removeItem(at: folder)
        }
        return true
    }

    /// "Jane Doe.vcf"; the name (or number) without characters a file name cannot have.
    static func fileName(name: String?, number: String) -> String {
        let base = (name.flatMap { $0.isEmpty ? nil : $0 } ?? number)
            .components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters)).joined()
            .trimmingCharacters(in: .whitespaces)
        return (base.isEmpty ? "Contact" : String(base.prefix(80))) + ".vcf"
    }
}
