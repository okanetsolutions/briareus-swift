// SQL run on a server's MySQL over SSH (the Windows client's app/ssh_query.c): this Mac's OpenSSH client, /usr/bin/ssh,
// starts the server's own `mysql` client, which reads the password and then the statements from its standard input
// (SQLLogin), so neither shows on a command line. With no terminal, ssh asks for passwords and host keys through
// SSH_ASKPASS, which is this app (Askpass.swift), as the SFTP sessions' do. Each query is a process of its own, in the home
// folder where ~/.ssh is; a cancelled one is ended.
import Foundation

enum SSHQuery {
    static let client = "/usr/bin/ssh"

    /// `mysql --batch` output when `ok`, else what ssh or mysql said went wrong.
    struct Answer: Sendable { var ok: Bool; var out: String }

    /// Runs `sql` on the server; cancelling the task ends its ssh.
    static func run(_ target: TermTarget, login: SQLLogin, sql: String) async -> Answer {
        if let problem = target.problem ?? login.problem { return Answer(ok: false, out: problem) }
        let askpass = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let p = Process()
        p.executableURL = URL(fileURLWithPath: client)
        p.arguments = ["-T", "-p", String(target.port), "-o", "User=\(target.user)", "-o", "ServerAliveInterval=30", "-o", "LogLevel=ERROR",
                       "--", target.host, login.remoteCommand]
        p.environment = SSHAskpass.environment(base: ProcessInfo.processInfo.environment, askpass: askpass)
        p.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        let input = Pipe(), output = Pipe(), errors = Pipe()
        p.standardInput = input; p.standardOutput = output; p.standardError = errors
        // A write to an ssh that has already ended fails instead of ending the app.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let box = ProcessBox(p)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (done: CheckedContinuation<Answer, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { try p.run() } catch {
                        done.resume(returning: Answer(ok: false, out: "Could not start ssh (\(error.localizedDescription))."))
                        return
                    }
                    // The input is a few lines: written whole and closed at once.
                    try? input.fileHandleForWriting.write(contentsOf: Data(login.input(sql).utf8))
                    try? input.fileHandleForWriting.close()
                    // Both outputs are read as they come, so neither fills while the other is waited on.
                    let errBox = DataBox()
                    let group = DispatchGroup()
                    group.enter()
                    DispatchQueue.global().async { errBox.data = errors.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                    let out = output.fileHandleForReading.readDataToEndOfFile()
                    group.wait()
                    let err = errBox.data
                    p.waitUntilExit()
                    let code = p.terminationStatus
                    if code == 0 && p.terminationReason == .exit {
                        done.resume(returning: Answer(ok: true, out: String(decoding: out, as: UTF8.self)))
                        return
                    }
                    let why = String(decoding: err.isEmpty ? out : err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    done.resume(returning: Answer(ok: false, out: why.isEmpty ? "ssh ended with code \(code)." : why))
                }
            }
        } onCancel: {
            box.terminate()
        }
    }
}

/// What stderr said, read on a queue of its own.
private final class DataBox: @unchecked Sendable { var data = Data() }

/// The process, for a cancel from any thread.
private final class ProcessBox: @unchecked Sendable {
    let process: Process
    init(_ p: Process) { process = p }
    func terminate() { if process.isRunning { process.terminate() } }
}
