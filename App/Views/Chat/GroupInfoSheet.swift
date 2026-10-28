import SwiftUI
import SwiftData
import UIKit
import PhotosUI

/// 记忆：它从更早的聊天里记住的事，可以直接改或删
struct MemoryEditor: View {
    @Binding var memory: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            HStack {
                SectionLabel(text: "记忆")
                Spacer()
                if !memory.trimmed.isEmpty {
                    Button("清空") { withAnimation(Motion.spring) { memory = "" } }
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.inkSoft)
                        .padding(.trailing, 6)
                }
            }
            TextField("聊得多了，会自己记住关于你的事", text: $memory, axis: .vertical)
                .font(.system(size: 15))
                .lineSpacing(5)
                .lineLimit(2...14)
                .foregroundStyle(Palette.ink)
                .padding(Space.card)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
        }
    }
}

/// 删除群聊 / 清空单聊
enum ConversationRemover {
    @MainActor
    static func remove(_ convo: Conversation, context: ModelContext, engine: ChatEngine) {
        engine.stop(convo)
        Companion.cancelPlannedMessages(in: convo, context: context)
        if convo.isGroup {
            WallpaperStore.remove(for: convo.id)
            context.delete(convo)
        } else {
            for m in convo.messages ?? [] { context.delete(m) }
            Memory.reset(convo)
        }
        context.persist()
    }
}

struct GroupInfoSheet: View {
    @Bindable var convo: Conversation
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Persona.sortIndex) private var personas: [Persona]
    @Environment(Router.self) private var router
    @Environment(ChatEngine.self) private var engine
    @State private var confirmClear = false
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.section) {
                    VStack(alignment: .leading, spacing: Space.tight) {
                        SectionLabel(text: "群聊名称")
                        TextField("群聊", text: $convo.title)
                            .font(.system(size: 16))
                            .padding(.horizontal, Space.card)
                            .frame(height: Space.row)
                            .card()
                    }
                    VStack(alignment: .leading, spacing: Space.tight) {
                        SectionLabel(text: "成员")
                        VStack(spacing: 0) {
                            ForEach(personas) { p in
                                Button { toggle(p) } label: {
                                    HStack(spacing: Space.item) {
                                        AvatarView(persona: p, size: 32)
                                        Text(p.name).font(.system(size: 16)).foregroundStyle(Palette.ink)
                                        Spacer()
                                        if convo.memberIDs.contains(p.id) {
                                            Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink)
                                        }
                                    }
                                    .padding(.horizontal, Space.card)
                                    .frame(height: Space.row)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(PressableRowStyle())
                                if p.id != personas.last?.id { Hairline(inset: 60) }
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                        .card()
                    }
                    VStack(alignment: .leading, spacing: Space.tight) {
                        SectionLabel(text: "自动讨论")
                        VStack(alignment: .leading, spacing: Space.tight) {
                            Segmented(items: [(1, "不讨论"), (-1, "偶尔"), (2, "2 轮"), (3, "3 轮")], selection: $convo.discussRounds)
                            Text("你说一句后，大家会接着彼此的话聊几轮；「偶尔」是有时聊上两三轮、有时各回一句。你随时插话就会停下来听你说。")
                                .font(.system(size: Typo.secondary))
                                .foregroundStyle(Palette.inkSoft)
                                .padding(.horizontal, 4)
                        }
                        .padding(Space.card)
                        .card()
                    }
                    MemoryEditor(memory: $convo.memory)
                    VStack(alignment: .leading, spacing: Space.tight) {
                        SectionLabel(text: "聊天背景")
                        WallpaperPicker(owner: convo.id)
                            .padding(Space.card)
                            .card()
                    }
                    VStack(spacing: 0) {
                        Button { confirmClear = true } label: {
                            Text("清空聊天记录")
                                .font(.system(size: 16))
                                .foregroundStyle(Palette.danger)
                                .frame(maxWidth: .infinity)
                                .frame(height: Space.row)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableRowStyle())
                        Hairline()
                        Button { confirmDelete = true } label: {
                            Text("删除群聊")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(Palette.danger)
                                .frame(maxWidth: .infinity)
                                .frame(height: Space.row)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableRowStyle())
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    .card()
                }
                .padding(Space.page)
            }
            .background(Palette.paper.ignoresSafeArea())
            .navigationTitle("群聊")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        context.persist()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .confirmationDialog("清空这个群聊的记录？", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("清空", role: .destructive) {
                    for m in convo.messages ?? [] { context.delete(m) }
                    Memory.reset(convo)
                    context.persist()
                }
            } message: {
                Text("成员会保留，聊天记录和记忆删除后无法恢复。")
            }
            .confirmationDialog("删除这个群聊？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    dismiss()
                    // 先退出聊天页，再删数据，避免页面还在显示已删除的对话
                    router.closeChat()
                    let target = convo
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(450))
                        ConversationRemover.remove(target, context: context, engine: engine)
                    }
                }
            } message: {
                Text("群聊和里面的记录都会删除，无法恢复。")
            }
        }
    }

    private func toggle(_ p: Persona) {
        if let i = convo.memberIDs.firstIndex(of: p.id) {
            if convo.memberIDs.count > 2 { convo.memberIDs.remove(at: i) }
        } else {
            convo.memberIDs.append(p.id)
        }
    }
}
