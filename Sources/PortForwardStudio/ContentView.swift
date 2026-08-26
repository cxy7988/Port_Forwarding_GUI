import AppKit
import Charts
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var tunnels: TunnelManager
    @State private var selection: UUID?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 250, ideal: 280, max: 340)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    selection = store.addProfile()
                } label: {
                    Label("新增转发", systemImage: "plus")
                }
                Button(role: .destructive) {
                    if let selection {
                        store.remove(profileID: selection)
                        self.selection = store.profiles.first?.id
                    }
                } label: {
                    Label("删除转发", systemImage: "trash")
                }
                .disabled(selection == nil)
            }
        }
        .alert("Port Forward Studio", isPresented: alertBinding) {
            Button("好", role: .cancel) { store.alertMessage = nil }
        } message: {
            Text(store.alertMessage ?? "")
        }
        .onAppear {
            if selection == nil { selection = store.profiles.first?.id }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("端口转发")
                        .font(.title2.bold())
                    Text("安全连接，一目了然")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            if store.profiles.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("还没有转发")
                        .font(.headline)
                    Text("点击工具栏中的 + 创建第一条 SSH 隧道")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else {
                List(store.profiles, selection: $selection) { profile in
                    TunnelRow(profile: profile, snapshot: tunnels.snapshot(for: profile.id)) {
                        toggle(profile)
                    }
                    .tag(profile.id)
                    .contextMenu {
                        Button("删除", role: .destructive) {
                            store.remove(profileID: profile.id)
                            if selection == profile.id { selection = store.profiles.first?.id }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selection,
           let profile = store.profiles.first(where: { $0.id == id }) {
            ProfileEditor(profile: profile)
                .id(id)
        } else {
            WelcomeView {
                selection = store.addProfile()
            }
        }
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { store.alertMessage != nil },
            set: { if !$0 { store.alertMessage = nil } }
        )
    }

    private func toggle(_ profile: TunnelProfile) {
        let snapshot = tunnels.snapshot(for: profile.id)
        if snapshot.phase == .connected || snapshot.phase == .starting {
            store.stop(profileID: profile.id)
        } else {
            store.start(profile, credential: store.credential(for: profile.id))
        }
    }
}

private struct TunnelRow: View {
    let profile: TunnelProfile
    let snapshot: TunnelSnapshot
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(statusColor.opacity(0.14))
                    .frame(width: 38, height: 38)
                Image(systemName: "arrow.left.arrow.right")
                    .foregroundStyle(statusColor)
                    .font(.system(size: 15, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(profile.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                }
                Text(routeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if snapshot.phase == .connected {
                    Text("↑ \(ByteCountFormatter.string(snapshot.uploaded))   ↓ \(ByteCountFormatter.string(snapshot.downloaded))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            Button(action: onToggle) {
                Image(systemName: isActive ? "stop.fill" : "play.fill")
                    .font(.caption)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .disabled(snapshot.phase == .starting)
            .help(isActive ? "关闭转发" : "启动转发")
        }
        .padding(.vertical, 5)
    }

    private var isActive: Bool {
        snapshot.phase == .connected || snapshot.phase == .starting
    }

    private var statusColor: Color {
        switch snapshot.phase {
        case .connected: return .green
        case .starting: return .orange
        case .failed: return .red
        case .disconnected: return .secondary
        }
    }

    private var routeDescription: String {
        switch profile.forwardingMode {
        case .local:
            return "Mac \(profile.localHost):\(profile.localPort) → \(profile.remoteHost):\(profile.remotePort)"
        case .reverse:
            return "服务器 \(profile.reverseBindHost):\(profile.reverseBindPort) → Mac \(profile.reverseTargetHost):\(profile.reverseTargetPort)"
        }
    }
}

private struct ProfileEditor: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var tunnels: TunnelManager
    @State private var draft: TunnelProfile
    @State private var credential: String

    init(profile: TunnelProfile) {
        _draft = State(initialValue: profile)
        _credential = State(initialValue: KeychainStore.load(for: profile.id) ?? "")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if let message = snapshot.message, snapshot.phase == .failed {
                    errorCard(message)
                }
                connectionCard
                forwardingCard
                trafficCard
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: draft.authenticationMode) { _ in
            credential = ""
        }
    }

    private var snapshot: TunnelSnapshot { tunnels.snapshot(for: draft.id) }
    private var isActive: Bool { snapshot.phase == .connected || snapshot.phase == .starting }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                TextField("配置名称", text: $draft.name)
                    .textFieldStyle(.plain)
                    .font(.largeTitle.bold())
                    .disabled(isActive)
                Label(snapshot.phase.label, systemImage: statusIcon)
                    .font(.subheadline)
                    .foregroundStyle(statusColor)
            }
            Spacer()
            Button("保存") { _ = store.save(draft, credential: credential) }
                .disabled(isActive)
            Button {
                if isActive { store.stop(profileID: draft.id) }
                else { store.start(draft, credential: credential) }
            } label: {
                Label(isActive ? "关闭转发" : "启动转发",
                      systemImage: isActive ? "stop.fill" : "play.fill")
                    .frame(minWidth: 88)
            }
            .buttonStyle(.borderedProminent)
            .tint(isActive ? .red : .accentColor)
            .disabled(snapshot.phase == .starting)
        }
    }

    private var connectionCard: some View {
        SettingsCard(title: "SSH 服务器", icon: "server.rack") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                formRow("服务器地址") {
                    TextField("ssh.example.com", text: $draft.serverHost)
                }
                formRow("SSH 端口") {
                    TextField("22", value: $draft.sshPort, format: .number)
                        .frame(maxWidth: 150)
                }
                formRow("用户名") {
                    TextField("username", text: $draft.username)
                }
                formRow("认证方式") {
                    Picker("", selection: $draft.authenticationMode) {
                        Text("自动").tag(AuthenticationMode.automatic)
                        Text("密码").tag(AuthenticationMode.password)
                        Text("指定私钥").tag(AuthenticationMode.identityFile)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 390)
                }
                authenticationFields
                if draft.authenticationMode != .automatic {
                    formRow("") {
                        Toggle(rememberCredentialLabel, isOn: $draft.rememberPassword)
                            .toggleStyle(.checkbox)
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
            .disabled(isActive)
        }
    }

    private var forwardingCard: some View {
        SettingsCard(title: "转发规则", icon: "point.3.connected.trianglepath.dotted") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                formRow("转发方向") {
                    Picker("", selection: $draft.forwardingMode) {
                        Text("本地转发 · -L").tag(ForwardingMode.local)
                        Text("反向转发 · -R").tag(ForwardingMode.reverse)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 390)
                }
                forwardingFields
            }
            .textFieldStyle(.roundedBorder)
            .disabled(isActive)

            if exposesAllInterfaces {
                Label(exposureWarning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, 10)
            }
        }
    }

    @ViewBuilder
    private var authenticationFields: some View {
        switch draft.authenticationMode {
        case .automatic:
            formRow("") {
                Text("使用 ssh-agent、~/.ssh/config 和默认私钥；不显示交互提示。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .password:
            formRow("登录密码") {
                SecureField("SSH 登录密码", text: $credential)
            }
        case .identityFile:
            formRow("私钥文件") {
                HStack {
                    TextField("~/.ssh/id_ed25519", text: $draft.identityFile)
                    Button("选择…", action: chooseIdentityFile)
                }
            }
            formRow("密钥口令") {
                SecureField("私钥未加密时留空", text: $credential)
            }
        }
    }

    @ViewBuilder
    private var forwardingFields: some View {
        switch draft.forwardingMode {
        case .local:
            formRow("Mac 监听") {
                listenAddressPicker(selection: $draft.localHost)
            }
            formRow("Mac 端口") {
                portField($draft.localPort, placeholder: "8080")
            }
            formRow("服务器侧目标") {
                TextField("目标主机（从 SSH 服务器访问）", text: $draft.remoteHost)
            }
            formRow("目标端口") {
                portField($draft.remotePort, placeholder: "80")
            }
        case .reverse:
            formRow("服务器监听") {
                listenAddressPicker(selection: $draft.reverseBindHost)
            }
            formRow("服务器端口") {
                portField($draft.reverseBindPort, placeholder: "8080")
            }
            formRow("Mac 侧目标") {
                TextField("目标主机（从这台 Mac 访问）", text: $draft.reverseTargetHost)
            }
            formRow("目标端口") {
                portField($draft.reverseTargetPort, placeholder: "80")
            }
        }
    }

    private func listenAddressPicker(selection: Binding<String>) -> some View {
        Picker("", selection: selection) {
            Text("仅本机 · 127.0.0.1").tag("127.0.0.1")
            Text("仅本机 IPv6 · ::1").tag("::1")
            Text("所有网络接口 · 0.0.0.0").tag("0.0.0.0")
        }
        .labelsHidden()
    }

    private func portField(_ value: Binding<Int>, placeholder: String) -> some View {
        TextField(placeholder, value: value, format: .number)
            .frame(maxWidth: 150)
    }

    private func chooseIdentityFile() {
        let panel = NSOpenPanel()
        panel.title = "选择 SSH 私钥"
        panel.prompt = "选择"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        if panel.runModal() == .OK, let url = panel.url {
            draft.identityFile = url.path
        }
    }

    private var rememberCredentialLabel: String {
        draft.authenticationMode == .password
            ? "在 macOS 钥匙串中记住密码"
            : "在 macOS 钥匙串中记住密钥口令"
    }

    private var exposesAllInterfaces: Bool {
        draft.forwardingMode == .local
            ? draft.localHost == "0.0.0.0"
            : draft.reverseBindHost == "0.0.0.0"
    }

    private var exposureWarning: String {
        if draft.forwardingMode == .local {
            return "此设置会允许局域网内其他设备访问该转发端口。"
        }
        return "远端 SSH 服务必须启用 GatewayPorts，服务器防火墙也必须允许该端口。"
    }

    private var trafficCard: some View {
        SettingsCard(title: "实时流量", icon: "chart.xyaxis.line") {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    MetricTile(title: "已上传", value: ByteCountFormatter.string(snapshot.uploaded),
                               icon: "arrow.up", color: .blue)
                    MetricTile(title: "已下载", value: ByteCountFormatter.string(snapshot.downloaded),
                               icon: "arrow.down", color: .purple)
                    MetricTile(title: "总流量",
                               value: ByteCountFormatter.string(snapshot.uploaded + snapshot.downloaded),
                               icon: "sum", color: .green)
                }

                Divider()

                HStack {
                    Text("最近 60 秒")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Label("每秒数据量", systemImage: "waveform.path.ecg")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if snapshot.trafficSamples.isEmpty {
                    Text(isActive ? "正在收集流量数据…" : "启动转发后显示实时流量趋势")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 210)
                        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
                } else {
                    trafficChart
                        .frame(height: 220)
                }
            }
        }
    }

    private var trafficChart: some View {
        Chart {
            ForEach(snapshot.trafficSamples) { sample in
                LineMark(
                    x: .value("时间", sample.timestamp),
                    y: .value("数据量", Double(sample.uploadedPerSecond)),
                    series: .value("方向", "上传")
                )
                .foregroundStyle(by: .value("方向", "上传"))
                .lineStyle(StrokeStyle(lineWidth: 2))

                LineMark(
                    x: .value("时间", sample.timestamp),
                    y: .value("数据量", Double(sample.downloadedPerSecond)),
                    series: .value("方向", "下载")
                )
                .foregroundStyle(by: .value("方向", "下载"))
                .lineStyle(StrokeStyle(lineWidth: 2))
            }
        }
        .chartForegroundStyleScale(["上传": Color.blue, "下载": Color.purple])
        .chartXScale(domain: chartTimeRange)
        .chartYScale(domain: 0...chartMaximum)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { value in
                AxisGridLine().foregroundStyle(.separator.opacity(0.25))
                AxisTick().foregroundStyle(.secondary)
                AxisValueLabel(format: .dateTime.minute().second())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                AxisGridLine().foregroundStyle(.separator.opacity(0.25))
                AxisValueLabel {
                    if let bytes = value.as(Double.self) {
                        Text(ByteCountFormatter.string(UInt64(max(0, bytes))) + "/s")
                    }
                }
            }
        }
        .chartLegend(position: .top, alignment: .trailing, spacing: 12)
    }

    private var chartTimeRange: ClosedRange<Date> {
        let end = snapshot.trafficSamples.last?.timestamp ?? Date()
        return end.addingTimeInterval(-60)...end
    }

    private var chartMaximum: Double {
        let peak = snapshot.trafficSamples.reduce(UInt64(0)) { current, sample in
            max(current, max(sample.uploadedPerSecond, sample.downloadedPerSecond))
        }
        return max(1024, Double(peak) * 1.15)
    }

    private func formRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .trailing)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func errorCard(_ message: String) -> some View {
        Label {
            Text(message).textSelection(.enabled)
        } icon: {
            Image(systemName: "exclamationmark.circle.fill")
        }
        .foregroundStyle(.red)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var statusIcon: String {
        switch snapshot.phase {
        case .disconnected: return "circle"
        case .starting: return "clock.arrow.circlepath"
        case .connected: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch snapshot.phase {
        case .disconnected: return .secondary
        case .starting: return .orange
        case .connected: return .green
        case .failed: return .red
        }
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: icon)
                .font(.headline)
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.separator.opacity(0.35), lineWidth: 1)
        }
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 30, height: 30)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.title3.monospacedDigit().bold())
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct WelcomeView: View {
    let create: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "network")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.tint)
            Text("Port Forward Studio")
                .font(.largeTitle.bold())
            Text("通过 SSH 安全访问远程服务，并实时掌握每条隧道的流量。")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("创建第一条转发", action: create)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
