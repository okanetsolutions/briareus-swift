// Incoming feedback is evidence for a manual decision, never a verdict on the user's behalf.
import Foundation

struct FeedbackAssessmentDetails: Equatable, Sendable {
    let source: String?
    let author: String?
    let recommendation: String
    let verified: Bool
    let worthFixing: Bool
    let evidence: String
    let reason: String

    init?(_ finding: JSON) {
        let assessment = finding["assessment"]
        guard assessment.isObject else { return nil }
        source = finding["sourceBody"].nonEmpty
        author = finding["reviewAuthorLogin"].nonEmpty
        recommendation = findingDecisionIndex(finding["recommendation"].string).map { findingDecisionTitles[$0] } ?? "Optional"
        verified = assessment["verified"].is(true)
        worthFixing = assessment["worthFixing"].is(true)
        evidence = assessment["evidence"].string ?? ""
        reason = assessment["reason"].string ?? ""
    }
    var summary: String {
        "Recommended: \(recommendation) · \(verified ? "Verified" : "Unverified") · \(worthFixing ? "Worth fixing" : "Not worth fixing")"
    }
    var sourceTitle: String { author.map { "Source feedback · @\($0)" } ?? "Source feedback" }
}
