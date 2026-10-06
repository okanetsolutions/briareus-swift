// The Forge tab's reading of Laravel Forge's fields (Forge.swift), which the Windows client's project_forge.c and
// forge_site.c do in place: fields as text, names as words, the deployment token hidden, the project's own site found.
import XCTest
@testable import BriareusMacCore

final class ForgeTests: XCTestCase {
    func testForgeFieldsReadAsText() {
        XCTAssertEqual(Forge.fieldText("installed"), "installed")
        XCTAssertEqual(Forge.fieldText(JSON(42)), "42")
        XCTAssertEqual(Forge.fieldText(.number(8.3)), "8.3")
        XCTAssertEqual(Forge.fieldText(.bool(true)), "Yes")
        XCTAssertEqual(Forge.fieldText(["a", "", JSON(2)]), "a, 2")
        XCTAssertNil(Forge.fieldText(""))
        XCTAssertNil(Forge.fieldText(.null))
        XCTAssertNil(Forge.fieldText([:]))
    }

    func testForgeNamesReadAsWords() {
        XCTAssertEqual(Forge.fieldLabel("deployment_status"), "Deployment status")
        XCTAssertEqual(Forge.fieldLabel("php_version"), "PHP version")
        XCTAssertEqual(Forge.fieldLabel("deployment_url"), "Deployment URL")
        XCTAssertEqual(Forge.fieldLabel("name"), "Name")
    }

    func testTheDeploymentTokenIsHidden() {
        XCTAssertEqual(Forge.maskedURL("https://forge.laravel.com/servers/1/sites/2/deploy/http?token=abc123&x=1"),
                       "https://forge.laravel.com/servers/1/sites/2/deploy/http?token=••••••&x=1")
        XCTAssertEqual(Forge.maskedURL("https://x/deploy?token=abc"), "https://x/deploy?token=••••••")
        XCTAssertEqual(Forge.maskedURL("https://example.com"), "https://example.com")
    }

    func testTheProjectsSiteIsFoundByItsRepository() {
        let repo = "okanet/shop"
        XCTAssertTrue(Forge.siteIsProject(["repository": ["url": "git@github.com:okanet/shop.git"]], repo: repo))
        XCTAssertTrue(Forge.siteIsProject(["repository": ["name": "Okanet/Shop"]], repo: repo))
        XCTAssertTrue(Forge.siteIsProject(["repository": "https://github.com/okanet/shop"], repo: repo))
        XCTAssertFalse(Forge.siteIsProject(["repository": ["url": "git@github.com:okanet/myshop.git"]], repo: repo))
        XCTAssertFalse(Forge.siteIsProject(["repository": .null], repo: repo))
    }

    func testASiteOpensOverHTTPS() {
        XCTAssertEqual(Forge.siteURL(["url": "shop.example.com"]), "https://shop.example.com")
        XCTAssertEqual(Forge.siteURL(["url": "https://shop.example.com"]), "https://shop.example.com")
        XCTAssertNil(Forge.siteURL(["url": "http://shop.example.com"]))
        XCTAssertNil(Forge.siteURL([:]))
        XCTAssertEqual(Forge.serverDetail(["ip_address": "1.2.3.4", "region": "fra1"]), "1.2.3.4 · fra1")
        XCTAssertEqual(Forge.tone("installed"), .ok)
        XCTAssertEqual(Forge.tone("failed"), .danger)
        XCTAssertEqual(Forge.tone("deploying"), .accent)
        XCTAssertEqual(Forge.tone(nil), .muted)
    }
}
