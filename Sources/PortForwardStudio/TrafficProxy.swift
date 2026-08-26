import Foundation
import Network

final class TrafficProxy: @unchecked Sendable {
    enum Direction: Equatable { case upload, download }

    private let bindHost: String
    private let bindPort: UInt16
    private let targetHost: String
    private let targetPort: UInt16
    private let queue: DispatchQueue
    private let onBytes: (Direction, Int) -> Void
    private var listener: NWListener?
    private var pairs: [UUID: ProxyPair] = [:]

    init(bindHost: String, bindPort: UInt16, targetHost: String = "127.0.0.1", targetPort: UInt16,
         onBytes: @escaping (Direction, Int) -> Void) {
        self.bindHost = bindHost
        self.bindPort = bindPort
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.onBytes = onBytes
        self.queue = DispatchQueue(label: "PortForwardStudio.proxy.\(bindPort)")
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(
                        host: NWEndpoint.Host(self.bindHost),
                        port: NWEndpoint.Port(rawValue: self.bindPort)!
                    )
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    var resumed = false

                    listener.stateUpdateHandler = { [weak self] state in
                        switch state {
                        case .ready:
                            if !resumed {
                                resumed = true
                                continuation.resume()
                            }
                        case let .failed(error):
                            if !resumed {
                                resumed = true
                                continuation.resume(throwing: error)
                            }
                            self?.stop()
                        default:
                            break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] client in
                        self?.accept(client)
                    }
                    listener.start(queue: self.queue)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            self.pairs.values.forEach { $0.stop() }
            self.pairs.removeAll()
        }
    }

    private func accept(_ client: NWConnection) {
        let id = UUID()
        let upstream = NWConnection(
            host: NWEndpoint.Host(targetHost),
            port: NWEndpoint.Port(rawValue: targetPort)!,
            using: .tcp
        )
        let pair = ProxyPair(
            client: client,
            upstream: upstream,
            queue: queue,
            onBytes: onBytes,
            onClose: { [weak self] in self?.pairs[id] = nil }
        )
        pairs[id] = pair
        pair.start()
    }
}

private final class ProxyPair {
    private let client: NWConnection
    private let upstream: NWConnection
    private let queue: DispatchQueue
    private let onBytes: (TrafficProxy.Direction, Int) -> Void
    private let onClose: () -> Void
    private var stopped = false

    init(client: NWConnection, upstream: NWConnection, queue: DispatchQueue,
         onBytes: @escaping (TrafficProxy.Direction, Int) -> Void,
         onClose: @escaping () -> Void) {
        self.client = client
        self.upstream = upstream
        self.queue = queue
        self.onBytes = onBytes
        self.onClose = onClose
    }

    func start() {
        client.stateUpdateHandler = { [weak self] state in self?.handle(state) }
        upstream.stateUpdateHandler = { [weak self] state in self?.handle(state) }
        client.start(queue: queue)
        upstream.start(queue: queue)
        pump(from: client, to: upstream, direction: .upload)
        pump(from: upstream, to: client, direction: .download)
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        client.cancel()
        upstream.cancel()
        onClose()
    }

    private func handle(_ state: NWConnection.State) {
        if case .failed = state { stop() }
    }

    private func pump(from source: NWConnection, to destination: NWConnection,
                      direction: TrafficProxy.Direction) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self, !self.stopped else { return }
            if let data, !data.isEmpty {
                self.onBytes(direction, data.count)
                destination.send(content: data, completion: .contentProcessed { [weak self] sendError in
                    guard let self else { return }
                    if sendError == nil {
                        self.pump(from: source, to: destination, direction: direction)
                    } else {
                        self.stop()
                    }
                })
            } else if complete || error != nil {
                self.stop()
            } else {
                self.pump(from: source, to: destination, direction: direction)
            }
        }
    }
}
