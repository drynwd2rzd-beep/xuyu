import Foundation
import Network
import Observation

struct EngineStatus: Decodable, Equatable {
    var installed: Bool
    var version: String
}

struct ModelInfo: Decodable, Equatable, Hashable, Identifiable {
    var id: String
    var name: String
    var description: String
    var efforts: [String]
    var defaultEffort: String
}

struct RelayStatus: Decodable, Equatable {
    struct Models: Decodable, Equatable {
        var claude: [String]
        var codex: [String]
    }
    struct Catalog: Decodable, Equatable {
        var claude: [ModelInfo]
        var codex: [ModelInfo]
    }
    var host: String
    var claude: EngineStatus
    var codex: EngineStatus
    var models: Models
    var catalog: Catalog?
    /// 电脑开机时是否自动启动中继
    var autostart: Bool?

    func catalog(for engine: Engine) -> [ModelInfo] {
        if let catalog { return engine == .claude ? catalog.claude : catalog.codex }
        let ids = engine == .claude ? models.claude : models.codex
        return ids.map { ModelInfo(id: $0, name: $0, description: "", efforts: [], defaultEffort: "") }
    }
}

/// 推理强度的中文名
enum EffortName {
    static func label(_ effort: String) -> String {
        switch effort {
        case "minimal": "最低"
        case "low": "低"
        case "medium": "中"
        case "high": "高"
        case "xhigh": "很高"
        case "max": "最高"
        case "ultra": "极限"
        case "": "默认"
        default: effort
        }
    }
}

struct RelayAttachment: Encodable {
    var kind: String
    var name: String
    var data: String
}

struct RelayRequest: Encodable {
    var engine: String
    var model: String
    var effort: String = ""
    var system: String
    var prompt: String
    var attachments: [RelayAttachment] = []
    /// 工作模式：允许在电脑的工作文件夹里读写文件、运行命令
    var work = false
}

enum RelayEvent {
    case text(String)
    case reasoning(String)
    /// 工作模式里做的一步，例如「读取 报告.docx」
    case step(String)
    /// 工作模式里发回手机的文件
    case file(String, Data)
    /// 工作模式里 AI 想运行命令、打开网页：等你在手机上点「允许 / 不允许」（req 用来对上号）
    case approval(req: String, text: String)
}

enum RelayError: LocalizedError {
    case notConfigured
    case unreachable
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "还没有连接电脑。在 To Do 右上角打开设置，点「电脑中继」填写地址和配对码。"
        case .unreachable: "连不上电脑上的中继。请确认电脑开着中继窗口，并且和手机在同一个网络。"
        case .server(let message): message
        }
    }
}
