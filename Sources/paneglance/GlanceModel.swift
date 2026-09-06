import Foundation

enum FleetStatus: String, Codable, CaseIterable, Sendable {
    case ok
    case offline
    case unauthorized
    case hubDown = "hub_down"
}

enum NodeRunState: String, Sendable {
    case running
    case stopped
}

enum NodeDotColor: String, Sendable {
    case normal
    case gray
    case yellow
    case red
}

struct GlanceResponse: Decodable, Sendable {
    let generatedAt: String
    let hub: Hub
    let nodes: [Node]
    let lanes: [Lane]
    let jobs: [Job]
    let tasks: Tasks
    let consolePaths: ConsolePaths

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case hub, nodes, lanes, jobs, tasks
        case consolePaths = "console_paths"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try container.decodeIfPresent(String.self, forKey: .generatedAt) ?? ""
        hub = try container.decode(Hub.self, forKey: .hub)
        nodes = try container.decodeIfPresent([Node].self, forKey: .nodes) ?? []
        lanes = try container.decodeIfPresent([Lane].self, forKey: .lanes) ?? []
        jobs = try container.decodeIfPresent([Job].self, forKey: .jobs) ?? []
        tasks = try container.decode(Tasks.self, forKey: .tasks)
        consolePaths = try container.decode(ConsolePaths.self, forKey: .consolePaths)
    }
}

struct Hub: Decodable, Sendable {
    let ok: Bool
    let error: String

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decode(Bool.self, forKey: .ok)
        error = try container.decodeIfPresent(String.self, forKey: .error) ?? ""
    }

    private enum CodingKeys: String, CodingKey { case ok, error }
}

struct Node: Decodable, Sendable {
    let machineID: String
    let state: String
    let accepting: Bool
    let acceptingEffective: Bool
    let acceptingOverride: String
    let alertClass: String
    let connectedSince: String
    let lastPingMS: Int?
    let load: Load?
    let memory: Memory?
    let activeJobs: Int

    enum CodingKeys: String, CodingKey {
        case machineID = "machine_id"
        case state, accepting
        case acceptingEffective = "accepting_effective"
        case acceptingOverride = "accepting_override"
        case alertClass = "alert_class"
        case connectedSince = "connected_since"
        case lastPingMS = "last_ping_ms"
        case load, memory
        case activeJobs = "active_jobs"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        machineID = try container.decode(String.self, forKey: .machineID)
        state = try container.decodeIfPresent(String.self, forKey: .state) ?? ""
        accepting = try container.decodeIfPresent(Bool.self, forKey: .accepting) ?? false
        acceptingEffective = try container.decodeIfPresent(Bool.self, forKey: .acceptingEffective) ?? false
        acceptingOverride = try container.decodeIfPresent(String.self, forKey: .acceptingOverride) ?? ""
        alertClass = try container.decodeIfPresent(String.self, forKey: .alertClass) ?? ""
        connectedSince = try container.decodeIfPresent(String.self, forKey: .connectedSince) ?? ""
        lastPingMS = try container.decodeIfPresent(Int.self, forKey: .lastPingMS)
        load = try container.decodeIfPresent(Load.self, forKey: .load)
        memory = try container.decodeIfPresent(Memory.self, forKey: .memory)
        activeJobs = try container.decodeIfPresent(Int.self, forKey: .activeJobs) ?? 0
    }

    var dotColor: NodeDotColor {
        guard state == "connected" else { return .gray }
        let normalizedAlert = alertClass.lowercased()
        if normalizedAlert.contains("red") || normalizedAlert.contains("critical") || normalizedAlert.contains("error") {
            return .red
        }
        return normalizedAlert.isEmpty ? .normal : .yellow
    }
}

struct Load: Decodable, Sendable {
    let load1: Double
    let load5: Double
    let load15: Double
    let ncpu: Int
}

struct Memory: Decodable, Sendable {
    let freePct: Double
    let compressedMB: Double?
    let swapUsedMB: Int
    let source: String

    enum CodingKeys: String, CodingKey {
        case freePct = "free_pct"
        case compressedMB = "compressed_mb"
        case swapUsedMB = "swap_used_mb"
        case source
    }
}

struct Lane: Decodable, Sendable {
    let lane: String
    let machine: String
    let pane: String
    let parent: String
    let sink: Bool

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lane = try container.decode(String.self, forKey: .lane)
        machine = try container.decode(String.self, forKey: .machine)
        pane = try container.decode(String.self, forKey: .pane)
        parent = try container.decodeIfPresent(String.self, forKey: .parent) ?? ""
        sink = try container.decodeIfPresent(Bool.self, forKey: .sink) ?? false
    }

    private enum CodingKeys: String, CodingKey { case lane, machine, pane, parent, sink }
}

struct Job: Decodable, Sendable {
    let jobID: String
    let machine: String
    let ownerLane: String
    let role: String
    let tier: String
    let startedAt: String
    let lastEventKind: String
    let lastEventAt: String

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case machine
        case ownerLane = "owner_lane"
        case role, tier
        case startedAt = "started_at"
        case lastEventKind = "last_event_kind"
        case lastEventAt = "last_event_at"
    }
}

struct Tasks: Decodable, Sendable {
    let byState: TaskCounts
    let decisionsPending: Int
    let active: [ActiveTask]

    enum CodingKeys: String, CodingKey {
        case byState = "by_state"
        case decisionsPending = "decisions_pending"
        case active
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        byState = try container.decode(TaskCounts.self, forKey: .byState)
        decisionsPending = try container.decodeIfPresent(Int.self, forKey: .decisionsPending) ?? 0
        active = try container.decodeIfPresent([ActiveTask].self, forKey: .active) ?? []
    }
}

struct TaskCounts: Decodable, Sendable {
    let backlog: Int
    let claimed: Int
    let inProgress: Int
    let verifying: Int
    let join: Int
    let needsDecision: Int
    let hold: Int

    enum CodingKeys: String, CodingKey {
        case backlog, claimed, join, hold
        case inProgress = "in_progress"
        case verifying
        case needsDecision = "needs_decision"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        backlog = try container.decodeIfPresent(Int.self, forKey: .backlog) ?? 0
        claimed = try container.decodeIfPresent(Int.self, forKey: .claimed) ?? 0
        inProgress = try container.decodeIfPresent(Int.self, forKey: .inProgress) ?? 0
        verifying = try container.decodeIfPresent(Int.self, forKey: .verifying) ?? 0
        join = try container.decodeIfPresent(Int.self, forKey: .join) ?? 0
        needsDecision = try container.decodeIfPresent(Int.self, forKey: .needsDecision) ?? 0
        hold = try container.decodeIfPresent(Int.self, forKey: .hold) ?? 0
    }
}

struct ActiveTask: Decodable, Sendable {
    let id: Int
    let lane: String
    let title: String
    let kind: String
    let state: String
    let claimedBy: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, lane, title, kind, state
        case claimedBy = "claimed_by"
        case updatedAt = "updated_at"
    }
}

struct ConsolePaths: Decodable, Sendable {
    let decisions: String
    let queue: String
    let fleet: String
}

enum FetchOutcome: Sendable {
    case response(GlanceResponse)
    case httpStatus(Int)
    case transport
}

struct FleetPollState: Sendable {
    private(set) var status: FleetStatus = .offline
    private(set) var lastSuccess: Date?
    private(set) var glance: GlanceResponse?

    mutating func apply(_ outcome: FetchOutcome, at date: Date) {
        switch outcome {
        case .response(let response):
            glance = response
            lastSuccess = date
            status = response.hub.ok ? .ok : .hubDown
        case .httpStatus(let code):
            status = (code == 401 || code == 403) ? .unauthorized : .offline
        case .transport:
            status = .offline
        }
    }
}

@MainActor
final class AcceptingState {
    private(set) var accepting: Bool?
    private(set) var failureReason: String?

    init(accepting: Bool? = nil) {
        self.accepting = accepting
    }

    func updateFromGlance(_ response: GlanceResponse?, machineID: String) {
        guard let node = response?.nodes.first(where: { $0.machineID == machineID }) else { return }
        accepting = node.accepting
        failureReason = nil
    }

    func toggle(using client: GlanceClient, machineID: String) async {
        guard let original = accepting else { return }
        let requested = !original
        accepting = requested
        failureReason = nil
        let result = await client.setAccepting(machineID: machineID, accepting: requested)
        guard case .success = result else {
            accepting = original
            failureReason = result.failureReason
            return
        }
    }
}
