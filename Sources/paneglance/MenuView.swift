import AppKit
import SwiftUI

struct MenuSnapshot: Sendable {
    let header: String
    let nodeStatus: String
    let nodeAction: String
    let launchdFailure: String?
    let acceptingFailure: String?
    let machines: [MachineMenuLine]
    let lanes: [String]
    let queueSummary: String
    let activeTasks: [String]
    let decisions: String
}

struct MachineMenuLine: Sendable {
    let text: String
    let dotColor: NodeDotColor
}

enum MenuRenderer {
    static func snapshot(
        pollState: FleetPollState,
        nodeState: NodeRunState,
        launchdFailure: String?,
        acceptingFailure: String? = nil,
        timeZone: TimeZone = .current
    ) -> MenuSnapshot {
        let glance = pollState.glance
        return MenuSnapshot(
            header: header(status: pollState.status, lastSuccess: pollState.lastSuccess, timeZone: timeZone),
            nodeStatus: "Node: \(nodeState.rawValue)",
            nodeAction: nodeState == .running ? "Node Off" : "Node On",
            launchdFailure: launchdFailure,
            acceptingFailure: acceptingFailure,
            machines: glance?.nodes.map(machineLine) ?? [],
            lanes: glance?.lanes.map(laneLine) ?? [],
            queueSummary: queueLine(glance?.tasks.byState),
            activeTasks: glance?.tasks.active.prefix(5).map(activeTaskLine) ?? [],
            decisions: "Decisions pending: \(glance?.tasks.decisionsPending ?? 0)"
        )
    }

    static func menuItems(configured: Bool) -> [String] {
        configured ? [] : ["Not configured"]
    }

    static func header(status: FleetStatus, lastSuccess: Date?, timeZone: TimeZone = .current) -> String {
        let time = formatted(lastSuccess, format: status == .ok ? "HH:mm:ss" : "HH:mm", timeZone: timeZone)
        if status == .ok {
            return "Fleet · ok \(time ?? "--:--:--")"
        }
        return "Fleet · \(status.rawValue) since \(time ?? "--:--")"
    }

    static func machineLine(_ node: Node) -> MachineMenuLine {
        let load: String
        if let nodeLoad = node.load {
            load = String(
                format: "load %.1f/%d",
                locale: Locale(identifier: "en_US_POSIX"),
                nodeLoad.load1,
                nodeLoad.ncpu
            )
        } else {
            load = "load –"
        }
        let memory: String
        if let nodeMemory = node.memory {
            memory = "free \(Int(nodeMemory.freePct.rounded()))%  swap \(nodeMemory.swapUsedMB)"
        } else {
            memory = "free –  swap –"
        }
        let accepting = node.acceptingEffective ? "  [accepting]" : ""
        return MachineMenuLine(
            text: "\(node.machineID)  ●  \(load)  \(memory)\(accepting)",
            dotColor: node.dotColor
        )
    }

    static func laneLine(_ lane: Lane) -> String {
        let indent = lane.parent.isEmpty ? "" : "  "
        let sink = lane.sink ? " (sink)" : ""
        return "\(indent)\(lane.lane) → \(lane.machine) \(lane.pane)\(sink)"
    }

    static func queueLine(_ counts: TaskCounts?) -> String {
        "in_progress \(counts?.inProgress ?? 0) · verifying \(counts?.verifying ?? 0) · needs_decision \(counts?.needsDecision ?? 0)"
    }

    static func activeTaskLine(_ task: ActiveTask) -> String {
        let title = task.title.count <= 40 ? task.title : String(task.title.prefix(39)) + "…"
        return "#\(task.id) \(task.lane) · \(title)"
    }

    private static func formatted(_ date: Date?, format: String, timeZone: TimeZone) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}

@MainActor
struct MenuView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        if !store.configured {
            ForEach(MenuRenderer.menuItems(configured: store.configured), id: \.self) { item in
                Button(item) {}
                    .disabled(true)
            }
        } else {
            let snapshot = store.snapshot
            Text(snapshot.header)
            Divider()
            Text("This Mac")
            Text(snapshot.nodeStatus)
            Button(snapshot.nodeAction) { store.toggleNode() }
            Toggle("Accepting", isOn: Binding(
                get: { store.accepting },
                set: { _ in store.toggleAccepting() }
            ))
            .disabled(!store.acceptingAvailable)
            if let failure = snapshot.launchdFailure {
                Text(failure)
            }
            if let failure = snapshot.acceptingFailure {
                Text(failure)
            }
            Divider()
            Text("Machines")
            ForEach(Array(snapshot.machines.enumerated()), id: \.offset) { _, machine in
                Text(machine.text)
                    .foregroundStyle(dotColor(machine.dotColor))
            }
            Divider()
            Text("Lanes")
            ForEach(Array(snapshot.lanes.enumerated()), id: \.offset) { _, lane in
                Text(lane)
            }
            Divider()
            Text("Queue")
            Text(snapshot.queueSummary)
            ForEach(Array(snapshot.activeTasks.enumerated()), id: \.offset) { _, task in
                Text(task)
            }
            Button(snapshot.decisions) { store.openDecisions() }
            Divider()
            Button("Refresh now") { store.refresh() }
            Button("Open console") { store.openConsole() }
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }

    private func dotColor(_ color: NodeDotColor) -> Color {
        switch color {
        case .normal: .primary
        case .gray: .gray
        case .yellow: .yellow
        case .red: .red
        }
    }
}
