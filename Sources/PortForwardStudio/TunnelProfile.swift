import Foundation

enum ForwardingMode: String, Codable, CaseIterable {
    case local
    case reverse
}

enum AuthenticationMode: String, Codable, CaseIterable {
    case automatic
    case password
    case identityFile
}

struct TunnelProfile: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var name = "新建转发"
    var serverHost = ""
    var sshPort = 22
    var username = ""
    var authenticationMode = AuthenticationMode.automatic
    var identityFile = ""
    var forwardingMode = ForwardingMode.local
    var localHost = "127.0.0.1"
    var localPort = 8080
    var remoteHost = "127.0.0.1"
    var remotePort = 80
    var reverseBindHost = "127.0.0.1"
    var reverseBindPort = 8080
    var reverseTargetHost = "127.0.0.1"
    var reverseTargetPort = 80
    var rememberPassword = true

    init() {}

    private enum CodingKeys: String, CodingKey {
        case id, name, serverHost, sshPort, username, authenticationMode, identityFile
        case forwardingMode, localHost, localPort, remoteHost, remotePort
        case reverseBindHost, reverseBindPort, reverseTargetHost, reverseTargetPort
        case rememberPassword
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "新建转发"
        serverHost = try values.decodeIfPresent(String.self, forKey: .serverHost) ?? ""
        sshPort = try values.decodeIfPresent(Int.self, forKey: .sshPort) ?? 22
        username = try values.decodeIfPresent(String.self, forKey: .username) ?? ""
        authenticationMode = try values.decodeIfPresent(AuthenticationMode.self, forKey: .authenticationMode) ?? .automatic
        identityFile = try values.decodeIfPresent(String.self, forKey: .identityFile) ?? ""
        forwardingMode = try values.decodeIfPresent(ForwardingMode.self, forKey: .forwardingMode) ?? .local
        localHost = try values.decodeIfPresent(String.self, forKey: .localHost) ?? "127.0.0.1"
        localPort = try values.decodeIfPresent(Int.self, forKey: .localPort) ?? 8080
        remoteHost = try values.decodeIfPresent(String.self, forKey: .remoteHost) ?? "127.0.0.1"
        remotePort = try values.decodeIfPresent(Int.self, forKey: .remotePort) ?? 80
        reverseBindHost = try values.decodeIfPresent(String.self, forKey: .reverseBindHost) ?? "127.0.0.1"
        reverseBindPort = try values.decodeIfPresent(Int.self, forKey: .reverseBindPort) ?? 8080
        reverseTargetHost = try values.decodeIfPresent(String.self, forKey: .reverseTargetHost) ?? "127.0.0.1"
        reverseTargetPort = try values.decodeIfPresent(Int.self, forKey: .reverseTargetPort) ?? 80
        rememberPassword = try values.decodeIfPresent(Bool.self, forKey: .rememberPassword) ?? true
    }

    func validated() throws -> TunnelProfile {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProfileError.missingName
        }
        guard !serverHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProfileError.missingServer
        }
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProfileError.missingUsername
        }
        guard (1...65535).contains(sshPort) else {
            throw ProfileError.invalidPort
        }

        if authenticationMode == .identityFile {
            guard !identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProfileError.missingIdentityFile
            }
            guard FileManager.default.isReadableFile(atPath: NSString(string: identityFile).expandingTildeInPath) else {
                throw ProfileError.unreadableIdentityFile
            }
        }

        switch forwardingMode {
        case .local:
            guard !remoteHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProfileError.missingRemoteHost
            }
            guard (1...65535).contains(localPort), (1...65535).contains(remotePort) else {
                throw ProfileError.invalidPort
            }
            guard Self.isListenAddress(localHost) else { throw ProfileError.invalidLocalHost }
        case .reverse:
            guard !reverseTargetHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProfileError.missingReverseTargetHost
            }
            guard (1...65535).contains(reverseBindPort), (1...65535).contains(reverseTargetPort) else {
                throw ProfileError.invalidPort
            }
            guard Self.isListenAddress(reverseBindHost) else { throw ProfileError.invalidReverseBindHost }
        }
        return self
    }

    private static func isListenAddress(_ address: String) -> Bool {
        address == "127.0.0.1" || address == "0.0.0.0" || address == "::1"
    }
}

enum ProfileError: LocalizedError {
    case missingName
    case missingServer
    case missingUsername
    case missingRemoteHost
    case invalidPort
    case invalidLocalHost
    case missingIdentityFile
    case unreadableIdentityFile
    case missingReverseTargetHost
    case invalidReverseBindHost

    var errorDescription: String? {
        switch self {
        case .missingName: return "请输入配置名称"
        case .missingServer: return "请输入 SSH 服务器地址"
        case .missingUsername: return "请输入 SSH 用户名"
        case .missingRemoteHost: return "请输入目标地址"
        case .invalidPort: return "端口必须在 1 到 65535 之间"
        case .invalidLocalHost: return "本地监听地址仅支持 127.0.0.1、::1 或 0.0.0.0"
        case .missingIdentityFile: return "请选择 SSH 私钥文件"
        case .unreadableIdentityFile: return "SSH 私钥文件不存在或无法读取"
        case .missingReverseTargetHost: return "请输入 Mac 端目标地址"
        case .invalidReverseBindHost: return "服务器监听地址仅支持 127.0.0.1、::1 或 0.0.0.0"
        }
    }
}

enum ByteCountFormatter {
    static func string(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatterFoundation.shared
        return formatter.string(fromByteCount: Int64(clamping: bytes))
    }
}

private enum ByteCountFormatterFoundation {
    static let shared: Foundation.ByteCountFormatter = {
        let formatter = Foundation.ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()
}
