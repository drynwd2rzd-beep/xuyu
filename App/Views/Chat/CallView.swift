import SwiftUI
import Translation

/// 通话页：深色、头像在中间，光晕跟着谁在说话变；字幕下面是韩语。通话本身在 Services/Voice/CallSession.swift
struct CallView: View {
    @State var session: CallSession
    @Environment(\.dismiss) private var dismiss
    @State private var korean = true
    @State private var failure: String?
    @State private var translation: TranslationSession.Configuration?
    @State private var tick = Date.now

    private let night = Color(hex: 0x121212)
    private let glow = Color(hex: 0xD97757)
    private let light = Color(hex: 0xF4F3EF)

    var body: some View {
        ZStack {
            night.ignoresSafeArea()
            RadialGradient(colors: [glow.opacity(glowStrength), glow.opacity(glowStrength * 0.35), .clear],
                           center: UnitPoint(x: 0.5, y: 0.34), startRadius: 10, endRadius: 360)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.8), value: session.phase)
            LinearGradient(colors: [.black.opacity(0.38), .clear], startPoint: .bottom, endPoint: .center).ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                title
                    .padding(.top, 8)

                Button { session.interrupt() } label: { orb }
                    .buttonStyle(.plain)
                    .accessibilityLabel(session.phase == .listening ? Text("TA 在听") : Text("打断 TA"))
                    .padding(.top, 36)

                captions
                    .padding(.horizontal, 34)
                    .padding(.top, 32)

                Spacer()

                controls
                    .padding(.bottom, 30)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            if let error = await session.begin() { failure = error }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                tick = .now
            }
        }
        // 韩语字幕：iPhone 自带的翻译（不花钱）。有新的一句没翻就翻
        .onChange(of: session.lines.map(\.zh)) { _, _ in
            if translation == nil {
                translation = TranslationSession.Configuration(source: Locale.Language(identifier: "zh-Hans"), target: Locale.Language(identifier: "ko"))
            } else {
                translation?.invalidate()
            }
        }
        .translationTask(translation) { t in
            for line in session.lines where line.ko.isEmpty {
                if let r = try? await t.translate(line.zh) { session.translated(line.id, r.targetText) }
            }
        }
        .alert(failure ?? "", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil; dismiss() } })) {
            Button("好", role: .cancel) {}
        }
        .onDisappear { session.end() }
    }

    // MARK: - 页头

    private var topBar: some View {
        HStack {
            Button { minimize() } label: {
                Image(systemName: "chevron.down").font(.system(size: 17, weight: .semibold)).foregroundStyle(light.opacity(0.8))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("收起通话")
            Spacer()
            Button { withAnimation(Motion.snappy) { korean.toggle() } } label: {
                Text("한").font(.system(size: 14, weight: .medium))
                    .foregroundStyle(korean ? night : light)
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(korean ? light : light.opacity(0.12), in: Capsule())
            }
            .accessibilityLabel(korean ? Text("韩语字幕（开）") : Text("韩语字幕（关）"))
        }
        .padding(.horizontal, Space.tight)
    }

    private var title: some View {
        VStack(spacing: 4) {
            Text(session.persona.name).font(Typo.display(32)).tracking(-0.4).foregroundStyle(light)
            Text("\(status) · \(CallLogs.clock(tick.timeIntervalSince(session.started)))")
                .font(Typo.serif(14.5).italic()).foregroundStyle(light.opacity(0.55))
                .contentTransition(.opacity)
        }
    }

    private var status: String {
        switch session.phase {
        case .listening: session.muted ? "muted" : "listening"
        case .thinking: "thinking"
        case .speaking: "speaking"
        }
    }

    // MARK: - 头像和字幕

    private var glowStrength: Double {
        switch session.phase {
        case .speaking: 0.30
        case .listening: 0.18
        case .thinking: 0.10
        }
    }

    private var orb: some View {
        let speaking = session.phase == .speaking
        return ZStack {
            if speaking {
                Circle().fill(glow.opacity(0.06)).frame(width: 232, height: 232)
                Circle().fill(glow.opacity(0.09)).frame(width: 194, height: 194)
            } else if session.phase == .listening {
                Circle().strokeBorder(light.opacity(0.16), lineWidth: 1).frame(width: 178, height: 178)
            }
            AvatarView(persona: session.persona, size: speaking ? 156 : session.phase == .thinking ? 140 : 150)
                .overlay {
                    Circle().fill(RadialGradient(colors: [.white.opacity(0.16), .clear], center: UnitPoint(x: 0.32, y: 0.24), startRadius: 0, endRadius: 60))
                }
                .shadow(color: .black.opacity(0.5), radius: 30, y: 24)
                .shadow(color: glow.opacity(speaking ? 0.3 : 0.12), radius: 40)
                .opacity(session.phase == .thinking ? 0.8 : 1)
        }
        .frame(height: 240)
        .animation(.spring(duration: 0.6, bounce: 0.1), value: session.phase)
    }

    @ViewBuilder
    private var captions: some View {
        let lines = session.lines.suffix(2)
        VStack(spacing: 20) {
            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                let current = index == lines.count - 1 && session.live.isEmpty
                VStack(spacing: 5) {
                    Text(line.mine ? "you" : session.persona.name)
                        .font(Typo.serif(12.5).italic()).foregroundStyle(light.opacity(current ? 0.5 : 0.3))
                    if current && !line.mine && session.phase == .speaking {
                        karaoke(line.zh)
                    } else {
                        Text(line.zh)
                            .font(Typo.serif(current ? 22 : 15.5))
                            .foregroundStyle(light.opacity(current ? 1 : 0.34))
                    }
                    if korean, !line.ko.isEmpty {
                        Text(line.ko).font(.system(size: current ? 14.5 : 12.5, weight: .light)).foregroundStyle(light.opacity(current ? 0.6 : 0.26))
                    }
                }
                .multilineTextAlignment(.center)
                .transition(.opacity.combined(with: .offset(y: 10)))
            }
            if !session.live.isEmpty {
                VStack(spacing: 5) {
                    Text("you").font(Typo.serif(12.5).italic()).foregroundStyle(light.opacity(0.5))
                    Text(session.live).font(Typo.serif(22)).foregroundStyle(light).multilineTextAlignment(.center)
                }
                .transition(.opacity)
            }
        }
        .animation(Motion.spring, value: session.lines.count)
    }

    /// TA 正在念的那句：念到的字亮，没念到的暗
    private func karaoke(_ text: String) -> some View {
        let count = Int((Double(text.count) * session.spoken).rounded())
        let said = String(text.prefix(count)), rest = String(text.dropFirst(count))
        return (Text(said).foregroundStyle(light) + Text(rest).foregroundStyle(light.opacity(0.38)))
            .font(Typo.serif(22))
    }

    // MARK: - 按钮

    private var controls: some View {
        HStack(spacing: 38) {
            control(session.speaker ? "speaker.wave.2.fill" : "speaker.fill", "speaker", on: session.speaker) { session.toggleSpeaker() }
            control(session.muted ? "mic.slash.fill" : "mic.fill", "mute", on: session.muted) { session.toggleMute() }
            VStack(spacing: 8) {
                Button { hangUp() } label: {
                    Image(systemName: "phone.down.fill").font(.system(size: 24)).foregroundStyle(.white)
                        .frame(width: 72, height: 72)
                        .background(Color(hex: 0xC4554B), in: Circle())
                }
                .accessibilityLabel("挂断")
                Text("end").font(Typo.serif(13).italic()).foregroundStyle(light.opacity(0.6))
            }
        }
    }

    private func control(_ symbol: String, _ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Button(action: action) {
                Image(systemName: symbol).font(.system(size: 21)).foregroundStyle(on ? night : light)
                    .frame(width: 72, height: 72)
                    .background(on ? light : light.opacity(0.10), in: Circle())
                    .overlay(Circle().strokeBorder(light.opacity(0.18), lineWidth: 0.5))
            }
            .accessibilityLabel(label == "speaker" ? Text("扬声器") : Text("静音"))
            Text(label).font(Typo.serif(13).italic()).foregroundStyle(light.opacity(0.6))
        }
    }

    private func minimize() {
        // 收起就是挂断（通话不在后台继续）
        hangUp()
    }

    private func hangUp() {
        session.end()
        dismiss()
    }
}
