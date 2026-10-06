// The Database tab's SQL over SSH (the Windows client's app/ssh_query.c, its pure half): the server's own `mysql` client
// is started over SSH, reading the password and then the statements from its standard input, so neither shows on a
// command line; what it prints with --batch is split into cells here, and names and logins are quoted on the way in.
import Foundation

/// Where the database listens as seen from the SSH server, and the login it takes.
struct SQLLogin: Equatable, Sendable {
    var host: String
    var port: Int
    var user: String
    var password: String

    /// The remote command ssh is given: the first line in is the password, which mysql reads from MYSQL_PWD, and the
    /// statements are the rest.
    var remoteCommand: String {
        let h = shQuote(host.isEmpty ? "127.0.0.1" : host), u = shQuote(user)
        return "IFS= read -r MYSQL_PWD; export MYSQL_PWD; exec mysql --batch --default-character-set=utf8mb4 -h \(h) -P \(port > 0 ? port : 3306) -u \(u)"
    }
    /// What goes in on standard input: the password line, then the statements.
    func input(_ sql: String) -> String { "\(password)\n\(sql)\n" }
}

/// `mysql --batch` output split into rows of fields, the first row the column names, with \t \n \\ \0 unescaped.
struct SQLTable: Equatable, Sendable {
    private(set) var cells: [[String]] = []
    private(set) var cols = 0
    var rows: Int { cells.count }

    init() {}
    init(_ out: String) {
        var lines = Array(out.unicodeScalars).split(separator: "\n", omittingEmptySubsequences: false)
        // The text after the last line end, when empty, is no line.
        if lines.last?.isEmpty == true { lines.removeLast() }
        for piece in lines {
            var line = Array(piece)
            if line.last == "\r" { line.removeLast() }
            if cells.isEmpty { cols = line.filter { $0 == "\t" }.count + 1 }
            guard !line.isEmpty || cols == 1 else { continue }
            // A row shorter than the header has its missing fields empty; the last field takes the rest of a longer one.
            var row: [String] = []
            var rest = line[...]
            var more = true
            for c in 0..<cols {
                guard more else { row.append(""); continue }
                if c + 1 < cols, let tab = rest.firstIndex(of: "\t") {
                    row.append(Self.unescape(rest[..<tab]))
                    rest = rest[(tab + 1)...]
                } else {
                    row.append(Self.unescape(rest))
                    more = false
                }
            }
            cells.append(row)
        }
    }
    func cell(_ row: Int, _ col: Int) -> String { cells[row][col] }

    private static func unescape(_ s: ArraySlice<Unicode.Scalar>) -> String {
        var out = String.UnicodeScalarView()
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c != "\\" || i + 1 == s.endIndex { out.append(c); i += 1; continue }
            let e = s[i + 1]
            out.append(e == "n" ? "\n" : e == "t" ? "\t" : e == "0" ? " " : e)
            i += 2
        }
        return String(out)
    }
}

/// A name as a MySQL identifier: in backticks, any backtick doubled.
func sqlIdent(_ name: String) -> String { "`" + name.replacingOccurrences(of: "`", with: "``") + "`" }

/// A string quoted for a POSIX shell: in single quotes, any single quote closed, quoted in double quotes and reopened.
func shQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
