// A project's memories (core /memories): what its agents remember between sessions, each a named fact of a kind with a
// one-line description and its text; and, for an Admin token, the health report that says which need verifying, which are
// archived, and which look duplicated.
import Foundation

struct Memory: Equatable, Sendable, Identifiable {
    var id: Int
    var repo: String
    var name: String
    var type: String
    var description: String
    var body: String
    /// The session that last wrote it; nil once edited by hand.
    var jobID: String?
    var updatedAt: Date?
    /// From the health report: archived, when it was last verified, whether it needs verifying, and its revision (which
    /// a policy change or a merge names).
    var archived = false
    var verifiedAt: Date?
    var needsVerification = false
    var revision: String?

    init?(_ j: JSON) {
        guard let id = j["id"].truncatedInt, let name = j["name"].nonEmpty else { return nil }
        self.id = id; self.name = name
        repo = j["repo"].string ?? ""
        type = j["type"].nonEmpty ?? "project"
        description = j["description"].string ?? ""
        body = j["body"].string ?? ""
        jobID = j["jobId"].nonEmpty
        updatedAt = j["updatedAt"].string.flatMap(memoryDate)
        archived = j["archived"].is(true)
        verifiedAt = j["verifiedAt"].string.flatMap(memoryDate)
        needsVerification = j["needsVerification"].is(true)
        revision = j["revision"].nonEmpty
    }

    static let types = ["project", "feedback", "user", "reference"]
    static func typeLabel(_ t: String) -> String {
        switch t {
        case "user": return "About you"
        case "feedback": return "Feedback"
        case "reference": return "Reference"
        default: return "Project"
        }
    }
}

/// Two memories that look alike, and how alike.
struct MemoryDuplicate: Equatable, Sendable {
    var ids: [Int]
    var similarity: Double
}

enum MemoryLogic {
    /// The list, with the health report's flags laid over it when there is one.
    static func merge(list: JSON, health: JSON?) -> [Memory] {
        var out = list["memories"].items.compactMap(Memory.init)
        if let health {
            let byID = Dictionary(health["memories"].items.compactMap(Memory.init).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            out = out.map { m in
                guard let h = byID[m.id] else { return m }
                var m = m
                m.archived = h.archived; m.verifiedAt = h.verifiedAt; m.needsVerification = h.needsVerification; m.revision = h.revision
                return m
            }
            // Archived ones are in the report only.
            for h in byID.values where !out.contains(where: { $0.id == h.id }) { out.append(h) }
        }
        return out.sorted { a, b in a.archived != b.archived ? !a.archived : a.name < b.name }
    }
    static func duplicates(_ health: JSON?) -> [MemoryDuplicate] {
        (health?["duplicates"].items ?? []).compactMap { d in
            let ids = d["ids"].items.compactMap(\.truncatedInt)
            guard ids.count == 2 else { return nil }
            return MemoryDuplicate(ids: ids, similarity: d["similarity"].number ?? 0)
        }
    }
    /// A memory's name: a slug of letters, digits, `-` and `_`.
    static func validName(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 100 && s.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") }
    }
}

/// An ISO-8601 time, with or without fractions.
func memoryDate(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}
