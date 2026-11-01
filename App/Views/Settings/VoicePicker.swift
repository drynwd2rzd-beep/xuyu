import SwiftUI
import SwiftData

// MARK: - 选择声音

/// 给角色挑一个声音：上面是自己复刻的（可以改名、删除），下面是这家的全部声音，右边可以先试听。
/// onPick 不为空时只是挑一个声音（混合声音用），不改角色
struct VoicePicker: View {
    @Bindable var persona: Persona
    var onPick: ((Voice.Choice) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var service: VoiceProvider = .elevenlabs
    @State private var voices: [Voice.Choice] = []
    @State private var loaded = false
    @State private var failure: String?
    @State private var notice: String?
    @State private var query = ""
    @State private var customID = ""
    @State private var cloning = false
    @State private var renaming: Voice.Choice?
    @State private var newName = ""
    @State private var deleting: Voice.Choice?
    @State private var loadingPreview: String?
    /// 试听过的声音留在这里，再点不用重新下载或现念
    @State private var previews: [String: Data] = [:]
    /// 试听没成功的原因
    @State private var previewFailure: String?

    init(persona: Persona, onPick: ((Voice.Choice) -> Void)? = nil) {
        _persona = Bindable(persona)
        self.onPick = onPick
        _service = State(initialValue: Voice.provider(of: persona))
    }

    private var player: VoicePlayer { VoicePlayer.shared }
    private var picking: Bool { onPick != nil }

    /// 声音很多：可以搜名字和描述
    private func filtered(_ list: [Voice.Choice]) -> [Voice.Choice] {
        let q = query.trimmed
        guard !q.isEmpty else { return list }
        return list.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.detail.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        let mine = filtered(voices.filter(\.mine))
        let others = filtered(voices.filter { !$0.mine })
        VoiceSheet(title: picking ? "添加声音" : "选择声音") {
            if !picking && Voice.configured.count > 1 {
                Segmented(items: Voice.configured.map { ($0, $0.label) }, selection: $service)
                    .frame(maxWidth: .infinity)
            }
            if voices.count > 12 {
                SearchField(text: $query, placeholder: "搜索")
            }
            if !picking || !mine.isEmpty {
                mineGroup(mine)
            }
            if !picking {
                customIDRow
            }
            allGroup(others)
        }
        .task(id: service) { await load() }
        .onDisappear { player.stop() }
        .sheet(isPresented: $cloning) {
            VoiceCloneSheet(provider: service, persona: persona) {
                Task { await load() }
            }
        }
        .alert("重命名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { v in
            TextField("名字", text: $newName)
            Button("保存") { rename(v) }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog(Text("删除「\(deleting?.name ?? "")」？"),
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { v in
            Button("删除", role: .destructive) { delete(v) }
        } message: { _ in
            Text("删除后找不回来，用这个声音的角色也会没有声音。")
        }
        .alert("没能试听", isPresented: Binding(get: { previewFailure != nil }, set: { if !$0 { previewFailure = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(previewFailure ?? "")
        }
    }

    // MARK: - 分组

    /// 我的声音：复刻新声音的入口、自己复刻的声音，下面一行是改名或删除没成功的原因
    @ViewBuilder
    private func mineGroup(_ mine: [Voice.Choice]) -> some View {
        SettingsGroup(title: "我的声音") {
            if !picking {
                Button { cloning = true } label: {
                    SettingRow(title: "复刻新声音") {
                        Image(systemName: "plus").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                    }
                }
                .buttonStyle(PressableRowStyle())
            }
            ForEach(Array(mine.enumerated()), id: \.element.id) { index, v in
                if index > 0 || !picking { Hairline() }
                row(v)
            }
        }
        if let notice {
            Text(LocalizedStringKey(notice)).font(.system(size: 13)).foregroundStyle(Palette.inkSoft).padding(.horizontal, 6)
        }
    }

    /// 在官网复刻、还没用过的声音不在列表里：直接填它的 ID 也能马上用
    private var customIDRow: some View {
        HStack(spacing: Space.tight) {
            TextField("填写声音 ID", text: $customID)
                .font(.system(size: 15))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit(useCustomID)
            Button("使用", action: useCustomID)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(customID.trimmed.isEmpty ? Palette.faint : Palette.ink)
                .disabled(customID.trimmed.isEmpty)
        }
        .padding(.horizontal, Space.card)
        .frame(minHeight: Space.row)
        .card()
    }

    /// 这家的全部声音（不含自己的）：读不出来时显示原因，还在读时转圈
    private func allGroup(_ others: [Voice.Choice]) -> some View {
        SettingsGroup(title: "全部声音") {
            if let failure {
                Text(failure).font(.system(size: 14)).foregroundStyle(Palette.inkSoft).padding(Space.card)
            } else if !loaded {
                ProgressView().frame(maxWidth: .infinity).padding(Space.section)
            }
            ForEach(Array(others.enumerated()), id: \.element.id) { index, v in
                if index > 0 { Hairline() }
                row(v)
            }
        }
    }

    // MARK: - 一行声音

    private func row(_ v: Voice.Choice) -> some View {
        Button {
            if let onPick {
                onPick(v)
                dismiss()
            } else {
                choose(id: v.id, name: v.name)
            }
        } label: {
            HStack(spacing: Space.item) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(v.name).font(.system(size: 15)).foregroundStyle(Palette.ink).lineLimit(1)
                    if !v.detail.isEmpty {
                        Text(v.detail).font(.system(size: 12)).foregroundStyle(Palette.inkSoft).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if !picking && persona.voiceID == v.id {
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                }
                previewButton(v)
            }
            .padding(.horizontal, Space.card)
            .frame(minHeight: Space.row + 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableRowStyle())
        .contextMenu {
            if v.mine && !picking {
                Button { newName = v.name; renaming = v } label: { Label("重命名", systemImage: "pencil") }
                Button(role: .destructive) { deleting = v } label: { Label("删除", systemImage: "trash") }
            }
        }
    }

    /// 试听：ElevenLabs 下载自带的样音；没有样音的用这个声音现念一句（见 VoiceLibrary.sample）
    private func previewButton(_ v: Voice.Choice) -> some View {
        Button {
            if let data = previews[v.id] {
                if !player.toggle(v.id, data: data) { previewFailure = String(localized: "这段声音放不出来。") }
                return
            }
            loadingPreview = v.id
            Task {
                defer { loadingPreview = nil }
                do {
                    let data = try await VoiceLibrary.sample(of: v, on: service, for: persona)
                    // 放不出来的不留着，下次点还会重新取
                    guard player.toggle(v.id, data: data) else {
                        previewFailure = String(localized: "这段声音放不出来。")
                        return
                    }
                    previews[v.id] = data
                } catch {
                    // 以前失败了转一下圈就没了，什么也不说
                    previewFailure = error.localizedDescription
                }
            }
        } label: {
            Group {
                if loadingPreview == v.id {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: player.playing == v.id ? "stop.fill" : "play.fill")
                        .font(.system(size: 11, weight: .bold))
                }
            }
            .foregroundStyle(Palette.ink)
            .frame(width: 32, height: 32)
            .background(Palette.fill, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("试听")
    }

    // MARK: - 操作

    private func load() async {
        loaded = false
        failure = nil
        do {
            let list = try await Voice.voices(service)
            withAnimation(Motion.spring) { voices = list }
        } catch {
            voices = []
            failure = error.localizedDescription
        }
        loaded = true
    }

    /// 换成这个声音（见 VoiceLibrary.assign），然后关掉这一页
    private func choose(id: String, name: String) {
        VoiceLibrary.assign(id, name: name, on: service, to: persona)
        dismiss()
    }

    /// 用填进来的声音 ID（名字先显示 ID，之后可以改）
    private func useCustomID() {
        let id = customID.trimmed
        guard !id.isEmpty else { return }
        choose(id: id, name: VoiceNames.all[id] ?? id)
    }

    /// 改名：所有用这个声音的角色一起改
    private func rename(_ v: Voice.Choice) {
        let name = newName.trimmed
        guard !name.isEmpty else { return }
        Task {
            do {
                try await VoiceLibrary.rename(v, to: name, on: service, context: context)
                notice = nil
                await load()
            } catch {
                notice = error.localizedDescription
            }
        }
    }

    /// 删除：用这个声音的角色变回没有声音
    private func delete(_ v: Voice.Choice) {
        Task {
            do {
                try await VoiceLibrary.delete(v, on: service, context: context)
                notice = nil
                await load()
            } catch {
                notice = error.localizedDescription
            }
        }
    }
}
