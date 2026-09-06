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

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
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
