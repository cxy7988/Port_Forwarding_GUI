import Foundation

@MainActor
final class AppStore: ObservableObject {
    @Published var profiles: [TunnelProfile] = [] {
        didSet { persistProfiles() }
    }
    @Published var alertMessage: String?

    let tunnels = TunnelManager()
    private let profilesURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PortForwardStudio", isDirectory: true)
        profilesURL = base.appendingPathComponent("profiles.json")
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: profilesURL.path) {
                let data = try Data(contentsOf: profilesURL)
                var loaded = try JSONDecoder().decode([TunnelProfile].self, from: data)
                for index in loaded.indices where loaded[index].authenticationMode == .automatic {
                    if KeychainStore.load(for: loaded[index].id) != nil {
                        loaded[index].authenticationMode = .password
                    }
                }
                profiles = loaded
            }
        } catch {
            alertMessage = "无法读取配置：\(error.localizedDescription)"
        }
    }

    @discardableResult
    func addProfile() -> UUID {
        var profile = TunnelProfile()
        let usedPorts = Set(profiles.map(\.localPort))
        while usedPorts.contains(profile.localPort), profile.localPort < 65535 {
            profile.localPort += 1
        }
        profiles.append(profile)
        return profile.id
    }

    func save(_ profile: TunnelProfile, credential: String) -> Bool {
        do {
            _ = try profile.validated()
            if profile.authenticationMode == .password && credential.isEmpty {
                throw CredentialError.missingPassword
            }
            if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
                profiles[index] = profile
            } else {
                profiles.append(profile)
            }
            if profile.authenticationMode == .automatic {
                KeychainStore.delete(for: profile.id)
            } else if profile.rememberPassword {
                if credential.isEmpty { KeychainStore.delete(for: profile.id) }
                else { try KeychainStore.save(credential, for: profile.id) }
            } else {
                KeychainStore.delete(for: profile.id)
            }
            return true
        } catch {
            alertMessage = error.localizedDescription
            return false
        }
    }

    func start(_ profile: TunnelProfile, credential: String) {
        guard save(profile, credential: credential) else { return }
        Task {
            let hasCredential = profile.authenticationMode != .automatic && !credential.isEmpty
            do {
                if hasCredential && !profile.rememberPassword {
                    try KeychainStore.save(credential, for: profile.id)
                }
                defer {
                    if !profile.rememberPassword { KeychainStore.delete(for: profile.id) }
                }
                try await tunnels.start(profile, hasCredential: hasCredential)
            } catch {
                if tunnels.snapshot(for: profile.id).message == nil {
                    alertMessage = error.localizedDescription
                }
            }
        }
    }

    func stop(profileID: UUID) {
        tunnels.stop(profileID: profileID)
    }

    func remove(profileID: UUID) {
        tunnels.stop(profileID: profileID)
        KeychainStore.delete(for: profileID)
        profiles.removeAll { $0.id == profileID }
    }

    func credential(for profileID: UUID) -> String {
        KeychainStore.load(for: profileID) ?? ""
    }

    private func persistProfiles() {
        do {
            let data = try JSONEncoder.pretty.encode(profiles)
            try data.write(to: profilesURL, options: .atomic)
        } catch {
            alertMessage = "无法保存配置：\(error.localizedDescription)"
        }
    }
}

private enum CredentialError: LocalizedError {
    case missingPassword

    var errorDescription: String? { "请输入 SSH 登录密码" }
}

private extension JSONEncoder {
    static let pretty: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}
