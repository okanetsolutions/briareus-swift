// The SSH server form's body, its database login and write-only passwords, and unsaved-change tracking.
import XCTest
@testable import BriareusMacCore

final class SSHServerLogicTests: XCTestCase {
    func testSSHServerDefaultsAndChecks() {
        var s = SSHServerFormState(row: [:], firstRepo: "o/r")
        XCTAssertEqual(s.repo, "o/r")
        XCTAssertEqual(s.text(.port), "22")
        XCTAssertEqual(s.mode, "ask")
        XCTAssertEqual(s.body().failureMessage, "Enter the host: a hostname or an IP address.")
        s.texts[.host] = "h"
        s.texts[.username] = "u"
        XCTAssertEqual(try s.body().get()["port"], 22)
        XCTAssertTrue(s.changed)
        XCTAssertEqual(SSHServerFormState.subtitle(["username": "u", "host": "h", "port": 22, "repo": "o/r"]), "u@h:22 · o/r")
        XCTAssertEqual(SSHServerFormState.rowID(["id": 1712345678901]), 1712345678901)
    }

    func testSSHServerDatabaseLogin() throws {
        // A server that predates the login has no Database tab and is sent none of its keys.
        let old = SSHServerFormState(row: ["id": 1, "repo": "o/r", "host": "h", "port": 22, "username": "u"])
        XCTAssertFalse(old.offersDatabase)
        XCTAssertNil(try old.body().get().object?["dbHost"])

        // A new one starts where the server's default puts the database, and sends a login only once one is typed.
        var s = SSHServerFormState(row: [:], firstRepo: "o/r", database: true)
        XCTAssertTrue(s.offersDatabase)
        XCTAssertEqual(s.text(.dbHost), "127.0.0.1")
        XCTAssertEqual(s.text(.dbPort), "3306")
        s.texts[.host] = "h"; s.texts[.username] = "u"
        XCTAssertNil(try s.body().get().object?["dbUsername"])
        s.texts[.dbPassword] = "p"
        XCTAssertEqual(s.body().failure, FormProblem(message: "Enter the database username this password is for.", tab: SSHServerTab.database.rawValue))
        s.texts[.dbUsername] = " app "
        s.texts[.dbPort] = "0"
        XCTAssertEqual(s.body().failure?.tab, SSHServerTab.database.rawValue)
        s.texts[.dbPort] = "3307"
        var body = try s.body().get()
        XCTAssertEqual(body["dbUsername"], "app")
        XCTAssertEqual(body["dbPassword"], "p")
        XCTAssertEqual(body["dbPort"], 3307)
        XCTAssertTrue(s.tabChanged(.database))

        // Saved: the row only says there is a login; the form knows it from what it sent.
        let row: JSON = ["id": 5, "repo": "o/r", "host": "h", "port": 22, "username": "u", "dbHost": "127.0.0.1", "dbPort": 3307, "hasDbCredentials": true]
        s.saved(row, sent: body)
        XCTAssertTrue(s.loginKnown)
        XCTAssertEqual(s.text(.dbUsername), "app")
        XCTAssertFalse(s.changed)

        // Emptying the username removes the whole login.
        s.texts[.dbUsername] = ""
        body = try s.body().get()
        XCTAssertEqual(body["dbUsername"], "")
        XCTAssertEqual(body["dbPassword"], "")
        XCTAssertNil(body.object?["hasDbCredentials"])

        // A stored login not read yet: only the half typed is sent, and the other stays on the server.
        var stored = SSHServerFormState(row: row)
        XCTAssertFalse(stored.loginKnown)
        stored.texts[.dbPassword] = "new"
        body = try stored.body().get()
        XCTAssertNil(body.object?["dbUsername"])
        XCTAssertEqual(body["dbPassword"], "new")
        // Read, it fills the box not typed in and leaves the typed one.
        stored.loginRead(["username": "app", "password": "p"])
        XCTAssertEqual(stored.text(.dbUsername), "app")
        XCTAssertEqual(stored.text(.dbPassword), "new")
        XCTAssertTrue(stored.tabChanged(.database))
        XCTAssertFalse(stored.tabChanged(.server))

        // A clone carries the login it was copied with.
        let copy = try stored.copy().get()
        XCTAssertEqual(copy["label"], "")
        XCTAssertEqual(copy["dbUsername"], "app")
        XCTAssertEqual(copy["dbPassword"], "new")
        let clone = SSHServerFormState(row: copy)
        XCTAssertEqual(try clone.body().get()["dbUsername"], "app")
    }

    func testSSHServerPasswords() throws {
        // A server that predates passwords shows no boxes and is sent none of their keys.
        let old = SSHServerFormState(row: ["id": 1, "repo": "o/r", "host": "h", "port": 22, "username": "u"])
        XCTAssertFalse(old.offersPasswords)
        XCTAssertEqual(old.fields(on: .server), [.label, .host, .port, .username, .key])
        XCTAssertNil(try old.body().get().object?["password"])

        // A new one on a current server: neither stored, nothing sent until typed, sent as typed.
        var s = SSHServerFormState(row: [:], firstRepo: "o/r", passwords: [.password, .sudoPassword])
        XCTAssertTrue(s.offersPasswords)
        XCTAssertTrue(s.fields(on: .server).contains(.sudoPassword))
        s.texts[.host] = "h"; s.texts[.username] = "u"
        var body = try s.body().get()
        XCTAssertNil(body.object?["password"]); XCTAssertNil(body.object?["sudoPassword"]); XCTAssertNil(body.object?["hasPassword"])
        s.texts[.sudoPassword] = " s p "
        body = try s.body().get()
        XCTAssertEqual(body["sudoPassword"], " s p ")
        XCTAssertNil(body.object?["password"])
        XCTAssertTrue(s.tabChanged(.server))

        // Refused before the server would: a line break, or more than 1023 bytes.
        for bad in ["a\nb", "a\rb", "a\0b"] {
            s.texts[.password] = bad
            XCTAssertNotNil(s.body().failure)
        }
        s.texts[.password] = String(repeating: "é", count: 512)
        XCTAssertNotNil(s.body().failure)
        s.texts[.password] = String(repeating: "é", count: 511)
        XCTAssertEqual(try s.body().get()["password"].string?.count, 511)

        // Saved: the row only says what is stored, and the boxes start empty again.
        let row: JSON = ["id": 5, "repo": "o/r", "host": "h", "port": 22, "username": "u", "hasPassword": true, "hasSudoPassword": false]
        s.saved(row, sent: body)
        XCTAssertEqual(s.text(.password), "")
        XCTAssertTrue(s.stored(.password)); XCTAssertFalse(s.stored(.sudoPassword))
        XCTAssertFalse(s.changed)
        XCTAssertNotEqual(s.cue(.password), SSHServerField.password.def.cue)
        XCTAssertNil(try s.body().get().object?["password"])

        // Removing a stored one sends it empty; unticked, it stays; typing one replaces it instead.
        s.setText(.password, "typed")
        s.toggleClear(.password)
        XCTAssertEqual(s.text(.password), "")
        XCTAssertTrue(s.changed)
        XCTAssertNotEqual(s.cue(.password), s.cue(.sudoPassword))
        XCTAssertEqual(try s.body().get()["password"], "")
        s.toggleClear(.password)
        XCTAssertNil(try s.body().get().object?["password"])
        XCTAssertFalse(s.changed)
        s.toggleClear(.password)
        s.setText(.password, "new")
        XCTAssertTrue(s.clear.isEmpty)
        XCTAssertEqual(try s.body().get()["password"], "new")
        s.setText(.password, "")

        // A clone carries the passwords typed, never the flags, and takes passwords too.
        s.texts[.sudoPassword] = "root"
        let copy = try s.copy().get()
        XCTAssertEqual(copy["sudoPassword"], "root")
        XCTAssertNil(copy.object?["password"]); XCTAssertNil(copy.object?["hasPassword"])
        let clone = SSHServerFormState(row: copy, passwords: [.password, .sudoPassword])
        XCTAssertEqual(clone.text(.sudoPassword), "root")
        XCTAssertEqual(try clone.body().get()["sudoPassword"], "root")
        XCTAssertFalse(clone.stored(.password))
    }

    func testSSHServerTakesEachPasswordOnItsOwn() throws {
        // A server that takes SSH passwords but not sudo ones shows only the SSH box and is never sent a sudo password.
        var s = SSHServerFormState(row: ["id": 1, "repo": "o/r", "host": "h", "port": 22, "username": "u", "hasPassword": false])
        XCTAssertTrue(s.offers(.password)); XCTAssertFalse(s.offers(.sudoPassword))
        XCTAssertEqual(s.fields(on: .server), [.label, .host, .port, .username, .key, .password])
        s.texts[.password] = "p"; s.texts[.sudoPassword] = "root"
        let body = try s.body().get()
        XCTAssertEqual(body["password"], "p")
        XCTAssertNil(body.object?["sudoPassword"])
        let copy = try s.copy().get()
        XCTAssertEqual(copy["password"], "p")
        XCTAssertNil(copy.object?["sudoPassword"])

        // A new one on such a server starts with only the SSH password's flag.
        let new = SSHServerFormState(row: [:], firstRepo: "o/r", passwords: [.password])
        XCTAssertTrue(new.offers(.password)); XCTAssertFalse(new.offers(.sudoPassword))
    }

    func testSSHServerListSaysWhichPasswordsAreTaken() {
        XCTAssertEqual(SSHServerFormState.takesPasswords([]), [.password, .sudoPassword])
        XCTAssertEqual(SSHServerFormState.takesPasswords([["id": 1, "host": "h"]]), [])
        XCTAssertEqual(SSHServerFormState.takesPasswords([["id": 1, "host": "h", "hasPassword": false]]), [.password])
        XCTAssertEqual(SSHServerFormState.takesPasswords([["id": 1, "host": "h", "hasPassword": true, "hasSudoPassword": false]]),
                       [.password, .sudoPassword])
    }

    func testSSHServerFoldersFollowTheSidebarsProjects() {
        let servers: [JSON] = [
            ["id": 1, "repo": "o/b", "label": "web", "host": "10.0.0.1", "username": "forge"],
            ["id": 2, "repo": "o/a", "host": "db.example.com", "username": "deploy"],
            ["id": 3, "repo": "", "host": "spare"],
            ["id": 4, "repo": "o/b", "host": "10.0.0.2", "username": "forge"],
            ["id": 5, "repo": "z/gone", "host": "old"],
            ["id": 6, "repo": "m/gone", "host": "older"],
        ]
        let projects = [Project(repo: "o/a", label: "Alpha"), Project(repo: "o/b"), Project(repo: "o/none")]
        let folders = sshServerFolders(servers, projects: projects)
        XCTAssertEqual(folders.map(\.repo), ["o/a", "o/b", "m/gone", "z/gone", ""])
        XCTAssertEqual(folders.map(\.title), ["Alpha", "o/b", "m/gone", "z/gone", nil])
        XCTAssertEqual(folders[1].servers.map { $0["id"].int }, [1, 4])
    }

    func testSSHServerFoldersSearch() {
        let servers: [JSON] = [
            ["id": 1, "repo": "o/b", "label": "Web", "host": "10.0.0.1", "username": "forge"],
            ["id": 2, "repo": "o/b", "host": "10.0.0.2", "username": "deploy"],
            ["id": 3, "repo": "o/a", "host": "db.example.com", "username": "deploy"],
            ["id": 4, "repo": "", "host": "spare"],
        ]
        let projects = [Project(repo: "o/a", label: "Alpha"), Project(repo: "o/b")]
        func ids(_ q: String) -> [[Int?]] { sshServerFolders(servers, projects: projects, query: q).map { $0.servers.map { $0["id"].int } } }
        XCTAssertEqual(ids("  "), [[3], [1, 2], [4]])
        XCTAssertEqual(ids("web"), [[1]])
        XCTAssertEqual(ids("DEPLOY"), [[3], [2]])
        // A project's title or repository keeps all of its servers.
        XCTAssertEqual(ids("alpha"), [[3]])
        XCTAssertEqual(ids("o/b"), [[1, 2]])
        XCTAssertEqual(ids("spare"), [[4]])
        XCTAssertEqual(ids("nothing"), [])
    }
}

private extension Result where Failure == FormProblem {
    var failureMessage: String? { if case .failure(let p) = self { return p.message }; return nil }
    var failure: FormProblem? { if case .failure(let p) = self { return p }; return nil }
}
