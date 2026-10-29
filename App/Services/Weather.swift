import Foundation
import CoreLocation

/// 真实天气：TA 知道你那边现在什么天气、今天会怎样、明天怎样，日落了没有。
/// 天气来自 Open-Meteo（免费、不用注册、不用密钥），每小时最多取一次；位置用手机定位（只换算成城市和经纬度，不发出去），
/// 或者用你在设置里填的城市。发给 TA 的只有「哪个城市、什么天气」
@MainActor
enum Weather {
    /// 打开「真实天气」（默认开；没给定位、也没填城市时就什么都不说）
    nonisolated static let enabledKey = "weather.enabled"
    /// 自己填的城市（留空就用定位）
    static let cityKey = "weather.city"
    nonisolated private static let summaryKey = "weather.summary"
    private static let placeKey = "weather.place"
    nonisolated private static let fetchedKey = "weather.fetchedAt"

    nonisolated static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// 写进提示词的那段（太旧了就不用：超过 3 小时的天气不准了）
    nonisolated static var summary: String? {
        let d = UserDefaults.standard
        guard enabled, let text = d.string(forKey: summaryKey), !text.isEmpty,
              Date.now.timeIntervalSince1970 - d.double(forKey: fetchedKey) < 3 * 3600 else { return nil }
        return text
    }

    /// 设置里显示的一行：「首尔 · 小雨 14°」
    static var shortLine: String? { UserDefaults.standard.string(forKey: placeKey) }

    private static var refreshing = false

    /// App 打开、回到前台时调用：一小时内取过就不再取
    static func refreshIfNeeded(force: Bool = false) async {
        guard enabled, !DemoMode.isOn, !refreshing else { return }
        let last = UserDefaults.standard.double(forKey: fetchedKey)
        guard force || Date.now.timeIntervalSince1970 - last > 3600 else { return }
        refreshing = true
        defer { refreshing = false }
        guard let place = await locate(), let report = await fetch(place) else { return }
        let d = UserDefaults.standard
        d.set(report.summary, forKey: summaryKey)
        d.set(report.short, forKey: placeKey)
        d.set(Date.now.timeIntervalSince1970, forKey: fetchedKey)
    }

    // MARK: - 在哪儿

    struct Place {
        var name: String
        var latitude: Double
        var longitude: Double
    }

    /// 填了城市就查这个城市；没填就用手机定位（第一次会问你允不允许）
    private static func locate() async -> Place? {
        let city = (UserDefaults.standard.string(forKey: cityKey) ?? "").trimmed
        if !city.isEmpty { return await geocode(city) }
        guard let location = await LocationOnce.shared.current() else { return nil }
        let mark = (try? await CLGeocoder().reverseGeocodeLocation(location))?.first
        let name = mark?.locality ?? mark?.administrativeArea ?? ""
        return Place(name: name.isEmpty ? String(localized: "你那边") : name,
                     latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
    }

    private struct GeoResult: Decodable {
        struct Item: Decodable { var name: String; var latitude: Double; var longitude: Double }
        var results: [Item]?
    }

    private static func geocode(_ city: String) async -> Place? {
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")
        c?.queryItems = [.init(name: "name", value: city), .init(name: "count", value: "1"), .init(name: "language", value: "zh")]
        guard let url = c?.url, let (data, _) = try? await URLSession.shared.data(from: url),
              let first = (try? JSONDecoder().decode(GeoResult.self, from: data))?.results?.first else { return nil }
        return Place(name: first.name, latitude: first.latitude, longitude: first.longitude)
    }

    // MARK: - 天气

    private struct Forecast: Decodable {
        struct Current: Decodable {
            var temperature_2m: Double
            var apparent_temperature: Double
            var relative_humidity_2m: Double
            var weather_code: Int
            var wind_speed_10m: Double
            var is_day: Int
        }
        struct Hourly: Decodable {
            var time: [String]
            var temperature_2m: [Double]
            var precipitation_probability: [Double?]
            var weather_code: [Int]
        }
        struct Daily: Decodable {
            var weather_code: [Int]
            var temperature_2m_max: [Double]
            var temperature_2m_min: [Double]
            var sunset: [String]
            var precipitation_probability_max: [Double?]
        }
        var current: Current
        var hourly: Hourly
        var daily: Daily
    }

    private static func fetch(_ place: Place) async -> (summary: String, short: String)? {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        c?.queryItems = [
            .init(name: "latitude", value: String(place.latitude)),
            .init(name: "longitude", value: String(place.longitude)),
            .init(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,is_day"),
            .init(name: "hourly", value: "temperature_2m,precipitation_probability,weather_code"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,sunset,precipitation_probability_max"),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: "2"),
        ]
        guard let url = c?.url, let (data, _) = try? await URLSession.shared.data(from: url),
              let f = try? JSONDecoder().decode(Forecast.self, from: data), f.daily.weather_code.count >= 2 else { return nil }
        return describe(f, place: place.name)
    }

    /// 写成一段给 TA 看的话
    private static func describe(_ f: Forecast, place: String) -> (summary: String, short: String) {
        let now = f.current
        let sky = name(of: now.weather_code)
        let t = Int(now.temperature_2m.rounded()), feel = Int(now.apparent_temperature.rounded())
        var parts = ["现在\(place)：\(sky)，\(t)°" + (abs(feel - t) >= 2 ? "，体感 \(feel)°" : "") + "，湿度 \(Int(now.relative_humidity_2m))%"
                     + (now.wind_speed_10m >= 25 ? "，风挺大" : "") + "。"]
        parts.append("今天最高 \(Int(f.daily.temperature_2m_max[0].rounded()))° 最低 \(Int(f.daily.temperature_2m_min[0].rounded()))°。")
        // 接下来几小时：会不会下雨、雨什么时候停、晚上降到多少
        let hourFmt = DateFormatter()
        hourFmt.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let upcoming = zip(f.hourly.time.indices, f.hourly.time).compactMap { i, s -> (Date, Int, Double, Double?)? in
            guard let d = hourFmt.date(from: s), d > .now, d < .now.addingTimeInterval(9 * 3600) else { return nil }
            return (d, f.hourly.weather_code[i], f.hourly.temperature_2m[i], f.hourly.precipitation_probability[i] ?? nil)
        }
        let wet = { (code: Int) in code >= 51 }
        if wet(now.weather_code), let dry = upcoming.first(where: { !wet($0.1) }) {
            parts.append("\(Fmt.time24.string(from: dry.0)) 左右雨会停。")
        } else if !wet(now.weather_code), let rain = upcoming.first(where: { wet($0.1) && ($0.3 ?? 0) >= 50 }) {
            parts.append("\(Fmt.time24.string(from: rain.0)) 左右可能会\(name(of: rain.1))。")
        }
        if let coldest = upcoming.min(by: { $0.2 < $1.2 }), Int(coldest.2.rounded()) <= t - 4 {
            parts.append("晚些时候会降到 \(Int(coldest.2.rounded()))°。")
        }
        parts.append("明天\(name(of: f.daily.weather_code[1]))，\(Int(f.daily.temperature_2m_min[1].rounded()))～\(Int(f.daily.temperature_2m_max[1].rounded()))°。")
        if let sunset = hourFmt.date(from: f.daily.sunset[0]) {
            parts.append("今天日落 \(Fmt.time24.string(from: sunset))" + (now.is_day == 0 ? "（外面已经黑了）" : "") + "。")
        }
        return (parts.joined(), "\(place) · \(sky) \(t)°")
    }

    /// 天气代码（WMO）→ 中文
    static func name(of code: Int) -> String {
        switch code {
        case 0: "晴"
        case 1: "大致晴朗"
        case 2: "多云"
        case 3: "阴天"
        case 45, 48: "有雾"
        case 51, 53, 55: "毛毛雨"
        case 56, 57, 66, 67: "冻雨"
        case 61: "小雨"
        case 63: "中雨"
        case 65: "大雨"
        case 71: "小雪"
        case 73: "中雪"
        case 75: "大雪"
        case 77: "下雪粒"
        case 80, 81: "阵雨"
        case 82: "大阵雨"
        case 85, 86: "阵雪"
        case 95: "雷雨"
        case 96, 99: "雷雨夹冰雹"
        default: "多云"
        }
    }
}

/// 取一次当前位置（只要大概的位置，够查天气就行）
@MainActor
final class LocationOnce: NSObject, CLLocationManagerDelegate {
    static let shared = LocationOnce()
    private let manager = CLLocationManager()
    private var waiting: [CheckedContinuation<CLLocation?, Never>] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func current() async -> CLLocation? {
        switch manager.authorizationStatus {
        case .denied, .restricted: return nil
        default: break
        }
        return await withCheckedContinuation { c in
            waiting.append(c)
            if manager.authorizationStatus == .notDetermined {
                manager.requestWhenInUseAuthorization()
            } else if waiting.count == 1 {
                manager.requestLocation()
            }
        }
    }

    private func finish(_ location: CLLocation?) {
        let list = waiting
        waiting = []
        list.forEach { $0.resume(returning: location) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                if !self.waiting.isEmpty { manager.requestLocation() }
            case .denied, .restricted:
                self.finish(nil)
            default: break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let last = locations.last
        Task { @MainActor in self.finish(last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(nil) }
    }
}
