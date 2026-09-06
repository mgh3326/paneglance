import Foundation

struct AccessCredentials: Sendable {
    let clientID: String
    let clientSecret: String
}

enum AcceptingResult: Sendable {
    case success
    case httpStatus(Int)
    case transport

    var failureReason: String? {
        switch self {
        case .success:
            return nil
        case .httpStatus(let status):
            return "Accepting failed: HTTP \(status)"
        case .transport:
            return "Accepting failed: offline"
        }
    }
}

actor GlanceClient {
    private let consoleURL: URL
    private let credentials: AccessCredentials?
    private let session: URLSession
    private var inFlight: Task<FetchOutcome, Never>?

    init(consoleURL: URL, credentials: AccessCredentials?, session: URLSession = .shared) {
        self.consoleURL = consoleURL
        self.credentials = credentials
        self.session = session
    }

    func fetchGlance() async -> FetchOutcome {
        if let inFlight {
            return await inFlight.value
        }

        let url = consoleURL.appending(path: "/ui/api/glance")
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        addCredentials(to: &request)
        let task = Task { [session] in
            await Self.performGlance(request, session: session)
        }
        inFlight = task
        let outcome = await task.value
        inFlight = nil
        return outcome
    }

    func setAccepting(machineID: String, accepting: Bool) async -> AcceptingResult {
        let url = consoleURL
            .appending(path: "/ui/api/nodes")
            .appending(path: machineID)
            .appending(path: "accepting")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addCredentials(to: &request)
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "accepting": accepting,
            "reason": "paneglance"
        ])

        do {
            let (_, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { return .transport }
            return (200..<300).contains(response.statusCode) ? .success : .httpStatus(response.statusCode)
        } catch {
            return .transport
        }
    }

    private func addCredentials(to request: inout URLRequest) {
        guard let credentials else { return }
        request.setValue(credentials.clientID, forHTTPHeaderField: "CF-Access-Client-Id")
        request.setValue(credentials.clientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
    }

    private static func performGlance(_ request: URLRequest, session: URLSession) async -> FetchOutcome {
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { return .transport }
            guard response.statusCode == 200 else { return .httpStatus(response.statusCode) }
            do {
                return .response(try JSONDecoder().decode(GlanceResponse.self, from: data))
            } catch {
                return .transport
            }
        } catch {
            return .transport
        }
    }
}
