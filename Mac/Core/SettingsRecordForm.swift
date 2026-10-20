// A settings form saved as one record on the server (a project, a provider, a database or SSH server, a Forge account, a
// Slack workspace), the same on the iPhone and the Mac: which operation creates, updates or deletes it, the body a save
// sends with the record's id, how the answer fills the form again, and what leaving it unsaved says. Each form's own
// state (its fields and `body()`) is in SettingsLogic.swift, SSHServerLogic.swift and AccountSettingsLogic.swift.
import Foundation

/// The operations and words of one kind of record.
struct SettingsRecord: Sendable {
    let create: String
    let update: String
    let delete: String
    /// The key of the saved record in a create or update answer.
    let answerKey: String
    /// "Forge account", as "The new Forge account has not been saved." says it.
    let noun: String
    /// "this Forge account": the record when its row has no label.
    let unnamed: String
}

protocol SettingsRecordForm {
    static var record: SettingsRecord { get }
    /// The row the form was filled from; empty for a new record.
    var row: JSON { get set }
    /// The record's id as the server numbers it; 0 for a record not created yet.
    var recordID: Double { get }
    var dirty: Bool { get set }
    /// The fields as a save sends them, or what stops the save.
    func body() -> Result<JSON, FormProblem>
    /// Fills the boxes again from `row`.
    mutating func fill()
}

extension SettingsRecordForm {
    var isNew: Bool { recordID == 0 }
    /// Updates a record the server already has; creates a new one.
    var saveOperation: String { isNew ? Self.record.create : Self.record.update }
    /// The save's body: the fields, with the id of a record being updated.
    func saveRequest() -> Result<JSON, FormProblem> {
        body().map { fields in
            var out = fields
            if !isNew { out["id"] = JSON(recordID) }
            return out
        }
    }
    /// Takes the server's word on what was saved: an empty label filled in, a new record's id. Nil when the answer holds
    /// no record, and the form is left as it was.
    mutating func saved(_ answer: JSON) -> JSON? {
        let saved = answer[Self.record.answerKey]
        guard saved.isObject else { return nil }
        row = saved
        fill()
        return saved
    }
    /// The record as messages name it: its label, else "this …".
    var name: String { row["label"].nonEmpty ?? Self.record.unnamed }
    /// What closing the form with changes not saved asks about.
    var discardMessage: String {
        isNew ? "The new \(Self.record.noun) has not been saved." : "The changes to \(name) have not been saved."
    }
}

extension ProjectFormState: SettingsRecordForm {
    var recordID: Double { Double(id) }
    static let record = SettingsRecord(create: "create_project", update: "update_project", delete: "delete_project",
                                       answerKey: "project", noun: "project", unnamed: "this project")
}
extension ProviderFormState: SettingsRecordForm {
    var recordID: Double { Double(id) }
    func body() -> Result<JSON, FormProblem> { body(validate: true) }
    static let record = SettingsRecord(create: "create_provider", update: "update_provider", delete: "delete_provider",
                                       answerKey: "provider", noun: "provider", unnamed: "this provider")
}
extension DBServerFormState: SettingsRecordForm {
    var recordID: Double { Double(id) }
    static let record = SettingsRecord(create: "create_db_server", update: "update_db_server", delete: "delete_db_server",
                                       answerKey: "server", noun: "database server", unnamed: "this server")
}
extension SSHServerFormState: SettingsRecordForm {
    var recordID: Double { id }
    static let record = SettingsRecord(create: "create_ssh_server", update: "update_ssh_server", delete: "delete_ssh_server",
                                       answerKey: "server", noun: "SSH server", unnamed: "this SSH server")
}
extension ForgeAccountFormState: SettingsRecordForm {
    var recordID: Double { id }
    static let record = SettingsRecord(create: "create_forge_account", update: "update_forge_account", delete: "delete_forge_account",
                                       answerKey: "account", noun: "Forge account", unnamed: "this Forge account")
}
extension SlackWorkspaceFormState: SettingsRecordForm {
    var recordID: Double { id }
    static let record = SettingsRecord(create: "create_slack_workspace", update: "update_slack_workspace",
                                       delete: "delete_slack_workspace", answerKey: "workspace", noun: "Slack workspace",
                                       unnamed: "this Slack workspace")
}
