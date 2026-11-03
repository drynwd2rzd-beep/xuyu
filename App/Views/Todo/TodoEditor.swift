import SwiftUI
import SwiftData

/// 编辑一条待办：标题、备注、日期、时间、提醒；关掉时没写标题就叫「未命名」，并同步提醒
struct TodoEditor: View {
    @Bindable var item: TodoItem
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var deleted = false
    @State private var denied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.section) {
                header
                textCard
                scheduleCard
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

    // MARK: - 分组

    /// 顶上一行：左边删除，右边完成
    private var header: some View {
        HStack {
            Button("删除", role: .destructive, action: deleteItem)
                .foregroundStyle(Palette.danger)
            Spacer()
            Button("完成") { dismiss() }.fontWeight(.semibold).foregroundStyle(Palette.ink)
        }
        .font(.system(size: 16))
    }

    /// 要做的事和备注
    private var textCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("要做的事", text: $item.title, axis: .vertical)
                .font(Typo.serif(19))
                .padding(Space.card)
            TextField("备注", text: $item.notes, axis: .vertical)
                .font(.system(size: 15))
                .lineLimit(2...6)
                .padding(Space.card)
        }
        .card()
    }

    /// 日期、时间和提醒：打开一项才展开下面的几行
    private var scheduleCard: some View {
        VStack(spacing: 0) {
            SettingRow(title: "日期") {
                Toggle("", isOn: dateBinding).labelsHidden().tint(Palette.ink)
            }
            if item.dueDate != nil {
                SettingRow(title: "哪一天") {
                    DatePicker("", selection: dueBinding, displayedComponents: .date).labelsHidden()
                }
                SettingRow(title: "具体时间") {
                    Toggle("", isOn: timeBinding).labelsHidden().tint(Palette.ink)
                }
                if item.hasTime {
                    SettingRow(title: "几点") {
                        DatePicker("", selection: dueBinding, displayedComponents: .hourAndMinute).labelsHidden()
                    }
                }
                SettingRow(title: "提醒我", subtitle: item.remind && !item.hasTime ? "当天上午 9:00" : nil) {
                    Toggle("", isOn: remindBinding).labelsHidden().tint(Palette.ink)
                }
                if item.remind && item.hasTime {
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

    // MARK: - 操作

    /// 删除这条待办：先撤提醒、关掉这一页，等页面收起后再从数据库删
    private func deleteItem() {
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
