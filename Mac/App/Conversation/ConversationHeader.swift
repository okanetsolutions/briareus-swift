// The conversation header's buttons: the shared browser, the ⚡ Webhook, ✉ Mail wake, Resources, then stopping,
// reopening, closing and deleting the session, each where the server and the token allow it.
import SwiftUI

@MainActor
func conversationHeaderButtons(_ model: ConversationModel, store: Store) -> [HeaderButton] {
    let s = model.session
    let can = model.can
    let closed = s.isClosed
    var out: [HeaderButton] = []
    if store.supports("browser") {
        let browser = BrowserState.sessionOn(s.raw)
        out.append(HeaderButton(glyph: Glyph.symbol(0xE774), label: browser.on && browser.running ? "\u{1F310} Browser \u{25CF}" : "\u{1F310} Browser",
                                tip: "The session's shared browser") { BrowserDock.open(s) })
    }
    // An admin token's; the session record carries the settings, so the button says when deliveries are on.
    if store.supports("session_webhook") {
        let armed = s.raw["webhook"]["armed"].is(true)
        out.append(HeaderButton(glyph: "bolt", label: armed ? "\u{26A1} Webhook \u{25CF}" : "\u{26A1} Webhook",
                                tip: armed ? "Webhook (on)" : "Webhook") { Navigator.shared.push(.webhook(session: s.raw)) })
    }
    // An admin token's too; the record's mailWake says whether a rule is on.
    if store.supports("session_mail_wake") {
        let on = mailWakeOn(s.raw)
        out.append(HeaderButton(glyph: "envelope", label: on ? "\u{2709} Mail wake \u{25CF}" : "\u{2709} Mail wake",
                                tip: on ? "Mail wake (on)" : "Mail wake") { Navigator.shared.push(.mailWake(session: s.raw)) })
    }
    // What the session costs the machine, for any token.
    if store.supports("session_stats") {
        out.append(HeaderButton(glyph: "gauge.with.dots.needle.33percent", label: "Resources", tip: "CPU, memory and disk") {
            Navigator.shared.push(.sessionStats(session: s.raw))
        })
    }
    if store.supports("pin") {
        out.append(HeaderButton(glyph: s.pinSymbol, label: s.pinLabel, tip: s.pinLabel, enabled: can) { model.mutate("pin", s.pinBody) })
    }
    if store.supports("cancel") && s.isActive {
        out.append(HeaderButton(glyph: Glyph.symbol(0xE71A), label: "\u{23F9} Stop", tip: "Stop", enabled: can) { model.confirmAndMutate("cancel") })
    }
    if store.supports("reopen") && closed {
        out.append(HeaderButton(glyph: Glyph.symbol(0xE7A7), label: "\u{27F3} Reopen", tip: "Reopen", enabled: can) { model.confirmAndMutate("reopen") })
    }
    if store.supports("close") && !closed {
        out.append(HeaderButton(glyph: Glyph.symbol(0xE8BB), label: "Close", tip: "Close", enabled: can) { model.confirmAndMutate("close") })
    }
    if store.supports("delete") {
        out.append(HeaderButton(glyph: Glyph.symbol(0xE74D), label: "\u{1F5D1} Delete", tip: "Delete", enabled: can, destructive: true) { model.confirmAndMutate("delete") })
    }
    return out
}
