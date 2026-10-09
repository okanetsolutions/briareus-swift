import XCTest
@testable import BriareusMacCore

final class CodeSymbolsTests: XCTestCase {
    private func outline(_ text: String, _ path: String) -> [String] {
        codeOutline(text, path: path).symbols.map { "\($0.kind.label) \($0.container.map { $0 + "." } ?? "")\($0.name) @\($0.line)" }
    }

    func testPHPClassesMembersImportsAndDocs() {
        let php = """
        <?php
        namespace App\\Models;

        use Illuminate\\Database\\Eloquent\\Model;
        use App\\Support\\Money as Cash;

        /**
         * A rental customer.
         */
        final class User extends Model implements HasName
        {
            use SoftDeletes;
            public const ROLE = 'admin';
            protected ?string $name = null;

            /** The display name. */
            public function displayName(): string
            {
                $f = function ($x) { return $x; };
                return $this->name ?? User::class;
            }
        }

        function helper() {}
        enum Status: string
        {
            case Open = 'open';
        }
        """
        XCTAssertEqual(outline(php, "app/Models/User.php"), [
            "class User @10", "constant User.ROLE @13", "property User.name @14", "method User.displayName @17",
            "function helper @24", "enum Status @25", "constant Status.Open @27",
        ])
        let o = codeOutline(php, path: "app/Models/User.php")
        XCTAssertEqual(o.namespace, "App\\Models")
        XCTAssertEqual(o.imports, ["Model": "Illuminate\\Database\\Eloquent\\Model", "Cash": "App\\Support\\Money"])
        let user = o.symbols[0]
        XCTAssertEqual(user.doc, "A rental customer.")
        XCTAssertEqual(user.signature, "final class User extends Model implements HasName")
        XCTAssertEqual(user.qualified, "App\\Models\\User")
        XCTAssertEqual(o.symbols[3].doc, "The display name.")
        XCTAssertEqual(o.symbols[3].qualified, "App\\Models\\User.displayName")
    }

    func testTypeScriptClassesFunctionsAndTypes() {
        let ts = """
        export interface Props { id: number }
        export type Id = string | number;
        export const LIMIT = 10;
        export const load = async (id: Id) => { return id };
        export default class Store {
          private items: Map<string, number> = new Map();
          async fetch(id: string): Promise<void> {
            if (id) { console.log("class Fake {") }
          }
        }
        function render() {}
        """
        XCTAssertEqual(outline(ts, "src/store.ts"), [
            "interface Props @1", "type Id @2", "constant LIMIT @3", "function load @4", "class Store @5",
            "property Store.items @6", "method Store.fetch @7", "function render @11",
        ])
    }

    func testSwiftTypesExtensionsAndMembers() {
        let swift = """
        /// A tree.
        struct RepoTree {
            var ref: String
            init(ref: String) { self.ref = ref }
            func files() -> [String] { let local = 1; return [] }
        }
        extension RepoTree {
            static let empty = RepoTree(ref: "")
        }
        enum Kind {
            case a, b
        }
        func helper() {}
        """
        XCTAssertEqual(outline(swift, "a.swift"), [
            "struct RepoTree @2", "property RepoTree.ref @3", "method RepoTree.init @4", "method RepoTree.files @5",
            "property RepoTree.empty @8", "enum Kind @10", "constant Kind.a @11", "function helper @13",
        ])
    }

    func testPythonGoAndRuby() {
        XCTAssertEqual(outline("MAX = 3\nclass A:\n    def run(self):\n        pass\n\ndef main():\n    pass\n", "x.py"),
                       ["constant MAX @1", "class A @2", "method A.run @3", "function main @6"])
        XCTAssertEqual(outline("type Server struct {\n}\nfunc (s *Server) Start() error {\n}\nfunc main() {\n}\n", "m.go"),
                       ["struct Server @1", "method Server.Start @3", "function main @5"])
        XCTAssertEqual(outline("module Billing\n  class Invoice\n    def total\n    end\n  end\nend\n", "b.rb"),
                       ["module Billing @1", "class Billing.Invoice @2", "method Invoice.total @3"])
    }

    func testOnlySourceFilesAreRead() {
        XCTAssertTrue(codeOutlineSupported("a.php"))
        XCTAssertFalse(codeOutlineSupported("README.md"))
        XCTAssertEqual(codeOutline("class A {}", path: "notes.txt").symbols, [])
    }

    // MARK: The index

    private let files: [String: String] = [
        "app/Models/User.php": "<?php\nnamespace App\\Models;\n\nclass User\n{\n    public function save() {}\n}\n",
        "app/Legacy/User.php": "<?php\nnamespace App\\Legacy;\n\nclass User\n{\n}\n",
        "app/Http/UserController.php": "<?php\nnamespace App\\Http;\n\nuse App\\Models\\User;\n\nclass UserController\n{\n    public function show() { return User::find(1)->save(); }\n}\n",
        "vendor/laravel/Model.php": "<?php\nclass Model {}\n",
    ]

    func testVendorAndNodeModulesAreLeftOut() {
        XCTAssertFalse(repoIndexIncludes("vendor/laravel/Model.php"))
        XCTAssertFalse(repoIndexIncludes("packages/web/node_modules/react/index.js"))
        XCTAssertFalse(repoIndexIncludes(".git/config"))
        XCTAssertTrue(repoIndexIncludes("app/vendors/List.php"))
        XCTAssertNil(repoText(Data([0x89, 0, 1])))
        XCTAssertEqual(repoText(Data("hé".utf8)), "hé")
    }

    func testGoToClassAndSymbol() {
        let index = RepoIndex(texts: files.filter { repoIndexIncludes($0.key) })
        XCTAssertEqual(index.search("usco", typesOnly: true).map(\.name), ["UserController"])
        XCTAssertEqual(Set(index.search("User", typesOnly: true).prefix(2).map(\.path)), ["app/Models/User.php", "app/Legacy/User.php"])
        XCTAssertEqual(index.search("save", typesOnly: true), [])
        XCTAssertEqual(index.search("save", typesOnly: false).map(\.qualified), ["App\\Models\\User.save"])
        XCTAssertEqual(index.search("User::save", typesOnly: false).first?.name, "save")
        XCTAssertEqual(index.search("Model", typesOnly: true), [])
        XCTAssertEqual(index.structure(of: "app/Models/User.php").map(\.name), ["User", "save"])
    }

    func testGoToDeclarationFollowsTheImport() {
        let index = RepoIndex(texts: files.filter { repoIndexIncludes($0.key) })
        let found = index.declarations(of: "User", from: "app/Http/UserController.php")
        XCTAssertEqual(found.map(\.path), ["app/Models/User.php"])
        // Without an import, every User is offered, the same folder first.
        XCTAssertEqual(index.declarations(of: "User", from: "app/Legacy/Other.php").map(\.path), ["app/Legacy/User.php", "app/Models/User.php"])
        XCTAssertEqual(index.declarations(of: "save", from: "app/Http/UserController.php", member: true).map(\.line), [6])
        XCTAssertEqual(index.declarations(of: "nothing", from: "x.php"), [])
    }

    func testFindUsagesAndFindInFiles() {
        let index = RepoIndex(texts: files.filter { repoIndexIncludes($0.key) })
        XCTAssertEqual(index.usages(of: "save").map { "\($0.path):\($0.line)" }, ["app/Http/UserController.php:8"])
        let any = index.find(TextQuery(text: "user"))
        XCTAssertEqual(Set(any.map(\.path)), ["app/Http/UserController.php", "app/Legacy/User.php", "app/Models/User.php"])
        XCTAssertEqual(index.find(TextQuery(text: "user", matchCase: true)), [])
        let words = repoFind(TextQuery(text: "User", matchCase: true, wholeWord: true), in: "UserController User $User", path: "a")
        XCTAssertEqual(words.first?.ranges, [NSRange(location: 15, length: 4)])
        XCTAssertEqual(repoFind(TextQuery(text: "fun.*\\(", regex: true), in: "a\npublic function x()", path: "a").map(\.line), [2])
        XCTAssertEqual(repoFind(TextQuery(text: "(", regex: true), in: "(", path: "a"), [])
    }

    func testTheWordUnderTheCaret() {
        let line = "return $this->user->save(User::find(1));"
        XCTAssertEqual(codeWord(in: line, at: 22)?.word, "save")
        XCTAssertEqual(codeWord(in: line, at: 22)?.member, true)
        XCTAssertEqual(codeWord(in: line, at: 27)?.word, "User")
        XCTAssertEqual(codeWord(in: line, at: 27)?.member, false)
        XCTAssertEqual(codeWord(in: line, at: 33)?.member, true)
        // Just past a word still takes it, as a caret at its end does.
        XCTAssertEqual(codeWord(in: "abc ", at: 3)?.word, "abc")
        XCTAssertNil(codeWord(in: "  ", at: 1))
        XCTAssertNil(codeWord(in: "x = 42", at: 4))
    }
}
