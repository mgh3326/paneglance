import Foundation
import Testing
@testable import paneglance

@Suite(.serialized)
struct PaneglanceTests {
@Test("the verbatim glance fixture decodes through the HTTP client")
func glanceFixtureDecodes() async throws {
    let client = clientResponding(status: 200, body: try fixture("glance-ok.json"))
    let outcome = await client.fetchGlance()
    guard case .response(let response) = outcome else {
        Issue.record("Expected the HTTP client to decode the glance response")
        return
    }
    #expect(response.hub.ok == true)
    #expect(response.nodes[0].machineID == "machine-a")
    #expect(response.nodes[0].memory?.compressedMB == nil)
    #expect(response.lanes[0].pane == "w1:p1")
    #expect(response.jobs[0].jobID == "job-a")
}

@Test("optional null fields decode as nil")
func optionalNullFieldsDecode() throws {
    let response = try decodeFixture("glance-null-values.json")
    #expect(response.nodes[0].load == nil)
    #expect(response.nodes[0].memory == nil)
    #expect(response.nodes[1].memory?.compressedMB == nil)
}

@Test("a glance superset ignores added hub fields while preserving contract fields")
func glanceSupersetDecodes() throws {
    let response = try decodeFixture("glance-superset.json")
    #expect(response.nodes[0].machineID == "machine-a")
    #expect(response.nodes[0].load?.load1 == 0.4)
    #expect(response.nodes[0].memory?.freePct == 91.8)
    #expect(response.jobs[0].jobID == "job-a")
}

@Test("state vocabulary transitions preserve the last successful timestamp")
func fleetStateTransitions() async throws {
    let first = Date(timeIntervalSince1970: 100)
    let second = Date(timeIntervalSince1970: 200)
    var state = FleetPollState()
    let successfulClient = clientResponding(status: 200, body: try fixture("glance-ok.json"))
    let successful = await awaitValue(successfulClient)
    state.apply(successful, at: first)
    #expect(state.status == .ok)
    #expect(state.lastSuccess == first)
    StubURLProtocol.result = .transport
    let offlineClient = GlanceClient(consoleURL: URL(string: "https://console.example")!, credentials: nil, session: stubbedSession())
    let offline = await awaitValue(offlineClient)
    state.apply(offline, at: second)
    #expect(state.status == .offline)
    #expect(state.lastSuccess == first)
    let recoveredClient = clientResponding(status: 200, body: try fixture("glance-ok.json"))
    let recovered = await awaitValue(recoveredClient)
    state.apply(recovered, at: second)
    #expect(state.status == .ok)
    #expect(state.lastSuccess == second)
}

@Test("401 and 403 transition only to unauthorized")
func unauthorizedStateTransition() async {
    var state = FleetPollState()
    let unauthorized401 = await awaitValue(clientResponding(status: 401, body: Data()))
    state.apply(unauthorized401, at: .now)
    #expect(state.status == .unauthorized)
    #expect(state.status.rawValue == "unauthorized")
    let unauthorized403 = await awaitValue(clientResponding(status: 403, body: Data()))
    state.apply(unauthorized403, at: .now)
    #expect(state.status == .unauthorized)
    #expect(state.status.rawValue == "unauthorized")
}

@Test("a 200 response with a down hub transitions to hub_down")
func hubDownStateTransition() async throws {
    let downData = try JSONSerialization.jsonObject(with: fixture("glance-ok.json")) as! [String: Any]
    var modified = downData
    modified["hub"] = ["ok": false, "error": "unreachable"]
    let body = try JSONSerialization.data(withJSONObject: modified)
    var state = FleetPollState()
    let firstOutcome = await awaitValue(clientResponding(status: 200, body: try fixture("glance-ok.json")))
    state.apply(firstOutcome, at: .distantPast)
    let succeeded = Date(timeIntervalSince1970: 300)
    let hubDown = await awaitValue(clientResponding(status: 200, body: body))
    state.apply(hubDown, at: succeeded)
    #expect(state.status == .hubDown)
    #expect(state.lastSuccess == succeeded)
}

@Test("menu rendering uses literal en dashes, truncation, accepting, and lane indentation")
func menuRendering() throws {
    let response = try decodeFixture("glance-null-values.json")
    var state = FleetPollState()
    state.apply(.response(response), at: Date(timeIntervalSince1970: 45_296))
    let snapshot = MenuRenderer.snapshot(
        pollState: state,
        nodeState: .running,
        launchdFailure: "Node Off failed: exit 113",
        timeZone: TimeZone(secondsFromGMT: 0)!
    )
    #expect(snapshot.header == "Fleet · ok 12:34:56")
    #expect(snapshot.nodeStatus == "Node: running")
    #expect(snapshot.nodeAction == "Node Off")
    #expect(snapshot.launchdFailure == "Node Off failed: exit 113")
    #expect(snapshot.acceptingFailure == nil)
    #expect(snapshot.machines[0].text == "machine-a  ●  load –  free –  swap –  [accepting]")
    #expect(snapshot.machines[0].dotColor == .normal)
    #expect(snapshot.machines[1].text == "machine-a  ●  load 1.2/8  free 50%  swap 7")
    #expect(snapshot.machines[1].dotColor == .yellow)
    #expect(snapshot.lanes == ["lane-a → machine-a w1:p1", "  lane-a → machine-a w1:p1 (sink)"])
    #expect(snapshot.queueSummary == "in_progress 3 · verifying 1 · needs_decision 2")
    #expect(snapshot.activeTasks == ["#1 lane-a · 123456789012345678901234567890123456789…"])
    #expect(snapshot.decisions == "Decisions pending: 2")
}

@Test("an absent configuration renders only the literal Not configured menu item")
@MainActor
func notConfiguredMenuRendering() {
    let store = AppStore(configuration: nil)
    #expect(store.configured == false)
    #expect(MenuRenderer.menuItems(configured: store.configured) == ["Not configured"])
}

@Test("AppStore keeps launchd and accepting failure reasons independent")
@MainActor
func appStoreFailureReasonsRemainIndependent() {
    let store = AppStore(configuration: nil)
    store.recordLaunchdFailure("Node Off failed: exit 113")
    store.recordAcceptingFailure(nil)
    #expect(store.snapshot.launchdFailure == "Node Off failed: exit 113")
    #expect(store.snapshot.acceptingFailure == nil)

    store.recordAcceptingFailure("Accepting failed: HTTP 503")
    store.recordLaunchdFailure(nil)
    #expect(store.snapshot.launchdFailure == nil)
    #expect(store.snapshot.acceptingFailure == "Accepting failed: HTTP 503")
}

@Test("non-ok headers use since time and an absent timestamp")
func nonOKHeaderRendering() {
    #expect(MenuRenderer.header(status: .offline, lastSuccess: nil, timeZone: .gmt) == "Fleet · offline since --:--")
    #expect(MenuRenderer.header(status: .unauthorized, lastSuccess: Date(timeIntervalSince1970: 45_000), timeZone: .gmt) == "Fleet · unauthorized since 12:30")
}

@Test("launchctl print parser recognizes running, stopped, and missing services")
func launchdParser() throws {
    #expect(LaunchdController.parsePrint(exitCode: 0, output: try fixtureText("launchctl-running.txt")) == LaunchdInspection(state: .running, reason: nil))
    #expect(LaunchdController.parsePrint(exitCode: 0, output: try fixtureText("launchctl-stopped.txt")) == LaunchdInspection(state: .stopped, reason: nil))
    #expect(LaunchdController.parsePrint(exitCode: 113, output: try fixtureText("launchctl-missing.txt")) == LaunchdInspection(state: .stopped, reason: "exit 113"))
}

@Test("the verbatim real hub response decodes, decimals and nulls included")
func realGlanceResponseDecodes() async throws {
    // The file is a real /ui/api/glance body with identifiers substituted; values,
    // structure, nulls and decimals are untouched. Before the numeric fix this
    // decode threw "Number 14446.44 is not representable in Swift" and the client
    // reported .transport, which is what pinned the menu to offline.
    let client = clientResponding(status: 200, body: try fixture("glance-real-sanitized.json"))
    let outcome = await client.fetchGlance()
    guard case .response(let response) = outcome else {
        Issue.record("Expected the real hub response to decode instead of falling back to .transport")
        return
    }
    #expect(response.hub.ok == true)
    #expect(response.nodes.count == 6)
    #expect(response.lanes.count == 23)
    #expect(response.jobs.count == 17)

    let swapping = try #require(response.nodes.first { $0.machineID == "machine-c" })
    #expect(swapping.memory?.swapUsedMB == 14446.44)
    #expect(swapping.memory?.compressedMB == 10083.84375)
    #expect(swapping.load?.load1 == 6.02)
    #expect(swapping.activeJobs == 0)

    let fractionalSwap = try #require(response.nodes.first { $0.machineID == "machine-e" })
    #expect(fractionalSwap.memory?.swapUsedMB == 6.7890625)
    #expect(fractionalSwap.memory?.freePct == 70.6054523688342)

    // Null numerics inside an otherwise present object survive as nil.
    let partial = try #require(response.nodes.first { $0.machineID == "machine-f" })
    #expect(partial.load?.load1 == 0.04)
    #expect(partial.load?.load15 == nil)
    #expect(partial.load?.ncpu == nil)
    #expect(partial.memory == nil)
    #expect(partial.lastPingMS == 9327)

    #expect(response.tasks.byState.inProgress == 6)
    #expect(response.tasks.byState.verifying == 5)
    #expect(response.tasks.byState.backlog == 16)
    #expect(response.tasks.decisionsPending == 0)
    #expect(response.tasks.active.count == 12)
    #expect(response.tasks.active.first?.id == 58)
    #expect(response.consolePaths.decisions == "/ui/decisions")
}

@Test("counts survive a hub that sends them as decimals")
func decimalCountsDecodeLeniently() throws {
    var payload = try JSONSerialization.jsonObject(with: fixture("glance-real-sanitized.json")) as! [String: Any]
    var nodes = payload["nodes"] as! [[String: Any]]
    nodes[0]["active_jobs"] = 5.5
    var load = nodes[0]["load"] as! [String: Any]
    load["ncpu"] = 4.9
    nodes[0]["load"] = load
    payload["nodes"] = nodes
    var tasks = payload["tasks"] as! [String: Any]
    var byState = tasks["by_state"] as! [String: Any]
    byState["in_progress"] = 6.0
    tasks["by_state"] = byState
    tasks["decisions_pending"] = 2.7
    var active = tasks["active"] as! [[String: Any]]
    active[0]["id"] = 58.9
    tasks["active"] = active
    payload["tasks"] = tasks

    let data = try JSONSerialization.data(withJSONObject: payload)
    let response = try JSONDecoder().decode(GlanceResponse.self, from: data)
    #expect(response.nodes[0].activeJobs == 5)
    #expect(response.nodes[0].load?.ncpu == 4)
    #expect(response.tasks.byState.inProgress == 6)
    #expect(response.tasks.decisionsPending == 2)
    #expect(response.tasks.active[0].id == 58)
}

@Test("the real hub response renders, dashing the fields it omits")
func realGlanceRenderSmoke() throws {
    let response = try decodeFixture("glance-real-sanitized.json")
    var state = FleetPollState()
    state.apply(.response(response), at: Date(timeIntervalSince1970: 45_296))
    let snapshot = MenuRenderer.snapshot(
        pollState: state,
        nodeState: .running,
        launchdFailure: nil,
        timeZone: TimeZone(secondsFromGMT: 0)!
    )
    #expect(snapshot.header == "Fleet · ok 12:34:56")
    #expect(snapshot.machines.count == 6)
    #expect(snapshot.machines[0].text == "machine-a  ●  load 0.4/4  free 92%  swap 0  [accepting]")
    // 14446.44 MB of swap renders as whole megabytes rather than failing the fetch.
    #expect(snapshot.machines[2].text == "machine-c  ●  load 6.0/10  free 58%  swap 14446  [accepting]")
    #expect(snapshot.machines[4].text == "machine-e  ●  load 0.4/2  free 71%  swap 6")
    // machine-f reports no cpu count and no memory block at all: en dashes, not a crash.
    #expect(snapshot.machines[5].text == "machine-f  ●  load 0.0/–  free –  swap –")
    #expect(snapshot.machines[5].text.contains("–"))
    #expect(snapshot.lanes.count == 23)
    #expect(snapshot.lanes[0] == "lane-1 → machine-b w1:p1")
    #expect(snapshot.lanes[1] == "  lane-2 → machine-b w1:p2")
    #expect(snapshot.lanes[21] == "  lane-22 → machine-g  (sink)")
    #expect(snapshot.queueSummary == "in_progress 6 · verifying 5 · needs_decision 0")
    #expect(snapshot.activeTasks == [
        "#58 lane-1 · task 1",
        "#53 lane-1 · task 2",
        "#52 lane-1 · task 3",
        "#45 lane-1 · task 4",
        "#41 lane-1 · task 5"
    ])
    #expect(snapshot.decisions == "Decisions pending: 0")
}

@Test("polling starts with the app, before any menu is opened")
@MainActor
func startupPollingFetchesBeforeMenuOpens() async throws {
    StubURLProtocol.glanceRequests = 0
    StubURLProtocol.result = .http(200, try fixture("glance-real-sanitized.json"))
    let store = AppStore(configuration: testConfiguration(), session: stubbedSession())
    defer { store.stopPolling() }

    // Nothing here opens the menu; the fetch must come from init alone.
    let refreshed = await waitUntil { store.snapshot.machines.isEmpty == false }
    #expect(refreshed)
    #expect(StubURLProtocol.glanceRequests >= 1)
    #expect(store.snapshot.header == "Fleet · ok \(nowFormatted())")
    #expect(store.snapshot.machines.count == 6)
    #expect(store.acceptingAvailable == true)

    // Opening the menu still refreshes immediately on top of the running poll.
    let beforeOpen = StubURLProtocol.glanceRequests
    store.menuDidOpen()
    let opened = await waitUntil { StubURLProtocol.glanceRequests > beforeOpen }
    #expect(opened)
}

@Test("accepting restores the original value after 4xx, 5xx, and transport failures")
@MainActor
func acceptingFailureRollsBack() async {
    for outcome in [StubResult.http(400), .http(503), .transport] {
        StubURLProtocol.result = outcome
        let client = GlanceClient(consoleURL: URL(string: "https://console.example")!, credentials: nil, session: stubbedSession())
        let state = AcceptingState(accepting: true)
        await state.toggle(using: client, machineID: "machine-a")
        #expect(state.accepting == true)
        #expect(state.failureReason != nil)
    }
}
}

@MainActor
private func testConfiguration() -> AppConfiguration {
    AppConfiguration(
        consoleURL: URL(string: "https://console.example")!,
        credentials: nil,
        machineID: "machine-a",
        // No such launchd job exists in the test environment; inspect() reports
        // "exit 113", which the store records without touching the poll path.
        launchdLabel: "com.example.paneglance.absent",
        launchdPlist: "/nonexistent.plist",
        pollSeconds: 3_600
    )
}

@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<300 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

private func nowFormatted() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: Date())
}

private func decodeFixture(_ name: String) throws -> GlanceResponse {
    try JSONDecoder().decode(GlanceResponse.self, from: fixture(name))
}

private func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: fixtureURL(name))
}

private func fixtureText(_ name: String) throws -> String {
    try String(contentsOf: fixtureURL(name), encoding: .utf8)
}

private func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "fixtures")
        .appending(path: name)
}

private func clientResponding(status: Int, body: Data) -> GlanceClient {
    StubURLProtocol.result = .http(status, body)
    return GlanceClient(consoleURL: URL(string: "https://console.example")!, credentials: nil, session: stubbedSession())
}

private func awaitValue(_ client: GlanceClient) async -> FetchOutcome {
    await client.fetchGlance()
}

private func stubbedSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: configuration)
}

private enum StubResult {
    case http(Int, Data = Data())
    case transport
}

private final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var result: StubResult = .transport
    nonisolated(unsafe) static var glanceRequests = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if request.url?.path().hasSuffix("/ui/api/glance") == true { Self.glanceRequests += 1 }
        switch Self.result {
        case .http(let status, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .transport:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }
    }

    override func stopLoading() {}
}
