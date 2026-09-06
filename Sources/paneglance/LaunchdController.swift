import Foundation

struct LaunchdInspection: Sendable, Equatable {
    let state: NodeRunState
    let reason: String?
}

enum NodeOperation: Sendable {
    case on
    case off
}

struct LaunchdController {
    let label: String
    let plistPath: String
    private let userID: uid_t

    init(label: String, plistPath: String, userID: uid_t = getuid()) {
        self.label = label
        self.plistPath = plistPath
        self.userID = userID
    }

    func inspect() -> LaunchdInspection {
        let result = run(arguments: ["print", "gui/\(userID)/\(label)"])
        return Self.parsePrint(exitCode: result.exitCode, output: result.output)
    }

    func perform(_ operation: NodeOperation) -> String? {
        let arguments: [String]
        let title: String
        switch operation {
        case .on:
            arguments = ["bootstrap", "gui/\(userID)", plistPath]
            title = "Node On"
        case .off:
            arguments = ["bootout", "gui/\(userID)/\(label)"]
            title = "Node Off"
        }
        let result = run(arguments: arguments)
        return result.exitCode == 0 ? nil : "\(title) failed: exit \(result.exitCode)"
    }

    static func parsePrint(exitCode: Int32, output: String) -> LaunchdInspection {
        guard exitCode == 0 else {
            return LaunchdInspection(state: .stopped, reason: "exit \(exitCode)")
        }
        let states = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("state =") }
        guard let line = states.first else {
            return LaunchdInspection(state: .stopped, reason: "state unavailable")
        }
        if line == "state = running" {
            return LaunchdInspection(state: .running, reason: nil)
        }
        if line == "state = not running" {
            return LaunchdInspection(state: .stopped, reason: nil)
        }
        return LaunchdInspection(state: .stopped, reason: "state unavailable")
    }

    private func run(arguments: [String]) -> (exitCode: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        do {
            try process.run()
            process.waitUntilExit()
            let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return (process.terminationStatus, stdout + stderr)
        } catch {
            return (-1, "")
        }
    }
}
