// What the Forge tab reads off Laravel Forge's servers and sites (the Windows client's app/project_forge.c and
// app/forge_site.c, their pure half): Forge's fields as text and its snake_case names as words, the site that deploys
// the project, its address, and its deployment trigger URL with the token hidden.
import Foundation

enum Forge {
    /// A field read as text whatever its type: a string, a number, a boolean (Yes or No), or a list of them.
    static func fieldText(_ j: JSON) -> String? {
        if let s = j.nonEmpty { return s }
        if let n = j.number, n.isFinite { return n == n.rounded(.down) ? String(format: "%.0f", n) : String(format: "%g", n) }
        if let b = j.bool { return b ? "Yes" : "No" }
        let parts = j.items.compactMap(fieldText)
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Forge's snake_case name as words: "deployment_status" → "Deployment status", "php_version" → "PHP version".
    static func fieldLabel(_ key: String) -> String {
        let upper: Set<String> = ["url", "php", "ip", "ssl", "id", "ssh", "dns", "http", "https", "tls"]
        var words: [String] = []
        for part in key.split(separator: "_", omittingEmptySubsequences: false) {
            let word = String(part)
            if upper.contains(word.lowercased()) { words.append(word.uppercased()) }
            else if words.isEmpty, let first = word.first, first >= "a", first <= "z" { words.append(first.uppercased() + word.dropFirst()) }
            else { words.append(word) }
        }
        return words.joined(separator: " ")
    }

    /// A URL with the value of its `token` parameter hidden: Forge's deployment trigger URL deploys the site to whoever
    /// has it.
    static func maskedURL(_ text: String) -> String {
        guard let t = text.range(of: "token=") else { return text }
        let tail = text[t.upperBound...]
        let end = tail.firstIndex { $0 == "&" || $0 == "#" } ?? text.endIndex
        return String(text[..<t.upperBound]) + "••••••" + String(text[end...])
    }

    /// Whether a site deploys project `repo` (`owner/name`): its repository names it, as the end of a URL or of
    /// git@host:owner/name(.git).
    static func siteIsProject(_ site: JSON, repo: String) -> Bool {
        let r = site["repository"]
        let rn = repo.utf8.count
        guard rn > 0 else { return false }
        for name in [r["url"].string, r["name"].string, r["repository"].string, r.string] {
            guard var s = name, !s.isEmpty else { continue }
            if s.utf8.count > 4 && s.lowercased().hasSuffix(".git") { s = String(s.dropLast(4)) }
            let bytes = Array(s.utf8), n = bytes.count
            guard n >= rn, String(decoding: bytes[(n - rn)...], as: UTF8.self).lowercased() == repo.lowercased() else { continue }
            if n == rn || bytes[n - rn - 1] == UInt8(ascii: "/") || bytes[n - rn - 1] == UInt8(ascii: ":") { return true }
        }
        return false
    }

    /// Where a site answers: its `url`, a bare domain over HTTPS. Nil unless it is an https address.
    static func siteURL(_ site: JSON) -> String? {
        guard let url = site["url"].string else { return nil }
        let out = !safeWebURL(url) && !url.contains("://") ? "https://\(url)" : url
        return safeWebURL(out) ? out : nil
    }

    /// "a · b · c" from the parts that are set.
    static func joined(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
    }
    /// A server's address, cloud and region.
    static func serverDetail(_ server: JSON) -> String {
        joined([server["ip_address"].string, server["provider"].string, server["region"].string])
    }

    /// The colour a site's state is drawn in.
    enum Tone: Equatable { case muted, danger, ok, accent }
    /// Installed green, failing red, under way blue (the accent), anything else muted.
    static func tone(_ state: String?) -> Tone {
        guard let s = state?.lowercased(), !s.isEmpty else { return .muted }
        if s.contains("fail") || s.contains("error") { return .danger }
        if ["installed", "deployed", "finished", "success"].contains(s) { return .ok }
        if s.contains("ing") || s == "queued" || s == "pending" { return .accent }
        return .muted
    }
}
