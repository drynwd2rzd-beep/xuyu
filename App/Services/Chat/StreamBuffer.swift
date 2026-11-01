import Foundation
import Observation

/// 正在生成中的消息。单独成对象，流式刷新时只重绘这一条。
@Observable
final class StreamBuffer {
    var text = ""
    var reasoning = ""
    var steps: [String] = []
    /// 先不显示文字（只显示「正在输入」），等这一段写完再整条出现
    var hold = false
    /// 工作模式里正等你点「允许 / 不允许」的那一步
    var approval: PendingApproval?
    /// 打字犹豫：「正在输入」淡出一会儿再出现（像真人打了又删）
    var paused = false
}

/// 工作模式里等你确认的一步：中继给的编号和要做的事
struct PendingApproval: Equatable {
    let req: String
    let text: String
}

/// 你要发出去的一个附件（照片、文件、表情、语音）
struct OutgoingAttachment {
    var kind: AttachmentKind
    var name: String
    var data: Data
}
