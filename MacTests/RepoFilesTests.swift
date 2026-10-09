import XCTest
@testable import BriareusMacCore

final class RepoFilesTests: XCTestCase {
    private func tree(_ paths: [String]) -> RepoTree {
        RepoTree(ref: "main", entries: paths.map { $0.hasSuffix("/") ? RepoEntry(path: String($0.dropLast()), folder: true) : RepoEntry(path: $0, folder: false) })
    }

    func testFoldersComeFirstAndNamesSortAsPeopleSortThem() {
        let t = tree(["b.txt", "src/", "a10.js", "a2.js", "docs/", "src/x.swift", "README.md"])
        XCTAssertEqual(t.children[""], ["docs", "src", "a2.js", "a10.js", "b.txt", "README.md"])
        XCTAssertEqual(t.children["src"], ["src/x.swift"])
    }
    func testFoldersATruncatedTreeLeftOutAreStillThere() {
        let t = tree(["deep/er/file.c"])
        XCTAssertEqual(t.children[""], ["deep"])
        XCTAssertEqual(t.children["deep"], ["deep/er"])
        XCTAssertEqual(t.entries["deep/er"]?.folder, true)
        XCTAssertEqual(t.ancestors(of: "deep/er/file.c"), ["deep", "deep/er"])
        XCTAssertEqual(t.files, ["deep/er/file.c"])
    }
    func testTheTreeReadsFromTheServersAnswer() {
        let j: JSON = ["ref": "main", "sha": "abc", "truncated": true,
                       "entries": [["path": "src", "type": "tree"], ["path": "src/a.js", "type": "blob", "size": 12], ["type": "blob"]]]
        let t = RepoTree(j)
        XCTAssertEqual(t?.sha, "abc")
        XCTAssertEqual(t?.truncated, true)
        XCTAssertEqual(t?.entries["src/a.js"], RepoEntry(path: "src/a.js", folder: false, size: 12))
        XCTAssertEqual(t?.entries.count, 2)
        XCTAssertNil(RepoTree(["entries": "no"]))
    }
    func testAFileReadsWithOrWithoutItsText() {
        let f = RepoFile(["path": "a.png", "size": 10, "content": .null, "binary": true, "tooLarge": false])
        XCTAssertEqual(f?.binary, true)
        XCTAssertNil(f?.content)
        XCTAssertEqual(RepoFile(["path": "a.js", "content": "x"])?.content, "x")
        XCTAssertNil(RepoFile(["content": "x"]))
    }

    func testGoToFilePrefersTheFilesOwnName() {
        let paths = ["app/Http/Controllers/UserController.php", "app/Models/User.php", "resources/views/user/controls.blade.php", "tests/Unit/UserTest.php"]
        XCTAssertEqual(repoFindFiles("usercon", in: paths).first, "app/Http/Controllers/UserController.php")
        XCTAssertEqual(repoFindFiles("User.php", in: paths).first, "app/Models/User.php")
        XCTAssertEqual(repoFindFiles("UC", in: paths).first, "app/Http/Controllers/UserController.php")
        XCTAssertEqual(repoFindFiles("models/user", in: paths), ["app/Models/User.php"])
        XCTAssertEqual(repoFindFiles("", in: paths), [])
        XCTAssertEqual(repoFindFiles("zzz", in: paths), [])
    }

    func testSizesReadAsPeopleWriteThem() {
        XCTAssertEqual(repoFormatSize(512), "512 B")
        XCTAssertEqual(repoFormatSize(1536), "1.5 KB")
        XCTAssertEqual(repoFormatSize(200 * 1024), "200 KB")
        XCTAssertEqual(repoFormatSize(3 * 1024 * 1024), "3.0 MB")
    }

    // MARK: Colours

    private func kinds(_ text: String, _ file: String) -> [[String]] {
        codeHighlight(text, language: CodeLanguage.of(file)).map { line in
            line.map { t in
                switch t.kind {
                case .plain: return t.text
                case .keyword: return "K:\(t.text)"
                case .string: return "S:\(t.text)"
                case .comment: return "C:\(t.text)"
                case .number: return "N:\(t.text)"
                case .type: return "T:\(t.text)"
                case .variable: return "V:\(t.text)"
                }
            }
        }
    }

    func testLinesJoinBackIntoTheText() {
        let text = "let a = \"x\" // y\n/* a\nb */ func f() { return 42 }\r\n"
        let lines = codeHighlight(text, language: CodeLanguage.of("a.swift"))
        XCTAssertEqual(lines.map { $0.map(\.text).joined() }, ["let a = \"x\" // y", "/* a", "b */ func f() { return 42 }", ""])
    }
    func testSwiftKeywordsStringsCommentsAndTypes() {
        XCTAssertEqual(kinds("let x: Int = 42 // the answer", "a.swift"), [["K:let", " x: ", "T:Int", " = ", "N:42", " ", "C:// the answer"]])
        XCTAssertEqual(kinds("print(\"a \\\" b\")", "a.swift"), [["print(", "S:\"a \\\" b\"", ")"]])
    }
    func testABlockCommentRunsAcrossLines() {
        XCTAssertEqual(kinds("a /* b\nc\nd */ if", "x.js"), [["a ", "C:/* b"], ["C:c"], ["C:d */", " ", "K:if"]])
    }
    func testAMultiLineStringRunsAcrossLines() {
        XCTAssertEqual(kinds("x = `a\nb` + 1", "x.ts"), [["x = ", "S:`a"], ["S:b`", " + ", "N:1"]])
        XCTAssertEqual(kinds("\"\"\"doc\nmore\"\"\"\ndef f(): pass", "m.py"), [["S:\"\"\"doc"], ["S:more\"\"\""], ["K:def", " f(): ", "K:pass"]])
    }
    func testPHPVariablesAndHashComments() {
        XCTAssertEqual(kinds("$user = new User(); # note", "a.php"), [["V:$user", " = ", "K:new", " ", "T:User", "(); ", "C:# note"]])
    }
    func testAHashInsideAWordIsNotAComment() {
        XCTAssertEqual(kinds("echo a#b", "run.sh"), [["K:echo", " a#b"]])
    }
    func testNumbersInsideNamesStayPlain() {
        XCTAssertEqual(kinds("var a1 = 0x1F", "a.js"), [["K:var", " a1 = ", "N:0x1F"]])
    }
    func testUnknownFilesArePlain() {
        XCTAssertEqual(kinds("if \"x\" // y", "notes.md"), [["if \"x\" // y"]])
        XCTAssertEqual(CodeLanguage.of("Dockerfile").name, "Dockerfile")
        XCTAssertEqual(CodeLanguage.of("resources/views/a.blade.php").name, "Blade")
    }
}
