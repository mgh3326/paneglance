import AppKit
import SwiftUI

@main
struct PaneGlanceApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        MenuBarExtra("PaneGlance", systemImage: "rectangle.3.group") {
            MenuView(store: store)
                .onAppear { store.menuDidOpen() }
        }
    }
}

@MainActor
final class AppStore: ObservableObject {
    let configuration: AppConfiguration?
    let client: GlanceClient?
    let launchd: LaunchdController?
    let acceptingState = AcceptingState()
    private var pollState = FleetPollState()
    private var nodeState: NodeRunState = .stopped
    private var launchdFailure: String?
    private var pollingTask: Task<Void, Never>?

    @Published private(set) var snapshot: MenuSnapshot
    @Published private(set) var accepting = false
    @Published private(set) var acceptingAvailable = false

    var configured: Bool { configuration != nil }

    init(configuration: AppConfiguration? = AppConfiguration.load()) {
        self.configuration = configuration
        if let configuration {
            client = GlanceClient(
                consoleURL: configuration.consoleURL,
                credentials: configuration.credentials
            )
            launchd = LaunchdController(label: configuration.launchdLabel, plistPath: configuration.launchdPlist)
        } else {
            client = nil
            launchd = nil
        }
        snapshot = MenuRenderer.snapshot(pollState: pollState, nodeState: nodeState, launchdFailure: launchdFailure)
    }

    func menuDidOpen() {
        guard configured else { return }
        refresh()
        if pollingTask == nil {
            pollingTask = Task { [weak self] in
                guard let self, let interval = self.configuration?.pollSeconds else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(interval))
                    guard !Task.isCancelled else { break }
                    self.refresh()
                }
            }
        }
    }

    func refresh() {
        guard let client else { return }
        if let launchd {
            let inspection = launchd.inspect()
            nodeState = inspection.state
            launchdFailure = inspection.reason.map { "Node status: \($0)" }
        }
        Task { [weak self] in
            guard let self else { return }
            let outcome = await client.fetchGlance()
            self.pollState.apply(outcome, at: Date())
            self.acceptingState.updateFromGlance(self.pollState.glance, machineID: self.configuration?.machineID ?? "")
            self.accepting = self.acceptingState.accepting ?? false
            self.acceptingAvailable = self.acceptingState.accepting != nil
            self.render()
        }
        render()
    }

    func toggleAccepting() {
        guard let client, let machineID = configuration?.machineID else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.acceptingState.toggle(using: client, machineID: machineID)
            self.accepting = self.acceptingState.accepting ?? false
            self.launchdFailure = self.acceptingState.failureReason
            self.render()
        }
        accepting.toggle()
    }

    func toggleNode() {
        guard let launchd else { return }
        let operation: NodeOperation = nodeState == .running ? .off : .on
        launchdFailure = launchd.perform(operation)
        let inspection = launchd.inspect()
        nodeState = inspection.state
        if launchdFailure == nil { launchdFailure = inspection.reason.map { "Node status: \($0)" } }
        render()
    }

    func openConsole() {
        guard let url = configuration?.consoleURL else { return }
        NSWorkspace.shared.open(url)
    }

    func openDecisions() {
        guard let configuration, let paths = pollState.glance?.consolePaths else { return }
        NSWorkspace.shared.open(configuration.consoleURL.appending(path: paths.decisions))
    }

    private func render() {
        snapshot = MenuRenderer.snapshot(
            pollState: pollState,
            nodeState: nodeState,
            launchdFailure: launchdFailure
        )
    }
}

struct AppConfiguration: Sendable {
    let consoleURL: URL
    let credentials: AccessCredentials?
    let machineID: String
    let launchdLabel: String
    let launchdPlist: String
    let pollSeconds: Double

    static func load(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> AppConfiguration? {
        let configURL = homeDirectory.appending(path: ".config/paneglance/config.toml")
        guard let contents = try? String(contentsOf: configURL, encoding: .utf8) else { return nil }
        let values = TOML.parse(contents)
        guard
            let urlText = values["console_url"], let consoleURL = URL(string: urlText),
            let machineID = values["machine_id"], !machineID.isEmpty,
            let label = values["launchd_label"], !label.isEmpty,
            let plist = values["launchd_plist"],
            let seconds = values["poll_seconds"].flatMap(Double.init)
        else { return nil }
        let credentialFile = values["cf_access_env"].map { TOML.expandingHome($0, homeDirectory: homeDirectory) }
        let credentials = credentialFile.flatMap { readCredentials(at: URL(fileURLWithPath: $0)) }
        return AppConfiguration(
            consoleURL: consoleURL,
            credentials: credentials,
            machineID: machineID,
            launchdLabel: label,
            launchdPlist: TOML.expandingHome(plist, homeDirectory: homeDirectory),
            pollSeconds: max(seconds, 1)
        )
    }

    private static func readCredentials(at url: URL) -> AccessCredentials? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let values = TOML.parseEnvironment(contents)
        guard let clientID = values["CF_ACCESS_CLIENT_ID"], let clientSecret = values["CF_ACCESS_CLIENT_SECRET"] else {
            return nil
        }
        return AccessCredentials(clientID: clientID, clientSecret: clientSecret)
    }
}

enum TOML {
    static func parse(_ source: String) -> [String: String] {
        source.split(whereSeparator: \.isNewline).reduce(into: [:]) { values, line in
            let line = stripComment(String(line)).trimmingCharacters(in: .whitespaces)
            guard let equals = line.firstIndex(of: "=") else { return }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.first == "\"", value.last == "\"" {
                value.removeFirst()
                value.removeLast()
            }
            guard !key.isEmpty else { return }
            values[String(key)] = value
        }
    }

    static func parseEnvironment(_ source: String) -> [String: String] {
        source.split(whereSeparator: \.isNewline).reduce(into: [:]) { values, line in
            var line = String(line).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("export ") { line.removeFirst("export ".count) }
            guard let equals = line.firstIndex(of: "=") else { return }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { return }
            values[String(key)] = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
    }

    static func expandingHome(_ value: String, homeDirectory: URL) -> String {
        guard value == "~" || value.hasPrefix("~/") else { return value }
        return homeDirectory.path + String(value.dropFirst())
    }

    private static func stripComment(_ value: String) -> String {
        var quoted = false
        for index in value.indices {
            if value[index] == "\"" { quoted.toggle() }
            if value[index] == "#" && !quoted { return String(value[..<index]) }
        }
        return value
    }
}
