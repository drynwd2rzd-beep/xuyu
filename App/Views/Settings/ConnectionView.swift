import SwiftUI

struct ConnectionView: View {
    @Environment(RelayClient.self) private var relay
    @State private var address = ""
    @State private var away = ""
    @State private var code = ""
    @State private var testing = false
    @State private var testResult: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.section) {
                VStack(spacing: 0) {
                    field("在家", text: $address, placeholder: "192.168.1.8:51888", keyboard: .URL)
                    Hairline()
                    field("出门", text: $away, placeholder: "Tailscale 地址（可不填）", keyboard: .URL)
                    Hairline()
                    field("配对码", text: $code, placeholder: "电脑窗口里显示的 8 位", keyboard: .asciiCapable)
                }
                .card()

                Button(action: connect) {
                    Text(relay.state == .connecting ? "连接中…" : "连接")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Palette.inkInverse)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Palette.ink, in: Capsule())
                }
                .buttonStyle(ScaleButtonStyle())
                .disabled((address.trimmed.isEmpty && away.trimmed.isEmpty) || code.trimmed.isEmpty)

                HStack(spacing: Space.tight) {
                    StatusDot(ok: relay.isConnected)
                    Text(stateText).font(.system(size: 14)).foregroundStyle(Palette.ink2)
                }
                .padding(.leading, 6)
                .animation(Motion.spring, value: relay.state)

                if relay.isConnected {
                    VStack(spacing: 0) {
                        engineLine(.claude, relay.status?.claude)
                        Hairline(inset: 50)
                        engineLine(.codex, relay.status?.codex)
                    }
                    .card()
                    .transition(.opacity)

                    Button(action: test) {
                        HStack {
                            Text(testing ? "正在问 Claude…" : "发一句话试试")
                            Spacer()
                            if testing { ProgressView() }
                        }
                        .font(.system(size: 16))
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, Space.card)
                        .frame(height: Space.row)
                        .card()
                    }
                    .buttonStyle(ScaleButtonStyle())
                    .disabled(testing)
                    if let testResult {
                        Text(testResult).font(.system(size: 14)).foregroundStyle(Palette.ink2).padding(.leading, 6)
                    }
                }
            }
            .padding(.horizontal, Space.page)
            .padding(.bottom, 40)
        }
        .safeAreaInset(edge: .top, spacing: 0) { SubpageHeader(title: "连接") }
        .background(Palette.paper.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            address = relay.address
            away = relay.awayAddress
            code = relay.code
        }
    }

    private var stateText: String {
        switch relay.state {
        case .connected: "已连接到 \(relay.status?.host ?? "电脑")" + (relay.usingAway ? "（出门线路）" : "（在家线路）")
        case .connecting: "正在连接…"
        case .notConfigured: "填写电脑上显示的地址和配对码"
        case .failed(let reason): "没连上：\(reason)"
        }
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String, keyboard: UIKeyboardType) -> some View {
        HStack(spacing: Space.item) {
            Text(label).font(.system(size: 15)).foregroundStyle(Palette.inkSoft).frame(width: 56, alignment: .leading)
            TextField(placeholder, text: text)
                .font(.system(size: 16, design: .monospaced))
                .foregroundStyle(Palette.ink)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, Space.card)
        .frame(height: Space.row)
    }

    private func engineLine(_ engine: Engine, _ status: EngineStatus?) -> some View {
        HStack(spacing: Space.item) {
            EngineLogo(engine: engine, size: 18).frame(width: 26)
            Text(engine.label).font(.system(size: 16)).foregroundStyle(Palette.ink)
            Spacer()
            Text(status.map { $0.installed ? $0.version : "未安装" } ?? "–")
                .font(.system(size: 13)).foregroundStyle(Palette.inkSoft).lineLimit(1)
            StatusDot(ok: status?.installed == true)
        }
        .padding(.horizontal, Space.card)
        .frame(height: Space.row)
    }

    private func connect() {
        relay.address = address
        relay.awayAddress = away
        relay.code = code
        relay.reconnect()
    }

    private func test() {
        testing = true
        testResult = nil
        Task {
            do {
                let reply = try await relay.complete(RelayRequest(engine: "claude", model: "", system: "你是一个简短的助手。", prompt: "用一句话跟我打个招呼。"))
                testResult = "Claude：\(reply)"
            } catch {
                testResult = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            testing = false
        }
    }
}
