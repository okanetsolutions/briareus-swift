// The colours of a source file in the Files tab: a small lexer per family of languages, picked by the file's name, that
// marks comments, strings, numbers, keywords and type names. It reads the whole file once, carrying a block comment or
// a multi-line string from one line into the next, and answers each line's runs; what it does not know stays plain.
import Foundation

enum CodeTokenKind: Equatable, Sendable { case plain, keyword, string, comment, number, type, variable }

struct CodeToken: Equatable, Sendable {
    var text: String
    var kind: CodeTokenKind
}

struct CodeLanguage: Equatable, Sendable {
    var name: String
    var lineComments: [String] = []
    var blockComment: (open: String, close: String)? = nil
    /// Quotes that open a string ending on the same line.
    var quotes: [Character] = ["\"", "'"]
    /// Delimiters of strings that may run across lines: """ in Python and Swift, the backtick in JavaScript.
    var multiline: [String] = []
    var keywords: Set<String> = []
    /// `$name` reads as a variable (PHP, shell).
    var dollarVariables = false
    /// Capitalised words read as type names.
    var types = true

    static func == (a: CodeLanguage, b: CodeLanguage) -> Bool { a.name == b.name }

    static let plain = CodeLanguage(name: "Text", quotes: [], types: false)

    /// The language a file is read in, from its name; plain text when none fits.
    static func of(_ path: String) -> CodeLanguage {
        let name = repoBasename(path).lowercased()
        switch name {
        case "dockerfile", "containerfile": return shell(named: "Dockerfile", extra: ["from", "run", "cmd", "copy", "add", "env", "arg", "workdir", "expose", "entrypoint", "user", "volume", "label", "as"])
        case "makefile", "gnumakefile": return shell(named: "Makefile")
        case ".env", ".gitignore", ".dockerignore", ".editorconfig", ".npmrc": return CodeLanguage(name: "Config", lineComments: ["#"], types: false)
        default: break
        }
        if name.hasSuffix(".blade.php") { return markup(named: "Blade") }
        let ext = name.contains(".") ? String(name[name.index(after: name.lastIndex(of: ".")!)...]) : ""
        switch ext {
        case "swift": return cLike("Swift", swift, multiline: ["\"\"\""], quotes: ["\""])
        case "php", "phtml": return cLike("PHP", php, lineComments: ["//", "#"], dollar: true)
        case "js", "mjs", "cjs", "jsx": return cLike("JavaScript", javascript, multiline: ["`"])
        case "ts", "mts", "cts", "tsx": return cLike("TypeScript", javascript.union(typescript), multiline: ["`"])
        case "java": return cLike("Java", java, multiline: ["\"\"\""])
        case "kt", "kts": return cLike("Kotlin", kotlin, multiline: ["\"\"\""])
        case "go": return cLike("Go", go, multiline: ["`"])
        case "rs": return cLike("Rust", rust, quotes: ["\""])
        case "c", "h": return cLike("C", c)
        case "cc", "cpp", "cxx", "hpp", "hh", "hxx": return cLike("C++", c.union(cpp))
        case "m", "mm": return cLike("Objective-C", c.union(objc))
        case "cs": return cLike("C#", csharp)
        case "dart": return cLike("Dart", dart, multiline: ["'''", "\"\"\""])
        case "scala": return cLike("Scala", kotlin, multiline: ["\"\"\""])
        case "py", "pyi": return CodeLanguage(name: "Python", lineComments: ["#"], multiline: ["\"\"\"", "'''"], keywords: python)
        case "rb", "rake", "gemspec": return CodeLanguage(name: "Ruby", lineComments: ["#"], keywords: ruby)
        case "sh", "bash", "zsh", "fish", "command": return shell(named: "Shell")
        case "yml", "yaml": return CodeLanguage(name: "YAML", lineComments: ["#"], keywords: ["true", "false", "null", "yes", "no", "on", "off"], types: false)
        case "toml", "ini", "cfg", "conf", "properties": return CodeLanguage(name: "Config", lineComments: ["#", ";"], keywords: ["true", "false"], types: false)
        case "json", "jsonc", "json5", "lock": return CodeLanguage(name: "JSON", lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\""], keywords: ["true", "false", "null"], types: false)
        case "sql": return CodeLanguage(name: "SQL", lineComments: ["--", "#"], blockComment: ("/*", "*/"), quotes: ["'", "\"", "`"], keywords: sql, types: false)
        case "html", "htm", "xml", "svg", "plist", "vue", "svelte", "xib", "storyboard": return markup(named: ext == "vue" ? "Vue" : ext == "svelte" ? "Svelte" : ext == "html" || ext == "htm" ? "HTML" : "XML")
        case "css", "scss", "sass", "less": return CodeLanguage(name: ext.uppercased(), lineComments: ext == "css" ? [] : ["//"], blockComment: ("/*", "*/"), keywords: css, types: false)
        case "md", "markdown", "txt", "rst": return .plain
        case "lua": return CodeLanguage(name: "Lua", lineComments: ["--"], blockComment: ("--[[", "]]"), keywords: lua)
        case "ex", "exs": return CodeLanguage(name: "Elixir", lineComments: ["#"], multiline: ["\"\"\""], keywords: elixir)
        case "gradle", "groovy": return cLike("Groovy", kotlin.union(java), multiline: ["\"\"\"", "'''"])
        default: return .plain
        }
    }

    private static func cLike(_ name: String, _ keywords: Set<String>, lineComments: [String] = ["//"], multiline: [String] = [],
                              quotes: [Character] = ["\"", "'"], dollar: Bool = false) -> CodeLanguage {
        CodeLanguage(name: name, lineComments: lineComments, blockComment: ("/*", "*/"), quotes: quotes, multiline: multiline,
                     keywords: keywords, dollarVariables: dollar)
    }
    private static func shell(named name: String, extra: Set<String> = []) -> CodeLanguage {
        CodeLanguage(name: name, lineComments: ["#"], keywords: shellWords.union(extra), dollarVariables: true, types: false)
    }
    private static func markup(named name: String) -> CodeLanguage {
        CodeLanguage(name: name, blockComment: ("<!--", "-->"), quotes: ["\"", "'"], types: false)
    }

    private static let swift: Set<String> = ["actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue", "default", "defer", "deinit", "do", "else", "enum", "extension", "fallthrough", "false", "fileprivate", "final", "for", "func", "guard", "if", "import", "in", "init", "inout", "internal", "is", "lazy", "let", "mutating", "nil", "nonisolated", "open", "operator", "override", "private", "protocol", "public", "repeat", "rethrows", "return", "self", "Self", "some", "static", "struct", "subscript", "super", "switch", "throw", "throws", "true", "try", "typealias", "var", "weak", "where", "while", "willSet", "didSet", "get", "set"]
    private static let php: Set<String> = ["abstract", "and", "array", "as", "break", "callable", "case", "catch", "class", "clone", "const", "continue", "declare", "default", "do", "echo", "else", "elseif", "empty", "enum", "extends", "false", "final", "finally", "fn", "for", "foreach", "function", "global", "if", "implements", "include", "include_once", "instanceof", "insteadof", "interface", "isset", "list", "match", "namespace", "new", "null", "or", "print", "private", "protected", "public", "readonly", "require", "require_once", "return", "self", "static", "parent", "switch", "throw", "trait", "true", "try", "unset", "use", "var", "while", "xor", "yield", "int", "string", "bool", "float", "void", "mixed", "never", "object", "iterable"]
    private static let javascript: Set<String> = ["async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else", "export", "extends", "false", "finally", "for", "from", "function", "get", "if", "import", "in", "instanceof", "let", "new", "null", "of", "return", "set", "static", "super", "switch", "this", "throw", "true", "try", "typeof", "undefined", "var", "void", "while", "with", "yield"]
    private static let typescript: Set<String> = ["abstract", "any", "as", "boolean", "declare", "enum", "implements", "interface", "keyof", "namespace", "never", "number", "private", "protected", "public", "readonly", "satisfies", "string", "type", "unknown"]
    private static let java: Set<String> = ["abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class", "const", "continue", "default", "do", "double", "else", "enum", "extends", "false", "final", "finally", "float", "for", "if", "implements", "import", "instanceof", "int", "interface", "long", "new", "null", "package", "private", "protected", "public", "record", "return", "short", "static", "super", "switch", "synchronized", "this", "throw", "throws", "true", "try", "var", "void", "volatile", "while"]
    private static let kotlin: Set<String> = ["as", "break", "class", "companion", "continue", "data", "do", "else", "enum", "false", "for", "fun", "if", "import", "in", "interface", "internal", "is", "lateinit", "null", "object", "open", "override", "package", "private", "protected", "public", "return", "sealed", "super", "suspend", "this", "throw", "true", "try", "typealias", "val", "var", "when", "while", "def", "new"]
    private static let go: Set<String> = ["break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "false", "for", "func", "go", "goto", "if", "import", "interface", "iota", "map", "nil", "package", "range", "return", "select", "struct", "switch", "true", "type", "var"]
    private static let rust: Set<String> = ["as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while"]
    private static let c: Set<String> = ["auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long", "register", "return", "short", "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void", "volatile", "while", "NULL", "true", "false", "bool", "#include", "#define", "#ifdef", "#ifndef", "#endif", "#if", "#else", "#pragma"]
    private static let cpp: Set<String> = ["class", "namespace", "template", "typename", "public", "private", "protected", "virtual", "override", "new", "delete", "this", "nullptr", "using", "try", "catch", "throw", "constexpr", "auto", "noexcept"]
    private static let objc: Set<String> = ["@interface", "@implementation", "@end", "@property", "@protocol", "@class", "self", "nil", "YES", "NO", "id"]
    private static let csharp: Set<String> = ["abstract", "as", "async", "await", "base", "bool", "break", "case", "catch", "class", "const", "continue", "default", "do", "else", "enum", "false", "finally", "for", "foreach", "if", "in", "int", "interface", "internal", "is", "namespace", "new", "null", "out", "override", "private", "protected", "public", "readonly", "record", "ref", "return", "sealed", "static", "string", "struct", "switch", "this", "throw", "true", "try", "using", "var", "virtual", "void", "while"]
    private static let dart: Set<String> = ["abstract", "as", "async", "await", "break", "case", "catch", "class", "const", "continue", "default", "do", "else", "enum", "extends", "false", "final", "finally", "for", "if", "implements", "import", "in", "is", "late", "new", "null", "required", "return", "super", "switch", "this", "throw", "true", "try", "var", "void", "while", "with"]
    private static let python: Set<String> = ["and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "False", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "None", "nonlocal", "not", "or", "pass", "raise", "return", "self", "True", "try", "while", "with", "yield"]
    private static let ruby: Set<String> = ["alias", "and", "begin", "break", "case", "class", "def", "defined?", "do", "else", "elsif", "end", "ensure", "false", "for", "if", "in", "module", "next", "nil", "not", "or", "redo", "rescue", "retry", "return", "self", "super", "then", "true", "undef", "unless", "until", "when", "while", "yield", "require", "attr_accessor", "attr_reader"]
    private static let shellWords: Set<String> = ["if", "then", "else", "elif", "fi", "case", "esac", "for", "while", "until", "do", "done", "in", "function", "return", "export", "local", "readonly", "set", "unset", "echo", "exit", "source", "true", "false"]
    private static let sql: Set<String> = Set(["select", "from", "where", "and", "or", "not", "insert", "into", "values", "update", "set", "delete", "create", "table", "alter", "drop", "index", "primary", "key", "foreign", "references", "join", "left", "right", "inner", "outer", "on", "as", "group", "by", "order", "having", "limit", "offset", "null", "is", "in", "like", "distinct", "union", "all", "case", "when", "then", "else", "end", "default", "unique", "constraint", "exists", "if", "begin", "commit", "rollback", "int", "varchar", "text", "boolean", "timestamp", "true", "false"].flatMap { [$0, $0.uppercased()] })
    private static let css: Set<String> = ["!important", "@media", "@import", "@keyframes", "@font-face", "@supports", "@apply", "@tailwind", "@layer", "@use", "@mixin", "@include"]
    private static let lua: Set<String> = ["and", "break", "do", "else", "elseif", "end", "false", "for", "function", "if", "in", "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while"]
    private static let elixir: Set<String> = ["def", "defp", "defmodule", "do", "end", "fn", "if", "else", "case", "cond", "with", "true", "false", "nil", "when", "import", "alias", "use", "require"]
}

/// Each line's runs, in order; joined, a line's runs give the line back.
func codeHighlight(_ text: String, language: CodeLanguage) -> [[CodeToken]] {
    var lexer = CodeLexer(language: language)
    // "\r\n" is one Character in Swift, so it is a line's end of its own.
    return text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }).map { lexer.line(Array($0)) }
}

private struct CodeLexer {
    let language: CodeLanguage
    /// What a line opens and the next one goes on in: a block comment, or a string ending in the delimiter held.
    private var openComment = false
    private var openString: String?

    init(language: CodeLanguage) { self.language = language }

    mutating func line(_ s: [Character]) -> [CodeToken] {
        var out: [CodeToken] = []
        func emit(_ chars: ArraySlice<Character>, _ kind: CodeTokenKind) {
            guard !chars.isEmpty else { return }
            if let last = out.last, last.kind == kind { out[out.count - 1].text += String(chars) }
            else { out.append(CodeToken(text: String(chars), kind: kind)) }
        }
        var i = 0
        // Carried over from the line before.
        if openComment, let block = language.blockComment {
            if let end = find(block.close, in: s, from: 0) { emit(s[0..<end], .comment); i = end; openComment = false }
            else { emit(s[...], .comment); return out }
        } else if let delim = openString {
            if let end = find(delim, in: s, from: 0, escapes: true) { emit(s[0..<end], .string); i = end; openString = nil }
            else { emit(s[...], .string); return out }
        }
        var plainStart = i
        func flushPlain(to end: Int) { emit(s[plainStart..<end], .plain) }
        while i < s.count {
            let c = s[i]
            // Comments to the end of the line.
            if let lc = language.lineComments.first(where: { matches($0, s, i) }), lc != "#" || i == 0 || !s[i - 1].isLetter && s[i - 1] != "$" {
                flushPlain(to: i); emit(s[i...], .comment); return out
            }
            if let block = language.blockComment, matches(block.open, s, i) {
                flushPlain(to: i)
                if let end = find(block.close, in: s, from: i + block.open.count) { emit(s[i..<end], .comment); i = end }
                else { emit(s[i...], .comment); openComment = true; return out }
                plainStart = i; continue
            }
            if let delim = language.multiline.first(where: { matches($0, s, i) }) {
                flushPlain(to: i)
                if let end = find(delim, in: s, from: i + delim.count, escapes: true) { emit(s[i..<end], .string); i = end }
                else { emit(s[i...], .string); openString = delim; return out }
                plainStart = i; continue
            }
            if language.quotes.contains(c) {
                flushPlain(to: i)
                let end = find(String(c), in: s, from: i + 1, escapes: true) ?? s.count
                emit(s[i..<end], .string); i = end
                plainStart = i; continue
            }
            if language.dollarVariables && c == "$" && i + 1 < s.count && (s[i + 1].isLetter || s[i + 1] == "_" || s[i + 1] == "{") {
                flushPlain(to: i)
                var j = i + 1
                if s[j] == "{" { while j < s.count && s[j] != "}" { j += 1 }; j = min(j + 1, s.count) }
                else { while j < s.count && (s[j].isLetter || s[j].isNumber || s[j] == "_") { j += 1 } }
                emit(s[i..<j], .variable); i = j
                plainStart = i; continue
            }
            if c.isNumber && (i == 0 || !isWordChar(s[i - 1])) {
                flushPlain(to: i)
                var j = i + 1
                while j < s.count && (s[j].isHexDigit || s[j] == "." || s[j] == "_" || s[j] == "x" || s[j] == "X") { j += 1 }
                emit(s[i..<j], .number); i = j
                plainStart = i; continue
            }
            if isWordStartChar(c) && (i == 0 || !isWordChar(s[i - 1])) {
                var j = i + 1
                while j < s.count && isWordChar(s[j]) { j += 1 }
                // A keyword may end in ? (Ruby's defined?).
                if j < s.count && s[j] == "?" && language.keywords.contains(String(s[i...j])) { j += 1 }
                let word = String(s[i..<j])
                if language.keywords.contains(word) { flushPlain(to: i); emit(s[i..<j], .keyword); plainStart = j }
                else if language.types, let first = word.first(where: { $0 != "@" && $0 != "#" }), first.isUppercase, word.contains(where: \.isLowercase) {
                    flushPlain(to: i); emit(s[i..<j], .type); plainStart = j
                }
                i = j; continue
            }
            i += 1
        }
        flushPlain(to: s.count)
        return out
    }

    private func isWordStartChar(_ c: Character) -> Bool { c.isLetter || c == "_" || c == "@" || c == "#" }
    private func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
    private func matches(_ token: String, _ s: [Character], _ i: Int) -> Bool {
        var j = i
        for t in token { guard j < s.count, s[j] == t else { return false }; j += 1 }
        return true
    }
    /// Where `token` ends (the index after it) from `from` on, a backslash escaping the character after it when `escapes`.
    private func find(_ token: String, in s: [Character], from: Int, escapes: Bool = false) -> Int? {
        var i = from
        while i < s.count {
            if escapes && s[i] == "\\" { i += 2; continue }
            if matches(token, s, i) { return i + token.count }
            i += 1
        }
        return nil
    }
}
