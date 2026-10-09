// The Files tab's local index of a repository at one commit: the text of every source file (vendor/ and node_modules/
// left out, as PhpStorm leaves them out of its project index), what each declares (CodeSymbols.swift), and the searches
// PhpStorm's navigation runs over them: Go to Class and Go to Symbol by a typed query, Go to Declaration of a name from
// where it is used, Find Usages of a name, and Find in Files.
import Foundation

/// Whether a path from the repository's root belongs in the index: not under vendor/ or node_modules/ (at any depth), nor
/// a .git folder.
func repoIndexIncludes(_ path: String) -> Bool {
    !path.split(separator: "/").contains { $0 == "vendor" || $0 == "node_modules" || $0 == ".git" }
}

/// The largest file the index reads, as the server's own limit on one file.
let repoIndexMaxFileBytes = 1024 * 1024

/// A file's bytes as text, or nil when it is binary: a NUL in its first 8 KB, or not UTF-8.
func repoText(_ data: Data) -> String? {
    if data.prefix(8192).contains(0) { return nil }
    return String(data: data, encoding: .utf8)
}

struct RepoIndex: Sendable {
    /// Path → text, for every file read.
    let texts: [String: String]
    let symbols: [CodeSymbol]
    /// Path → what it imports (PHP's `use`), and the namespace it declares.
    let outlines: [String: CodeFileOutline]
    private let byName: [String: [Int]]

    init(texts: [String: String]) {
        self.texts = texts
        var outlines: [String: CodeFileOutline] = [:]
        var symbols: [CodeSymbol] = []
        for path in texts.keys.sorted() where codeOutlineSupported(path) {
            let outline = codeOutline(texts[path]!, path: path)
            outlines[path] = outline
            symbols += outline.symbols
        }
        var byName: [String: [Int]] = [:]
        for (i, s) in symbols.enumerated() { byName[s.name, default: []].append(i) }
        self.outlines = outlines
        self.symbols = symbols
        self.byName = byName
    }

    var fileCount: Int { texts.count }

    // MARK: Go to Class, Go to Symbol

    /// The symbols a query finds, best first: types alone for Go to Class, everything for Go to Symbol. The query matches
    /// the name as Go to File matches a file's name; one with a dot, `::` or a backslash matches the qualified name
    /// (`User.save`, `User::save`, `Models\User`).
    func search(_ query: String, typesOnly: Bool, limit: Int = 60) -> [CodeSymbol] {
        var q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        q = q.replacingOccurrences(of: "::", with: ".").replacingOccurrences(of: "->", with: ".")
        let qualified = q.contains(".") || q.contains("\\")
        // Matched as a path is: each separator a folder's slash.
        let chars = Array(q.replacingOccurrences(of: "\\", with: "/").replacingOccurrences(of: ".", with: "/"))
        var scored: [(score: Int, symbol: CodeSymbol)] = []
        for s in symbols where !typesOnly || s.kind.isType {
            let target = qualified ? s.qualified.lowercased() : s.name.lowercased()
            guard var score = repoMatchScore(chars, target.replacingOccurrences(of: "\\", with: "/")
                .replacingOccurrences(of: ".", with: "/")) else { continue }
            if target == q || s.name.lowercased() == q { score += 500 }
            if s.kind.isType { score += 3 }
            scored.append((score, s))
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.symbol.name.count != b.symbol.name.count { return a.symbol.name.count < b.symbol.name.count }
            return (a.symbol.path, a.symbol.line) < (b.symbol.path, b.symbol.line)
        }
        return scored.prefix(limit).map(\.symbol)
    }

    /// The symbols declared in one file, in order: File Structure.
    func structure(of path: String) -> [CodeSymbol] { outlines[path]?.symbols ?? [] }

    // MARK: Go to Declaration

    /// Where `name`, used in `path`, is declared, the likeliest first. A member (`->name`, `.name`, `::name`) looks at
    /// methods, properties and constants; anything else at types and functions first. A PHP class imported with `use`
    /// is the one named there; one in the same file, then the same namespace or folder, comes before the rest.
    func declarations(of name: String, from path: String, member: Bool = false) -> [CodeSymbol] {
        guard let found = byName[name], !found.isEmpty else { return [] }
        var candidates = found.map { symbols[$0] }
        let memberKinds: Set<CodeSymbolKind> = [.method, .property, .constant]
        let preferred = candidates.filter { member ? memberKinds.contains($0.kind) : !memberKinds.contains($0.kind) || $0.container == nil }
        if !preferred.isEmpty { candidates = preferred }
        let outline = outlines[path]
        let imported = outline?.imports[name]
        let folder = repoParent(path)
        func rank(_ s: CodeSymbol) -> Int {
            if let imported, let ns = s.namespace, ns + "\\" + s.name == imported { return 0 }
            if s.path == path { return 1 }
            if let ns = outline?.namespace, s.namespace == ns { return 2 }
            if repoParent(s.path) == folder { return 3 }
            return 4
        }
        // An import names one class: the others of that name are not what this file means.
        if imported != nil, candidates.contains(where: { rank($0) == 0 }) { candidates = candidates.filter { rank($0) == 0 || $0.path == path } }
        return candidates.sorted { (rank($0), $0.path, $0.line) < (rank($1), $1.path, $1.line) }
    }

    // MARK: Find Usages, Find in Files

    /// Every line where `name` appears as a whole word, outside the line it is declared on.
    func usages(of name: String, limit: Int = 2000) -> [RepoMatch] {
        let declared = Set((byName[name] ?? []).map { "\(symbols[$0].path):\(symbols[$0].line)" })
        var out: [RepoMatch] = []
        for path in texts.keys.sorted() {
            for m in repoFind(TextQuery(text: name, matchCase: true, wholeWord: true), in: texts[path]!, path: path)
            where !declared.contains("\(path):\(m.line)") {
                out.append(m)
                if out.count >= limit { return out }
            }
        }
        return out
    }

    func find(_ query: TextQuery, limit: Int = 2000) -> [RepoMatch] {
        guard !query.text.isEmpty else { return [] }
        var out: [RepoMatch] = []
        for path in texts.keys.sorted() {
            out += repoFind(query, in: texts[path]!, path: path, limit: limit - out.count)
            if out.count >= limit { break }
        }
        return out
    }
}

/// What Find in Files looks for.
struct TextQuery: Equatable, Sendable {
    var text: String
    var matchCase = false
    var wholeWord = false
    var regex = false
}

/// One line that matched, with where in it (UTF-16 offsets, as NSString counts them).
struct RepoMatch: Equatable, Sendable {
    var path: String
    /// 1-based.
    var line: Int
    var preview: String
    var ranges: [NSRange]
}

/// The lines of `text` that match `query`. An invalid regular expression matches nothing.
func repoFind(_ query: TextQuery, in text: String, path: String, limit: Int = 2000) -> [RepoMatch] {
    guard !query.text.isEmpty, limit > 0 else { return [] }
    var pattern = query.regex ? query.text : NSRegularExpression.escapedPattern(for: query.text)
    if query.wholeWord { pattern = "(?<![\\w$])(?:" + pattern + ")(?![\\w])" }
    guard let regex = try? NSRegularExpression(pattern: pattern, options: query.matchCase ? [] : [.caseInsensitive]) else { return [] }
    var out: [RepoMatch] = []
    var number = 0
    text.enumerateLines { line, stop in
        number += 1
        let ns = line as NSString
        let found = regex.matches(in: line, range: NSRange(location: 0, length: ns.length)).map(\.range).filter { $0.length > 0 }
        if !found.isEmpty {
            out.append(RepoMatch(path: path, line: number, preview: line, ranges: found))
            if out.count >= limit { stop = true }
        }
    }
    return out
}

/// The word at a UTF-16 offset of a line, and whether a member operator (`->`, `.`, `::`, `?->`) comes just before it:
/// what Go to Declaration and Find Usages act on.
func codeWord(in line: String, at offset: Int) -> (word: String, range: NSRange, member: Bool)? {
    let ns = line as NSString
    guard ns.length > 0 else { return nil }
    func isWord(_ i: Int) -> Bool {
        guard i >= 0, i < ns.length, let scalar = Unicode.Scalar(ns.character(at: i)) else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
    }
    var start = min(max(offset, 0), ns.length - 1)
    if !isWord(start) { if isWord(start - 1) { start -= 1 } else { return nil } }
    var end = start
    while isWord(start - 1) { start -= 1 }
    while isWord(end + 1) { end += 1 }
    let range = NSRange(location: start, length: end - start + 1)
    let word = ns.substring(with: range)
    guard let first = word.unicodeScalars.first, !CharacterSet.decimalDigits.contains(first) else { return nil }
    var before = start - 1
    while before >= 0, ns.character(at: before) == 32 { before -= 1 }
    let prefix = ns.substring(to: before + 1)
    let member = prefix.hasSuffix("->") || prefix.hasSuffix(".") || prefix.hasSuffix("::")
    return (word, range, member)
}
