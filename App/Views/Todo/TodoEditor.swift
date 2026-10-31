import SwiftUI
import SwiftData

struct TodoEditor: View {
    @Bindable var item: TodoItem
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var deleted = false
    @State private var denied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.section) {
                HStack {
                    Button("删除", role: .destructive) {
                        deleted = true
                        Reminders.cancel(item)
                        dismiss()
                        let target = item
                        Task {
                            try? await Task.sleep(for: Motion.dismissSettle)
                            context.delete(target)
                            context.persist()
                        }
                    }
                    .foregroundStyle(Palette.danger)
                    Spacer()
                    Button("完成") { dismiss() }.fontWeight(.semibold).foregroundStyle(Palette.ink)
                }
                .font(.system(size: 16))

                VStack(alignment: .leading, spacing: 0) {
                    TextField("要做的事", text: $item.title, axis: .vertical)
                        .font(Typo.serif(19))
                        .padding(Space.card)
                    Hairline()
                    TextField("备注", text: $item.notes, axis: .vertical)
                        .font(.system(size: 15))
                        .lineLimit(2...6)
                        .padding(Space.card)
                }
                .card()

                VStack(spacing: 0) {
                    SettingRow(title: "日期") {
                        Toggle("", isOn: dateBinding).labelsHidden().tint(Palette.ink)
                    }
                    if item.dueDate != nil {
                        Hairline()
                        SettingRow(title: "哪一天") {
                            DatePicker("", selection: dueBinding, displayedComponents: .date).labelsHidden()
                        }
                        Hairline()
                        SettingRow(title: "具体时间") {
                            Toggle("", isOn: timeBinding).labelsHidden().tint(Palette.ink)
                        }
                        if item.hasTime {
                            Hairline()
                            SettingRow(title: "几点") {
                                DatePicker("", selection: dueBinding, displayedComponents: .hourAndMinute).labelsHidden()
                            }
                        }
                        Hairline()
                        SettingRow(title: "提醒我", subtitle: item.remind && !item.hasTime ? "当天上午 9:00" : nil) {
                            Toggle("", isOn: remindBinding).labelsHidden().tint(Palette.ink)
                        }
                        if item.remind && item.hasTime {
                            Hairline()
                            SettingRow(title: "提前") {
                                Picker("", selection: $item.remindLead) {
                                    Text("准时").tag(0)
                                    Text("5 分钟").tag(5)
                                    Text("10 分钟").tag(10)
                                    Text("30 分钟").tag(30)
                                    Text("1 小时").tag(60)
                                }
                                .labelsHidden()
                                .tint(Palette.ink2)
                            }
                        }
                    }
                }
                .card()
                .animation(Motion.spring, value: item.dueDate != nil)
                .animation(Motion.spring, value: item.hasTime)
                .animation(Motion.spring, value: item.remind)
            }
            .padding(Space.page)
        }
        .alert("需要在系统设置里允许「絮语」发送通知。", isPresented: $denied) { Button("好", role: .cancel) {} }
        .onDisappear {
            guard !deleted else { return }
            if item.title.trimmed.isEmpty { item.title = "未命名" }
            context.persist()
            Reminders.sync(item)
        }
    }

    private var dateBinding: Binding<Bool> {
        Binding(get: { item.dueDate != nil }, set: { on in
            item.dueDate = on ? Date.now.startOfDay : nil
            if !on {
                item.hasTime = false
                item.remind = false
            }
        })
    }

    private var dueBinding: Binding<Date> {
        Binding(get: { item.dueDate ?? .now }, set: { item.dueDate = item.hasTime ? $0 : $0.startOfDay })
    }

    private var timeBinding: Binding<Bool> {
        Binding(get: { item.hasTime }, set: { on in
            item.hasTime = on
            let day = (item.dueDate ?? .now).startOfDay
            if on {
                let hour = max(Calendar.current.component(.hour, from: .now) + 1, 9)
                item.dueDate = Calendar.current.date(bySettingHour: min(hour, 21), minute: 0, second: 0, of: day)
            } else {
                item.dueDate = day
            }
        })
    }

    private var remindBinding: Binding<Bool> {
        Binding(get: { item.remind }, set: { on in
            item.remind = on
            guard on else { return }
            Task {
                if !(await Reminders.ensureAuthorized()) {
                    item.remind = false
                    denied = true
                }
            }
        })
    }
}
