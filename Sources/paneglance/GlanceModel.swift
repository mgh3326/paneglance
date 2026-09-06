import Foundation

// The hub derives its numbers from OS counters in floating point, so a field that
// looks integral in the contract example ("swap_used_mb": 0) reaches us as
// 14446.44 from a real node. JSONDecoder rejects that outright for an `Int`
// property ("Number 14446.44 is not representable in Swift") and fails the *whole*
// payload, so one decimal parked the menu on `offline` forever. Every measured
// quantity below is therefore `Double`; the fields that count things stay `Int`
// and decode through `decodeLenientIntIfPresent`.
extension KeyedDecodingContainer {
    /// Decodes a count as `Int` while tolerating a JSON number that carries a
    /// fractional part.
    ///
    /// `ncpu`, `active_jobs`, the task tallies, `decisions_pending` and
    /// `active[].id` count whole things, so they stay `Int` here rather than
    /// leaking a `Double` into arithmetic and rendering. But the hub is free to
    /// compute them in floating point, and an `Int` property that meets `5.5`
    /// fails the entire response — the same failure mode `swap_used_mb` caused.
    /// Reading through `Double` and flooring degrades one odd value instead of
    /// losing every node, lane and job alongside it. A value too large for `Int`
    /// (or non-finite) would trap on conversion, so it decodes as a missing count.
    func decodeLenientIntIfPresent(forKey key: Key) throws -> Int? {
        if let value = try? decode(Int.self, forKey: key) { return value }
        guard
            let value = try decodeIfPresent(Double.self, forKey: key),
            value.isFinite, value >= Double(Int.min), value < Double(Int.max)
        else { return nil }
        return Int(value.rounded(.down))
    }
}

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
    let lastPingMS: Double?
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
        lastPingMS = try container.decodeIfPresent(Double.self, forKey: .lastPingMS)
        load = try container.decodeIfPresent(Load.self, forKey: .load)
        memory = try container.decodeIfPresent(Memory.self, forKey: .memory)
        activeJobs = try container.decodeLenientIntIfPresent(forKey: .activeJobs) ?? 0
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
    let load1: Double?
    let load5: Double?
    let load15: Double?
    let ncpu: Int?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        load1 = try container.decodeIfPresent(Double.self, forKey: .load1)
        load5 = try container.decodeIfPresent(Double.self, forKey: .load5)
        load15 = try container.decodeIfPresent(Double.self, forKey: .load15)
        ncpu = try container.decodeLenientIntIfPresent(forKey: .ncpu)
    }

    private enum CodingKeys: String, CodingKey { case load1, load5, load15, ncpu }
}

struct Memory: Decodable, Sendable {
    let freePct: Double?
    let compressedMB: Double?
    let swapUsedMB: Double?
    let source: String

    enum CodingKeys: String, CodingKey {
        case freePct = "free_pct"
        case compressedMB = "compressed_mb"
        case swapUsedMB = "swap_used_mb"
        case source
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        freePct = try container.decodeIfPresent(Double.self, forKey: .freePct)
        compressedMB = try container.decodeIfPresent(Double.self, forKey: .compressedMB)
        swapUsedMB = try container.decodeIfPresent(Double.self, forKey: .swapUsedMB)
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? ""
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
        decisionsPending = try container.decodeLenientIntIfPresent(forKey: .decisionsPending) ?? 0
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
        backlog = try container.decodeLenientIntIfPresent(forKey: .backlog) ?? 0
        claimed = try container.decodeLenientIntIfPresent(forKey: .claimed) ?? 0
        inProgress = try container.decodeLenientIntIfPresent(forKey: .inProgress) ?? 0
        verifying = try container.decodeLenientIntIfPresent(forKey: .verifying) ?? 0
        join = try container.decodeLenientIntIfPresent(forKey: .join) ?? 0
        needsDecision = try container.decodeLenientIntIfPresent(forKey: .needsDecision) ?? 0
        hold = try container.decodeLenientIntIfPresent(forKey: .hold) ?? 0
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

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeLenientIntIfPresent(forKey: .id) ?? 0
        lane = try container.decode(String.self, forKey: .lane)
        title = try container.decode(String.self, forKey: .title)
        kind = try container.decode(String.self, forKey: .kind)
        state = try container.decode(String.self, forKey: .state)
        claimedBy = try container.decode(String.self, forKey: .claimedBy)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
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
