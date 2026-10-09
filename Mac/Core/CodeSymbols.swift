// The declarations in a source file, as the Files tab's index reads them for Go to Class, Go to Symbol, File Structure
// and Go to Declaration: classes and their kin, functions, methods, constants and properties, each with the type it is
// declared in, its line, the line itself as its signature, and the comment above it. It reads the code the lexer leaves
// once strings and comments are blanked (CodeHighlight.swift), line by line, with a pattern per family of languages and
// the braces (or, in Python and Ruby, the indentation) to know which type a member belongs to. It is a reader of
// declarations, not a parser: what an unusual layout hides from it is simply not listed.
import Foundation

enum CodeSymbolKind: String, Equatable, Sendable, CaseIterable {
    case `class`, interface, trait, `enum`, `struct`, `protocol`, type, module, function, method, constant, property

    /// A kind Go to Class lists.
    var isType: Bool {
        switch self {
        case .class, .interface, .trait, .enum, .struct, .protocol, .type, .module: return true
        default: return false
        }
    }
    var label: String { rawValue }
}

struct CodeSymbol: Equatable, Sendable {
    var name: String
    var kind: CodeSymbolKind
    /// The type it is declared in, by name; nil at the top of a file.
    var container: String?
    /// The PHP namespace (or other package) it is declared in, when the file names one.
    var namespace: String?
    var path: String
    /// 1-based.
    var line: Int
    /// The declaration's line, trimmed and cut before its body.
    var signature: String
    /// The comment just above it, without its markers.
    var doc: String?

    /// `Namespace\Container.name`, as Go to Class and Go to Symbol show it beside the name.
    var qualified: String {
        var out = ""
        if let namespace, !namespace.isEmpty { out = namespace + "\\" }
        if let container { out += container + "." }
        return out + name
    }
}

/// What a file declares, and, for PHP, the classes it imports by their short name (`use A\B\C as D` → D: A\B\C).
struct CodeFileOutline: Equatable, Sendable {
    var symbols: [CodeSymbol] = []
    var imports: [String: String] = [:]
    var namespace: String?
}

private enum Family { case php, js, swift, python, go, ruby, jvm, rust, c, none }

private func family(_ language: CodeLanguage) -> Family {
    switch language.name {
    case "PHP": return .php
    case "JavaScript", "TypeScript", "Vue", "Svelte": return .js
    case "Swift": return .swift
    case "Python": return .python
    case "Go": return .go
    case "Ruby": return .ruby
    case "Java", "Kotlin", "C#", "Dart", "Scala", "Groovy": return .jvm
    case "Rust": return .rust
    case "C", "C++", "Objective-C": return .c
    default: return .none
    }
}

/// Whether the index reads a file of this name at all.
func codeOutlineSupported(_ path: String) -> Bool { family(CodeLanguage.of(path)) != .none }

/// What `text`, the file at `path`, declares.
func codeOutline(_ text: String, path: String) -> CodeFileOutline {
    let language = CodeLanguage.of(path)
    let fam = family(language)
    guard fam != .none else { return CodeFileOutline() }
    let tokens = codeHighlight(text, language: language)
    var reader = OutlineReader(family: fam, path: path)
    for (i, line) in tokens.enumerated() { reader.read(line, number: i + 1) }
    return reader.outline
}

// MARK: - The reader

private struct Pattern {
    let regex: NSRegularExpression
    init(_ source: String) { regex = try! NSRegularExpression(pattern: source) }
    /// The capture groups of the first match, "" for a group that took no part.
    func match(_ s: String) -> [String]? {
        let ns = s as NSString
        guard let m = regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }
}

private enum P {
    static let phpNamespace = Pattern(#"^\s*namespace\s+([\w\\]+)"#)
    static let phpUse = Pattern(#"^\s*use\s+\\?([\w\\]+)(?:\s+as\s+(\w+))?\s*;"#)
    static let phpType = Pattern(#"\b(class|interface|trait|enum)\s+(\w+)"#)
    static let phpFunction = Pattern(#"\bfunction\s+&?(\w+)\s*\("#)
    static let phpConst = Pattern(#"\bconst\s+(?:\w+\s+)?(\w+)\s*="#)
    static let phpProperty = Pattern(#"^\s*(?:(?:public|protected|private|var|static|readonly)\s+)+(?:\??[\w\\|]+\s+)?\$(\w+)"#)
    static let phpCase = Pattern(#"^\s*case\s+(\w+)\s*[=;]"#)

    static let jsClass = Pattern(#"\bclass\s+(\w+)"#)
    static let jsKind = Pattern(#"^\s*(?:export\s+)?(?:declare\s+)?(interface|enum)\s+(\w+)"#)
    static let jsType = Pattern(#"^\s*(?:export\s+)?type\s+(\w+)\s*(?:<[^=]*>)?\s*="#)
    static let jsFunction = Pattern(#"\bfunction\s*\*?\s*(\w+)\s*[<(]"#)
    static let jsArrow = Pattern(#"^\s*(?:export\s+)?(?:const|let|var)\s+(\w+)\s*(?::[^=]+)?=\s*(?:async\s+)?(?:function\b|\([^)]*\)\s*(?::[^=]+)?=>|\w+\s*=>)"#)
    static let jsConst = Pattern(#"^(?:export\s+)?const\s+(\w+)\s*(?::[^=]+)?="#)
    static let jsMethod = Pattern(#"^\s*(?:(?:public|private|protected|static|async|readonly|get|set|override|abstract|declare)\s+)*\*?#?(\w+)\s*(?:<[^>]*>)?\s*\("#)
    static let jsField = Pattern(#"^\s*(?:(?:public|private|protected|static|readonly|declare|override)\s+)*#?(\w+)\s*[?!]?\s*[:=]"#)

    static let swiftType = Pattern(#"\b(class|struct|enum|protocol|actor|extension)\s+(\w+)"#)
    static let swiftFunction = Pattern(#"\bfunc\s+([^\s(<]+)"#)
    static let swiftInit = Pattern(#"^\s*(?:(?:public|private|fileprivate|internal|open|convenience|required|override)\s+)*(init)[?!]?\s*[(<]"#)
    static let swiftProperty = Pattern(#"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|private|fileprivate|internal|open|static|class|final|lazy|weak|override|nonisolated)\s+|private\(set\)\s+)*(?:let|var)\s+(\w+)"#)
    static let swiftAlias = Pattern(#"\btypealias\s+(\w+)"#)
    static let swiftCase = Pattern(#"^\s*case\s+(\w+)"#)

    static let pyClass = Pattern(#"^(\s*)class\s+(\w+)"#)
    static let pyDef = Pattern(#"^(\s*)(?:async\s+)?def\s+(\w+)"#)
    static let pyConst = Pattern(#"^([A-Z_][A-Z0-9_]*)\s*(?::[^=]+)?="#)

    static let goType = Pattern(#"^type\s+(\w+)\s+(struct|interface)?"#)
    static let goFunc = Pattern(#"^func\s+(?:\(\s*\w*\s*\*?(\w+)[^)]*\)\s*)?(\w+)\s*[(\[]"#)
    static let goConst = Pattern(#"^(?:const|var)\s+(\w+)"#)

    static let rbType = Pattern(#"^(\s*)(class|module)\s+([\w:]+)"#)
    static let rbDef = Pattern(#"^(\s*)def\s+(?:self\.)?(\w+[?!=]?)"#)

    static let jvmType = Pattern(#"\b(class|interface|enum|record|object|trait)\s+(\w+)"#)
    static let jvmFun = Pattern(#"\bfun\s+(?:<[^>]*>\s*)?(?:[\w.]+\.)?(\w+)\s*\("#)
    static let jvmMethod = Pattern(#"^\s*(?:@\w+\s+)*(?:(?:public|private|protected|internal|static|final|abstract|synchronized|override|virtual|async|native|default|sealed|open|suspend)\s+)+(?:<[^>]*>\s*)?[\w<>\[\],.?]+\s+(\w+)\s*\("#)
    static let jvmConst = Pattern(#"^\s*(?:(?:public|private|protected|internal|static|final|const)\s+)+(?:[\w<>\[\],.?]+\s+)?([A-Z][A-Z0-9_]*)\s*="#)

    static let rustType = Pattern(#"\b(struct|enum|trait|type|union)\s+(\w+)"#)
    static let rustImpl = Pattern(#"\bimpl(?:<[^>]*>)?\s+(?:[\w:<>]+\s+for\s+)?(\w+)"#)
    static let rustFn = Pattern(#"\bfn\s+(\w+)"#)
    static let rustConst = Pattern(#"^\s*(?:pub(?:\([^)]*\))?\s+)?(?:const|static)\s+(\w+)\s*:"#)

    static let cType = Pattern(#"^\s*(?:typedef\s+)?(class|struct|enum|union)\s+(\w+)\s*(?:[:{]|$)"#)
    static let cFunction = Pattern(#"^[A-Za-z_][\w\s\*&:<>,]*?\b([A-Za-z_]\w*)\s*\([^;]*$"#)
    static let cDefine = Pattern(#"^\s*#\s*define\s+(\w+)"#)
    static let objcType = Pattern(#"^\s*@(interface|protocol|implementation)\s+(\w+)"#)
}

private let notNames: Set<String> = ["if", "for", "while", "switch", "catch", "return", "function", "else", "do", "try", "with",
                                     "new", "await", "typeof", "constructor", "super", "this", "sizeof", "defined"]

private struct OutlineReader {
    let family: Family
    let path: String
    var outline = CodeFileOutline()

    /// The types open around the current line: name, kind, and the brace depth (or indentation) they opened at.
    private var stack: [(name: String, depth: Int)] = []
    private var depth = 0
    /// The comment lines just above, to be a declaration's doc.
    private var comment: [String] = []

    init(family: Family, path: String) { self.family = family; self.path = path }

    mutating func read(_ tokens: [CodeToken], number: Int) {
        let original = tokens.map(\.text).joined()
        // The code alone: strings and comments blanked, so a word in either is not taken for a declaration.
        let code = tokens.map { t -> String in
            switch t.kind {
            case .comment: return String(repeating: " ", count: t.text.count)
            case .string: return t.text.isEmpty ? "" : String(t.text.first!) + String(repeating: " ", count: max(t.text.count - 2, 0)) + (t.text.count > 1 ? String(t.text.last!) : "")
            default: return t.text
            }
        }.joined()
        let blank = code.trimmingCharacters(in: .whitespaces).isEmpty
        let commentText = tokens.filter { $0.kind == .comment }.map(\.text).joined()
        if blank {
            // A comment line adds to the doc; a blank line between a comment and a declaration parts them.
            if commentText.isEmpty { comment = [] } else { comment.append(commentText) }
            return
        }
        // Python's docstring and Ruby's indentation have no braces: the types close by indentation instead.
        if family == .python || family == .ruby {
            let indent = original.prefix { $0 == " " || $0 == "\t" }.count
            while let top = stack.last, indent <= top.depth { stack.removeLast() }
        }
        declare(code: code, original: original, number: number)
        comment = []
        if family != .python && family != .ruby { braces(code) }
    }

    /// Opens and closes the braces of a line; a type declared on it opened at the depth before them.
    private mutating func braces(_ code: String) {
        for c in code {
            if c == "{" { depth += 1 }
            else if c == "}" {
                depth = max(depth - 1, 0)
                while let top = stack.last, depth <= top.depth { stack.removeLast() }
            }
        }
    }

    private var container: String? { stack.last?.name }
    /// Whether the current line is directly inside the innermost type's body.
    private var inTypeBody: Bool { stack.last.map { depth == $0.depth + 1 } ?? false }

    private mutating func add(_ name: String, _ kind: CodeSymbolKind, _ original: String, _ number: Int, container: String? = nil, topLevel: Bool = false) {
        guard !name.isEmpty, !notNames.contains(name) else { return }
        var signature = original.trimmingCharacters(in: .whitespaces)
        if let brace = signature.firstIndex(of: "{"), signature.distance(from: signature.startIndex, to: brace) > 0 {
            signature = String(signature[..<brace]).trimmingCharacters(in: .whitespaces)
        }
        if signature.count > 160 { signature = String(signature.prefix(159)) + "…" }
        outline.symbols.append(CodeSymbol(name: name, kind: kind, container: topLevel ? nil : (container ?? self.container),
                                          namespace: outline.namespace, path: path, line: number, signature: signature, doc: docText()))
    }
    private mutating func open(_ name: String, indent: Int? = nil) { stack.append((name, indent ?? depth)) }

    private func docText() -> String? {
        guard !comment.isEmpty else { return nil }
        let lines = comment.map { line -> String in
            var l = line.trimmingCharacters(in: .whitespaces)
            for marker in ["/**", "/*", "*/", "///", "//", "#", "--", "*"] where l.hasPrefix(marker) { l = String(l.dropFirst(marker.count)); break }
            if l.hasSuffix("*/") { l = String(l.dropLast(2)) }
            return l.trimmingCharacters(in: .whitespaces)
        }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private mutating func declare(code: String, original: String, number: Int) {
        switch family {
        case .php: php(code, original, number)
        case .js: js(code, original, number)
        case .swift: swift(code, original, number)
        case .python: python(code, original, number)
        case .go: go(code, original, number)
        case .ruby: ruby(code, original, number)
        case .jvm: jvm(code, original, number)
        case .rust: rust(code, original, number)
        case .c: c(code, original, number)
        case .none: break
        }
    }

    // MARK: Languages

    private mutating func php(_ code: String, _ o: String, _ n: Int) {
        if let m = P.phpNamespace.match(code) { outline.namespace = m[1]; return }
        if stack.isEmpty, let m = P.phpUse.match(code) {
            let fqn = m[1]
            let alias = m[2].isEmpty ? String(fqn.split(separator: "\\").last ?? Substring(fqn)) : m[2]
            outline.imports[alias] = fqn
            return
        }
        if let m = P.phpType.match(code), !code.contains("::class"), !code.contains("new class") {
            let kind: CodeSymbolKind = m[1] == "interface" ? .interface : m[1] == "trait" ? .trait : m[1] == "enum" ? .enum : .class
            add(m[2], kind, o, n, topLevel: true)
            open(m[2])
            return
        }
        if let m = P.phpFunction.match(code) { add(m[1], inTypeBody ? .method : .function, o, n, topLevel: !inTypeBody); return }
        if let m = P.phpConst.match(code) { add(m[1], .constant, o, n, topLevel: !inTypeBody); return }
        if inTypeBody, let m = P.phpProperty.match(code) { add(m[1], .property, o, n); return }
        if inTypeBody, let m = P.phpCase.match(code) { add(m[1], .constant, o, n) }
    }

    private mutating func js(_ code: String, _ o: String, _ n: Int) {
        if let m = P.jsClass.match(code) { add(m[1], .class, o, n, topLevel: true); open(m[1]); return }
        if let m = P.jsKind.match(code) { add(m[2], m[1] == "enum" ? .enum : .interface, o, n, topLevel: true); open(m[2]); return }
        if let m = P.jsType.match(code) { add(m[1], .type, o, n, topLevel: true); return }
        if let m = P.jsFunction.match(code) { add(m[1], inTypeBody ? .method : .function, o, n, topLevel: !inTypeBody); return }
        if let m = P.jsArrow.match(code) { add(m[1], inTypeBody ? .method : .function, o, n, topLevel: !inTypeBody); return }
        if inTypeBody {
            if let m = P.jsMethod.match(code), code.contains("{") || code.hasSuffix(";") == false { add(m[1], .method, o, n); return }
            if let m = P.jsField.match(code) { add(m[1], .property, o, n) }
            return
        }
        if depth == 0, let m = P.jsConst.match(code) { add(m[1], .constant, o, n, topLevel: true) }
    }

    private mutating func swift(_ code: String, _ o: String, _ n: Int) {
        if let m = P.swiftType.match(code), !code.contains("func ") {
            let kind: CodeSymbolKind = ["class": .class, "struct": .struct, "enum": .enum, "protocol": .protocol, "actor": .class][m[1]] ?? .class
            // An extension adds to a type declared elsewhere: its members are that type's, but it is no type of its own.
            if m[1] != "extension" { add(m[2], kind, o, n, topLevel: stack.isEmpty) }
            open(m[2])
            return
        }
        if let m = P.swiftFunction.match(code) { add(m[1], inTypeBody ? .method : .function, o, n, topLevel: !inTypeBody); return }
        if inTypeBody, let m = P.swiftInit.match(code) { add(m[1], .method, o, n); return }
        if let m = P.swiftAlias.match(code) { add(m[1], .type, o, n, topLevel: !inTypeBody); return }
        if inTypeBody, let m = P.swiftCase.match(code) { add(m[1], .constant, o, n); return }
        if inTypeBody || depth == 0, let m = P.swiftProperty.match(code) { add(m[1], inTypeBody ? .property : .constant, o, n, topLevel: !inTypeBody) }
    }

    private mutating func python(_ code: String, _ o: String, _ n: Int) {
        if let m = P.pyClass.match(code) { add(m[2], .class, o, n); open(m[2], indent: m[1].count); return }
        if let m = P.pyDef.match(code) {
            let inside = stack.last.map { m[1].count > $0.depth } ?? false
            add(m[2], inside ? .method : .function, o, n, topLevel: !inside)
            return
        }
        if stack.isEmpty, let m = P.pyConst.match(code) { add(m[1], .constant, o, n, topLevel: true) }
    }

    private mutating func go(_ code: String, _ o: String, _ n: Int) {
        if let m = P.goType.match(code) { add(m[1], m[2] == "interface" ? .interface : m[2] == "struct" ? .struct : .type, o, n, topLevel: true); return }
        if let m = P.goFunc.match(code) {
            if m[1].isEmpty { add(m[2], .function, o, n, topLevel: true) } else { add(m[2], .method, o, n, container: m[1]) }
            return
        }
        if depth == 0, let m = P.goConst.match(code) { add(m[1], .constant, o, n, topLevel: true) }
    }

    private mutating func ruby(_ code: String, _ o: String, _ n: Int) {
        if let m = P.rbType.match(code) {
            let name = String(m[3].split(separator: ":").last ?? Substring(m[3]))
            add(name, m[2] == "module" ? .module : .class, o, n)
            open(name, indent: m[1].count)
            return
        }
        if let m = P.rbDef.match(code) {
            let inside = stack.last.map { m[1].count > $0.depth } ?? false
            add(m[2], inside ? .method : .function, o, n, topLevel: !inside)
        }
    }

    private mutating func jvm(_ code: String, _ o: String, _ n: Int) {
        if let m = P.jvmType.match(code), !code.contains(".class") {
            let kind: CodeSymbolKind = ["interface": .interface, "enum": .enum, "trait": .trait][m[1]] ?? .class
            add(m[2], kind, o, n, topLevel: stack.isEmpty)
            open(m[2])
            return
        }
        if let m = P.jvmFun.match(code) { add(m[1], inTypeBody ? .method : .function, o, n, topLevel: !inTypeBody); return }
        if inTypeBody, let m = P.jvmConst.match(code) { add(m[1], .constant, o, n); return }
        if inTypeBody, let m = P.jvmMethod.match(code) { add(m[1], .method, o, n) }
    }

    private mutating func rust(_ code: String, _ o: String, _ n: Int) {
        if let m = P.rustType.match(code), !code.contains("fn ") {
            let kind: CodeSymbolKind = ["struct": .struct, "enum": .enum, "trait": .trait, "union": .struct][m[1]] ?? .type
            add(m[2], kind, o, n, topLevel: true)
            if m[1] == "trait" { open(m[2]) }
            return
        }
        if let m = P.rustImpl.match(code), code.trimmingCharacters(in: .whitespaces).hasPrefix("impl") { open(m[1]); return }
        if let m = P.rustFn.match(code) { add(m[1], inTypeBody ? .method : .function, o, n, topLevel: !inTypeBody); return }
        if let m = P.rustConst.match(code) { add(m[1], .constant, o, n, topLevel: !inTypeBody) }
    }

    private mutating func c(_ code: String, _ o: String, _ n: Int) {
        if let m = P.cDefine.match(code) { add(m[1], .constant, o, n, topLevel: true); return }
        if let m = P.objcType.match(code) {
            if m[1] != "implementation" { add(m[2], m[1] == "protocol" ? .protocol : .class, o, n, topLevel: true) }
            return
        }
        if let m = P.cType.match(code) {
            add(m[2], m[1] == "class" ? .class : m[1] == "enum" ? .enum : .struct, o, n, topLevel: stack.isEmpty)
            open(m[2])
            return
        }
        if depth == 0 || inTypeBody, let m = P.cFunction.match(code), !code.contains("="), !code.hasPrefix(" ") || inTypeBody {
            add(m[1], inTypeBody ? .method : .function, o, n, topLevel: !inTypeBody)
        }
    }
}
