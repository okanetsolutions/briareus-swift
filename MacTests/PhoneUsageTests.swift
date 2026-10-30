// The iPhone's Usage tab, its pure parts (Mac/Core/PhoneUsage.swift).
import XCTest
@testable import BriareusMacCore

final class PhoneUsageTests: XCTestCase {
    func testBucketDates() {
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(PhoneUsage.bucketDate("2026-08-03", calendar: utc), Date(timeIntervalSince1970: 1785715200))
        XCTAssertEqual(PhoneUsage.bucketDate("2026-08", calendar: utc), Date(timeIntervalSince1970: 1785542400))
        XCTAssertNil(PhoneUsage.bucketDate("2026-13", calendar: utc))
        XCTAssertNil(PhoneUsage.bucketDate("nope", calendar: utc))
        XCTAssertNil(PhoneUsage.bucketDate(nil, calendar: utc))
    }

    func testAddKeepsAnUnpricedTotalNull() {
        let sum = PhoneUsage.add([["turns": 2, "costUsd": nil], ["turns": 1, "costUsd": 0.5], ["turns": 1, "costUsd": 0.25]])
        XCTAssertEqual(sum["turns"], 4)
        XCTAssertEqual(sum["costUsd"], 0.75)
        XCTAssertEqual(PhoneUsage.add([["turns": 1, "costUsd": nil]])["costUsd"], .null)
    }

    func testCombineFoldsEachProjectsMonth() {
        let a: JSON = [
            "turns": 3, "sessions": 2, "inputTokens": 100, "outputTokens": 50, "totalTokens": 150, "durationMs": 1000,
            "costUsd": 1.5, "unpricedTurns": 0, "today": "2026-08-03",
            "daily": [["date": "2026-08-01", "turns": 1, "totalTokens": 50, "costUsd": 0.5], ["date": "2026-08-02", "turns": 2, "totalTokens": 100, "costUsd": 1]],
            "providers": [["provider": "claude", "totalTokens": 150, "costUsd": 1.5]],
            "models": [["key": "claude|opus", "provider": "claude", "model": "opus", "totalTokens": 150]],
            "activities": [["activity": "chat", "totalTokens": 150, "costUsd": 1.5]],
        ]
        let b: JSON = [
            "turns": 1, "sessions": 1, "inputTokens": 400, "outputTokens": 100, "totalTokens": 500, "durationMs": 500,
            "costUsd": nil, "unpricedTurns": 1, "today": "2026-08-03",
            "daily": [["date": "2026-08-01", "turns": 1, "totalTokens": 500, "costUsd": nil, "unpricedTurns": 1], ["date": "2026-08-02", "turns": 0, "totalTokens": 0]],
            "providers": [["provider": "codex", "totalTokens": 500], ["provider": "claude", "totalTokens": 0]],
            "models": [["key": "codex|gpt", "provider": "codex", "model": "gpt", "totalTokens": 500]],
            "activities": [["activity": "issue", "totalTokens": 500, "costUsd": nil]],
        ]
        let u = PhoneUsage.combine([(Project(repo: "o/a", label: "App"), a), (Project(repo: "o/b"), b)])
        XCTAssertEqual(u["turns"], 4)
        XCTAssertEqual(u["totalTokens"], 650)
        XCTAssertEqual(u["costUsd"], 1.5)
        XCTAssertEqual(u["unpricedTurns"], 1)
        XCTAssertEqual(u["period"], "month")
        XCTAssertEqual(u["month"], "2026-08")
        XCTAssertEqual(u["today"], "2026-08-03")
        XCTAssertEqual(u["buckets"].items.map { $0["date"] }, ["2026-08-01", "2026-08-02"])
        XCTAssertEqual(u["buckets"][0]["totalTokens"], 550)
        XCTAssertEqual(u["buckets"][0]["costUsd"], 0.5)
        XCTAssertEqual(u["buckets"][0]["unpricedTurns"], 1)
        XCTAssertEqual(u["projects"].items.map { $0["key"] }, ["o/b", "o/a"])
        XCTAssertEqual(u["projects"][1]["label"], "App")
        XCTAssertEqual(u["projects"][0]["label"], "o/b")
        XCTAssertEqual(u["providers"].items.map { $0["provider"] }, ["codex", "claude"])
        XCTAssertEqual(u["providers"][1]["totalTokens"], 150)
        XCTAssertEqual(u["models"].items.map { $0["key"] }, ["codex|gpt", "claude|opus"])
        XCTAssertEqual(u["activities"].items.map { $0["activity"] }, ["chat", "issue"])
        XCTAssertEqual(Usage.windowName(u, periodLabel: "This month", locale: Locale(identifier: "en_US")), "August 2026")
    }
}
