// After the Windows client's tests/core_mcp_tests.c: a save keeps the write-only headers, environment and client secret
// unless they are typed or cleared, sends only the active transport's fields, and refuses bad names, endpoints and maps.
import XCTest
@testable import BriareusMacCore

final class McpServerTests: XCTestCase {
    private let row = #"{"id":1791403200000,"name":"tools_1-2","label":"Tools","transport":"http","url":"https://mcp.example/tools","command":"","args":[],"repos":[],"enabled":true,"oauthRedirect":"callback","status":"ready","signedIn":true,"signInUrl":"https://auth.example/?state=private","headerNames":["Authorization"],"envNames":["TOKEN"],"hasOAuthClientSecret":true}"#
    private func form() -> McpServerFormState { McpServerFormState(row: j(row)) }
    private func body(_ s: McpServerFormState) -> JSON? { if case .success(let b) = s.body() { return b }; return nil }
    private func refused(_ s: McpServerFormState, _ why: String = "", file: StaticString = #filePath, line: UInt = #line) {
        if case .failure(let p) = s.body() { XCTAssertFalse(p.message.contains("private"), file: file, line: line) }
        else { XCTFail("accepted \(why)", file: file, line: line) }
    }

    func testSecretsAreKeptUnlessTypedOrCleared() {
        var s = form()
        XCTAssertEqual(s.id, 1791403200000); XCTAssertFalse(s.changed)
        XCTAssertEqual(s.cue(.headers), "Stored: Authorization · type to replace")
        var b = body(s)!
        XCTAssertEqual(b["name"].string, "tools_1-2"); XCTAssertEqual(b["label"].string, "Tools"); XCTAssertEqual(b["transport"].string, "http")
        XCTAssertEqual(b["command"].string, ""); XCTAssertEqual(b["args"].count, 0); XCTAssertEqual(b["url"].string, "https://mcp.example/tools")
        for k in ["headers", "env", "oauthClientSecret", "headerNames", "envNames", "status", "id", "signedIn", "signInUrl"] { XCTAssertTrue(b[k].isNull, k) }
        s.texts[.headers] = "Authorization: Bearer private\n\nX-Team : core"
        s.texts[.oauthClientSecret] = " private "
        b = body(s)!
        XCTAssertEqual(b["headers"]["Authorization"].string, "Bearer private"); XCTAssertEqual(b["headers"]["X-Team"].string, "core")
        XCTAssertEqual(b["oauthClientSecret"].string, "private")
        // A remote server sends no environment, typed or not.
        s.texts[.env] = "TOKEN=private"
        XCTAssertTrue(body(s)!["env"].isNull)
        s.texts[.headers] = ""; s.texts[.oauthClientSecret] = ""
        s.clear = [.headers, .oauthClientSecret]
        b = body(s)!
        XCTAssertEqual(b["headers"], .object([:])); XCTAssertEqual(b["oauthClientSecret"].string, "")
        XCTAssertTrue(s.changed)
    }

    func testACommandSendsItsArgumentsAndTheProjectsTicked() {
        var s = form()
        s.stdio = true
        s.texts[.command] = " /opt/mcp "
        s.texts[.args] = "--token\n value with spaces \n\n"
        s.texts[.env] = "TOKEN=private\n_X=1"
        s.repos = ["owner/project", "other/repo"]
        s.enabled = false
        let b = body(s)!
        XCTAssertEqual(b["url"].string, ""); XCTAssertEqual(b["command"].string, "/opt/mcp")
        XCTAssertEqual(b["args"].strings, ["--token", "value with spaces"])
        XCTAssertEqual(b["env"]["TOKEN"].string, "private"); XCTAssertTrue(b["headers"].isNull)
        XCTAssertEqual(b["repos"].strings, ["owner/project", "other/repo"]); XCTAssertTrue(b["enabled"].is(false))
        s.texts[.command] = " "
        refused(s, "empty command")
    }

    func testBadNamesEndpointsAndMapsAreRefused() {
        var s = form()
        for name in ["", "a b", "reviewer_memory", "reviewer_ssh", "reviewer_slack", "reviewer_workers", "browser", "pri\nvate", String(repeating: "a", count: 65)] {
            s.texts[.name] = name; refused(s, name)
        }
        s.texts[.name] = "ok"
        for url in ["http://remote.example/mcp", "ftp://x", "https://user@host/", "https://", "https://host:0/", "https://host:70000/", "https://ho st/"] {
            s.texts[.url] = url; refused(s, url)
        }
        for url in ["https://mcp.example", "http://localhost:8080/mcp", "http://127.0.0.1/mcp", "http://[::1]:9/x", "https://[2001:db8::1]:443/"] {
            s.texts[.url] = url; XCTAssertNotNil(body(s), url)
        }
        s.texts[.url] = "https://mcp.example"
        for headers in ["no separator", "bad name: x", ": x"] { s.texts[.headers] = headers; refused(s, headers) }
        s.texts[.headers] = "!#$%&'*+.^_`|~-: private"
        XCTAssertNotNil(body(s))
        s.texts[.headers] = (0..<33).map { "K\($0): v" }.joined(separator: "\n")
        refused(s, "33 headers")
        s.texts[.headers] = ""
        s.stdio = true; s.texts[.command] = "mcp"
        for env in ["1TOKEN=x", "a-b=x", "=x", "NOEQUALS"] { s.texts[.env] = env; refused(s, env) }
        s.texts[.env] = ""
        s.texts[.args] = (0..<65).map { "a\($0)" }.joined(separator: "\n")
        refused(s, "65 arguments")
    }

    func testLoopbackCallbacksNeedAStateAndACodeOrError() {
        XCTAssertTrue(mcpCallbackURL("http://127.0.0.1:53682/callback?code=abc&state=xyz"))
        XCTAssertTrue(mcpCallbackURL("http://127.0.0.1:53682/callback?state=xyz&error=access_denied"))
        for bad in ["http://127.0.0.1:53682/callback?code=abc", "http://127.0.0.1:53682/callback?state=&code=abc", "http://evil.example/callback?code=a&state=b",
                    "http://127.0.0.1/callback#code=a&state=b", "not a url"] {
            XCTAssertFalse(mcpCallbackURL(bad), bad)
        }
        XCTAssertEqual(McpServerFormState.sidebarLine(j(row)), "remote · ready · every project")
        XCTAssertEqual(McpServerFormState.sidebarLine(j(#"{"transport":"stdio","status":"needs-sign-in","repos":["a/b"]}"#)), "command · needs sign-in · 1 project")
    }
}
