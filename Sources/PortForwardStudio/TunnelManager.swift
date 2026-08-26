import Darwin
import Foundation

enum TunnelPhase: Equatable {
    case disconnected
    case starting
    case connected
    case failed

    var label: String {
        switch self {
        case .disconnected: return "已关闭"
        case .starting: return "连接中"
        case .connected: return "运行中"
        case .failed: return "连接失败"
        }
    }
}

struct TunnelSnapshot: Equatable {
    var phase: TunnelPhase = .disconnected
    var uploaded: UInt64 = 0
    var downloaded: UInt64 = 0
    var startedAt: Date?
    var message: String?
    var trafficSamples: [TrafficSample] = []
}

struct TrafficSample: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let uploadedPerSecond: UInt64
    let downloadedPerSecond: UInt64
}

@MainActor
final class TunnelManager: ObservableObject {
    @Published private(set) var snapshots: [UUID: TunnelSnapshot] = [:]
    private var sessions: [UUID: TunnelSession] = [:]

    func snapshot(for id: UUID) -> TunnelSnapshot {
        snapshots[id] ?? TunnelSnapshot()
    }

    func start(_ rawProfile: TunnelProfile, hasCredential: Bool) async throws {
        let profile = try rawProfile.validated()
        guard sessions[profile.id] == nil else { return }

        snapshots[profile.id] = TunnelSnapshot(phase: .starting)
        let internalPort = try Self.availableLoopbackPort()
        let controlPath = Self.makeControlPath()
        let process = Process()
        let log = LockedLog()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = sshArguments(
            for: profile,
            internalPort: internalPort,
            controlPath: controlPath,
            hasCredential: hasCredential
        )
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        if hasCredential {
            var environment = ProcessInfo.processInfo.environment
            environment["SSH_ASKPASS"] = Bundle.main.executableURL?.path
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["DISPLAY"] = environment["DISPLAY"] ?? "port-forward-studio:0"
            environment["PORT_FORWARD_ASKPASS"] = "1"
            environment["PORT_FORWARD_PROFILE_ID"] = profile.id.uuidString
            process.environment = environment
        }

        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                log.append(text)
            }
        }

        process.terminationHandler = { [weak self] terminated in
            Task { @MainActor in
                self?.processDidExit(profileID: profile.id, process: terminated, log: log.text)
            }
        }

        let session = TunnelSession(process: process, log: log, controlPath: controlPath)
        sessions[profile.id] = session

        do {
            if profile.forwardingMode == .reverse {
                let proxy = makeProxy(
                    bindHost: "127.0.0.1",
                    bindPort: internalPort,
                    targetHost: profile.reverseTargetHost,
                    targetPort: UInt16(profile.reverseTargetPort),
                    counter: session.trafficCounter,
                    invertDirections: true
                )
                session.proxy = proxy
                try await proxy.start()
            }

            try process.run()
            var sshReady = false
            for _ in 0..<100 {
                if !process.isRunning { break }
                let ready = profile.forwardingMode == .local
                    ? Self.canConnect(toLoopbackPort: internalPort)
                    : FileManager.default.fileExists(atPath: controlPath)
                if ready {
                    sshReady = true
                    break
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }

            if profile.forwardingMode == .reverse, sshReady {
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            guard sshReady, process.isRunning else {
                throw TunnelError.sshFailed(log.cleanedText)
            }

            if profile.forwardingMode == .local {
                let proxy = makeProxy(
                    bindHost: profile.localHost,
                    bindPort: UInt16(profile.localPort),
                    targetHost: "127.0.0.1",
                    targetPort: internalPort,
                    counter: session.trafficCounter
                )
                session.proxy = proxy
                try await proxy.start()
            }

            guard sessions[profile.id] === session else {
                session.proxy?.stop()
                throw TunnelError.cancelled
            }
            snapshots[profile.id] = TunnelSnapshot(
                phase: .connected,
                startedAt: Date()
            )
            beginSampling(profileID: profile.id, session: session)
        } catch {
            if sessions.removeValue(forKey: profile.id) === session {
                errorPipe.fileHandleForReading.readabilityHandler = nil
                session.sampleTimer?.invalidate()
                session.proxy?.stop()
                if process.isRunning { process.terminate() }
                try? FileManager.default.removeItem(atPath: controlPath)
                snapshots[profile.id] = TunnelSnapshot(
                    phase: .failed,
                    message: readableMessage(for: error, log: log.cleanedText)
                )
            }
            throw error
        }
    }

    func stop(profileID: UUID) {
        guard let session = sessions.removeValue(forKey: profileID) else {
            snapshots[profileID] = TunnelSnapshot()
            return
        }
        session.process.terminationHandler = nil
        session.sampleTimer?.invalidate()
        session.proxy?.stop()
        if session.process.isRunning { session.process.terminate() }
        try? FileManager.default.removeItem(atPath: session.controlPath)
        snapshots[profileID] = TunnelSnapshot()
    }

    func stopAll() {
        Array(sessions.keys).forEach(stop(profileID:))
    }

    private func beginSampling(profileID: UUID, session: TunnelSession) {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.captureTrafficSample(profileID: profileID)
            }
        }
        session.sampleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func captureTrafficSample(profileID: UUID) {
        guard let session = sessions[profileID],
              var snapshot = snapshots[profileID],
              snapshot.phase == .connected else { return }

        let traffic = session.trafficCounter.drain()
        snapshot.uploaded += traffic.uploaded
        snapshot.downloaded += traffic.downloaded
        snapshot.trafficSamples.append(
            TrafficSample(
                timestamp: Date(),
                uploadedPerSecond: traffic.uploaded,
                downloadedPerSecond: traffic.downloaded
            )
        )
        if snapshot.trafficSamples.count > 60 {
            snapshot.trafficSamples.removeFirst(snapshot.trafficSamples.count - 60)
        }
        snapshots[profileID] = snapshot
    }

    private func processDidExit(profileID: UUID, process: Process, log: String) {
        guard let session = sessions[profileID], session.process === process else { return }
        sessions[profileID] = nil
        session.sampleTimer?.invalidate()
        session.proxy?.stop()
        try? FileManager.default.removeItem(atPath: session.controlPath)
        snapshots[profileID] = TunnelSnapshot(
            phase: .failed,
            message: log.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? "SSH 连接已意外结束（状态码 \(process.terminationStatus)）"
        )
    }

    private func makeProxy(bindHost: String, bindPort: UInt16,
                           targetHost: String, targetPort: UInt16, counter: TrafficCounter,
                           invertDirections: Bool = false) -> TrafficProxy {
        TrafficProxy(
            bindHost: bindHost,
            bindPort: bindPort,
            targetHost: targetHost,
            targetPort: targetPort
        ) { direction, count in
            let reportedDirection = invertDirections
                ? (direction == .upload ? TrafficProxy.Direction.download : .upload)
                : direction
            counter.record(direction: reportedDirection, bytes: count)
        }
    }

    func sshArguments(for profile: TunnelProfile, internalPort: UInt16,
                      controlPath: String, hasCredential: Bool) -> [String] {
        var arguments = [
            "-N", "-T",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "TCPKeepAlive=yes",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ControlMaster=yes",
            "-o", "ControlPersist=no",
            "-o", "ControlPath=\(controlPath)"
        ]

        switch profile.authenticationMode {
        case .automatic:
            arguments += ["-o", "BatchMode=yes"]
        case .password:
            arguments += [
                "-o", "BatchMode=no",
                "-o", "NumberOfPasswordPrompts=1",
                "-o", "PreferredAuthentications=keyboard-interactive,password"
            ]
        case .identityFile:
            arguments += [
                "-o", hasCredential ? "BatchMode=no" : "BatchMode=yes",
                "-o", "NumberOfPasswordPrompts=1",
                "-o", "PreferredAuthentications=publickey",
                "-o", "IdentitiesOnly=yes",
                "-i", NSString(string: profile.identityFile).expandingTildeInPath
            ]
        }

        let forwardArgument: String
        let forwardSpecification: String
        switch profile.forwardingMode {
        case .local:
            forwardArgument = "-L"
            forwardSpecification = "127.0.0.1:\(internalPort):\(bracketed(profile.remoteHost)):\(profile.remotePort)"
        case .reverse:
            forwardArgument = "-R"
            forwardSpecification = "\(bracketed(profile.reverseBindHost)):\(profile.reverseBindPort):127.0.0.1:\(internalPort)"
        }

        arguments += [
            "-p", String(profile.sshPort),
            forwardArgument, forwardSpecification,
            "-l", profile.username,
            profile.serverHost
        ]
        return arguments
    }

    private func bracketed(_ host: String) -> String {
        host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    }

    private func readableMessage(for error: Error, log: String) -> String {
        if !log.isEmpty { return log }
        if let localized = error as? LocalizedError, let message = localized.errorDescription {
            return message
        }
        return error.localizedDescription
    }

    private static func availableLoopbackPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw TunnelError.noInternalPort }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw TunnelError.noInternalPort }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard nameResult == 0 else { throw TunnelError.noInternalPort }
        return UInt16(bigEndian: address.sin_port)
    }

    static func makeControlPath(id: UUID = UUID()) -> String {
        "/tmp/pfs-\(id.uuidString)"
    }

    private static func canConnect(toLoopbackPort port: UInt16) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}

private final class TunnelSession {
    let process: Process
    let log: LockedLog
    let controlPath: String
    let trafficCounter = TrafficCounter()
    var proxy: TrafficProxy?
    var sampleTimer: Timer?

    init(process: Process, log: LockedLog, controlPath: String) {
        self.process = process
        self.log = log
        self.controlPath = controlPath
    }
}

private final class TrafficCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var uploaded: UInt64 = 0
    private var downloaded: UInt64 = 0

    func record(direction: TrafficProxy.Direction, bytes: Int) {
        guard bytes > 0 else { return }
        lock.lock()
        switch direction {
        case .upload: uploaded += UInt64(bytes)
        case .download: downloaded += UInt64(bytes)
        }
        lock.unlock()
    }

    func drain() -> (uploaded: UInt64, downloaded: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        let traffic = (uploaded, downloaded)
        uploaded = 0
        downloaded = 0
        return traffic
    }
}

private final class LockedLog {
    private let lock = NSLock()
    private var value = ""

    func append(_ text: String) {
        lock.lock()
        value += text
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    var cleanedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

enum TunnelError: LocalizedError {
    case noInternalPort
    case sshFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noInternalPort: return "无法分配内部转发端口"
        case let .sshFailed(message): return message.isEmpty ? "SSH 连接失败" : message
        case .cancelled: return "操作已取消"
        }
    }
}
