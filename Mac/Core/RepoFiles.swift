// A repository's files at one branch, as the Files tab browses them: the tree the server lists (`repo_tree`), folders
// before files at every level, a file finder that matches a typed query against the paths as PhpStorm's Go to File
// does, and the language a file is read in for its colours (CodeHighlight.swift).
import Foundation

struct RepoEntry: Equatable, Sendable {
    /// The path from the repository's root, with no leading slash.
    var path: String
    var folder: Bool
    /// A file's size in bytes; nil for a folder or when the server sent none.
    var size: Int?

    init(path: String, folder: Bool, size: Int? = nil) { self.path = path; self.folder = folder; self.size = size }
    /// Needs a string `path`; `type` "tree" is a folder, anything else a file.
    init?(_ j: JSON) {
        guard let path = j["path"].string, !path.isEmpty else { return nil }
        self.path = path
        folder = j["type"].string == "tree"
        size = folder ? nil : j["size"].int32.flatMap { $0 >= 0 ? $0 : nil }
    }
    var name: String { repoBasename(path) }
}

func repoBasename(_ path: String) -> String {
    guard let slash = path.lastIndex(of: "/") else { return path }
    return String(path[path.index(after: slash)...])
}
/// The folder a path is in; "" at the root.
func repoParent(_ path: String) -> String {
    guard let slash = path.lastIndex(of: "/") else { return "" }
    return String(path[..<slash])
}

/// What `repo_tree` answers: every entry, and each folder's children in the order they are shown.
struct RepoTree: Equatable, Sendable {
    var ref: String
    var sha: String?
    /// GitHub lists at most 100,000 entries or 7 MB of a tree; past that the list stops short.
    var truncated: Bool
    var entries: [String: RepoEntry]
    /// A folder's path ("" for the root) → its children's paths, folders first, then by name as people sort them.
    var children: [String: [String]]

    init(ref: String, sha: String? = nil, truncated: Bool = false, entries list: [RepoEntry]) {
        self.ref = ref; self.sha = sha; self.truncated = truncated
        var entries: [String: RepoEntry] = [:]
        for e in list { entries[e.path] = e }
        // A folder the list skipped (a truncated tree) is still drawn above the files in it.
        for e in list {
            var p = repoParent(e.path)
            while !p.isEmpty && entries[p] == nil { entries[p] = RepoEntry(path: p, folder: true); p = repoParent(p) }
        }
        var children: [String: [String]] = ["": []]
        for e in entries.values { children[repoParent(e.path), default: []].append(e.path) }
        for (k, v) in children {
            children[k] = v.sorted { a, b in
                let fa = entries[a]?.folder ?? false, fb = entries[b]?.folder ?? false
                if fa != fb { return fa }
                let order = repoBasename(a).localizedStandardCompare(repoBasename(b))
                return order == .orderedSame ? a < b : order == .orderedAscending
            }
        }
        self.entries = entries
        self.children = children
    }
    /// Needs an object with an `entries` array; entries that do not read are skipped.
    init?(_ j: JSON) {
        guard j.isObject, let list = j["entries"].array else { return nil }
        self.init(ref: j["ref"].string ?? "", sha: j["sha"].string, truncated: j["truncated"].is(true), entries: list.compactMap(RepoEntry.init))
    }

    var files: [String] { entries.values.filter { !$0.folder }.map(\.path).sorted() }
    /// The folders that hold `path`, from the root down, so it can be revealed.
    func ancestors(of path: String) -> [String] {
        var out: [String] = []
        var p = repoParent(path)
        while !p.isEmpty { out.insert(p, at: 0); p = repoParent(p) }
        return out
    }
}

/// What `repo_file` answers for one file.
struct RepoFile: Equatable, Sendable {
    var path: String
    var ref: String
    var size: Int
    /// The text, or nil for a file shown only by its size: binary, or too large to send.
    var content: String?
    var binary: Bool
    var tooLarge: Bool
    var url: String?

    init(path: String, ref: String = "", size: Int = 0, content: String? = nil, binary: Bool = false, tooLarge: Bool = false, url: String? = nil) {
        self.path = path; self.ref = ref; self.size = size; self.content = content; self.binary = binary; self.tooLarge = tooLarge; self.url = url
    }
    /// Needs a string `path`.
    init?(_ j: JSON) {
        guard j.isObject, let path = j["path"].string else { return nil }
        self.init(path: path, ref: j["ref"].string ?? "", size: j["size"].int32 ?? 0, content: j["content"].string,
                  binary: j["binary"].is(true), tooLarge: j["tooLarge"].is(true), url: j["url"].string)
    }
}

// MARK: - Go to file

/// The paths a query finds, best first, as PhpStorm's Go to File ranks them: the query's characters in order, case
/// ignored; a "/" in it matches across folders. A match inside the file's own name beats one spread over its folders,
/// a run of characters beats scattered ones, and a match at a word's start beats one inside it. An empty query finds
/// nothing.
func repoFindFiles(_ query: String, in paths: [String], limit: Int = 50) -> [String] {
    let q = Array(query.lowercased().filter { !$0.isWhitespace })
    guard !q.isEmpty else { return [] }
    var scored: [(score: Int, path: String)] = []
    for p in paths {
        if let s = repoMatchScore(q, p) { scored.append((s, p)) }
    }
    scored.sort { $0.score != $1.score ? $0.score > $1.score : ($0.path.count != $1.path.count ? $0.path.count < $1.path.count : $0.path < $1.path) }
    return scored.prefix(limit).map(\.path)
}

/// Nil when `q` is not in `path` in order. Higher is better.
func repoMatchScore(_ q: [Character], _ path: String) -> Int? {
    let chars = Array(path.lowercased())
    let original = Array(path)
    let nameStart = (chars.lastIndex(of: "/") ?? -1) + 1
    // Matched inside the name alone when the query holds no slash and fits there; otherwise across the whole path.
    if !q.contains("/"), let s = scoreFrom(q, chars, original, start: nameStart) { return 1000 + s }
    return scoreFrom(q, chars, original, start: 0)
}

/// Greedy, preferring each character at a word's start, then anywhere after the last one matched.
private func scoreFrom(_ q: [Character], _ chars: [Character], _ original: [Character], start: Int) -> Int? {
    var score = 0, at = start, last = -2
    for c in q {
        var found: Int?
        // A word's start first: after / _ - . or a space, or a capital after a small letter.
        var i = at
        while i < chars.count {
            if chars[i] == c && isWordStart(original, i) { found = i; break }
            if chars[i] == c && i == last + 1 { found = i; break }
            i += 1
        }
        if found == nil { found = chars[at...].firstIndex(of: c) }
        guard let f = found else { return nil }
        if f == last + 1 { score += 8 }
        if isWordStart(original, f) { score += 5 }
        score -= min(f - at, 10)
        last = f; at = f + 1
    }
    return score
}

private func isWordStart(_ s: [Character], _ i: Int) -> Bool {
    if i == 0 { return true }
    let prev = s[i - 1]
    if "/_-. ".contains(prev) { return true }
    return s[i].isUppercase && prev.isLowercase
}

// MARK: - Sizes

func repoFormatSize(_ bytes: Int) -> String {
    if bytes < 1024 { return "\(bytes) B" }
    let kb = Double(bytes) / 1024
    if kb < 1024 { return kb < 10 ? String(format: "%.1f KB", kb) : String(format: "%.0f KB", kb) }
    let mb = kb / 1024
    return mb < 10 ? String(format: "%.1f MB", mb) : String(format: "%.0f MB", mb)
}
