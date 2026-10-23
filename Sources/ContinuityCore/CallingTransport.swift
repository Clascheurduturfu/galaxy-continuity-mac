import Foundation
import Network

/// Samsung Phone's local WebSocket adapter ultimately opens this TLS connection.
/// Certificate validation remains with the system; no insecure fallback is used.
@MainActor enum CallingTransport {
    static func probe(servers: [String], status: (String) -> Void) async throws -> String {
        guard !servers.isEmpty, servers.count <= 16 else { throw ContinuityError.message("Samsung returned no supported calling servers.") }
        var failures: [String] = []
        for (index, address) in servers.prefix(3).enumerated() {
            guard let endpoint = URLComponents(string: "tls://" + address), let host = endpoint.host,
                  let rawPort = endpoint.port, let port = UInt16(exactly: rawPort), port > 0,
                  endpoint.user == nil, endpoint.password == nil, endpoint.path.isEmpty,
                  endpoint.query == nil, endpoint.fragment == nil else {
                throw ContinuityError.message("Samsung returned an invalid SIP server endpoint.")
            }
            status("Checking secure calling transport \(index + 1)…")
            let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
            let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!,
                                          using: NWParameters(tls: NWProtocolTLS.Options(), tcp: tcp))
            let timeout = Task { try? await Task.sleep(nanoseconds: 10_000_000_000); if !Task.isCancelled { connection.cancel() } }
            defer { timeout.cancel(); connection.stateUpdateHandler = nil; connection.cancel() }
            do {
                try await withCheckedThrowingContinuation { (pending: CheckedContinuation<Void, Error>) in
                    var finished = false
                    connection.stateUpdateHandler = { state in Task { @MainActor in
                        guard !finished else { return }
                        switch state {
                        case .ready: finished = true; pending.resume()
                        case .failed(let error): finished = true; pending.resume(throwing: error)
                        case .cancelled: finished = true; pending.resume(throwing: ContinuityError.message("Calling transport timed out."))
                        default: break
                        }
                    } }
                    connection.start(queue: .main)
                }
                return "Samsung calling server \(index + 1) accepted a system-verified TLS connection. No calling device was registered and no call was placed."
            } catch let error as NWError {
                switch error {
                case .tls(let code): failures.append("server \(index + 1): TLS \(code)")
                case .posix(let code): failures.append("server \(index + 1): network \(code.rawValue)")
                default: failures.append("server \(index + 1): connection failed")
                }
            } catch { failures.append("server \(index + 1): timeout or cancellation") }
        }
        throw ContinuityError.message("Calling transport is not ready (\(failures.joined(separator: "; "))).")
    }
}
