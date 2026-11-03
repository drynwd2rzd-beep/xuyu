import SwiftUI

// MARK: - 天气

/// 真实天气：开关，下面一行是 TA 现在知道的天气；城市留空就跟着定位（放在 World 页的 Weather 分组里）
struct WeatherRows: View {
    @AppStorage(Prefs.weatherEnabled) private var on = true
    @AppStorage(Prefs.weatherCity) private var city = ""
    @State private var line = Weather.shortLine

    var body: some View {
        SettingRow(title: "真实天气", subtitle: on ? line : nil) {
            InkToggle(isOn: $on, label: "真实天气")
        }
        .onChange(of: on) { _, now in if now { refresh() } }
        if on {
            HStack(spacing: Space.item) {
                Text("城市").font(.system(size: 16)).foregroundStyle(Palette.ink)
                Spacer()
                TextField("跟着定位", text: $city)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.ink2)
                    .submitLabel(.done)
                    .onSubmit(refresh)
                    .frame(maxWidth: 180)
            }
            .padding(.horizontal, Space.card)
            .frame(height: Space.row)
            .transition(.opacity)
        }
    }

    /// 马上重新取一次天气，取回来后换掉上面那行字
    private func refresh() {
        Task {
            await Weather.refreshIfNeeded(force: true)
            withAnimation(Motion.snappy) { line = Weather.shortLine }
        }
    }
}
