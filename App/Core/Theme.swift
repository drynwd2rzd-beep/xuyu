import SwiftUI
import UIKit

enum Typo {
    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .regular, design: .serif) }
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    // 反复出现的几种字：同一种用途只用这一个字号，页面里不再各写各的数字。
    // 新版设计只用 11 · 13 · 15 · 17 · 22 五档
    /// 正文：气泡和动态里的字、输入框、设置行
    static let body: CGFloat = 15
    /// 分区标题、页内小标签、分段控件
    static let label: CGFloat = 13
    /// 副标题、次要说明（行下面那一行灰字、点赞、回复对象）
    static let secondary: CGFloat = 13
    /// 更小的注释：图片张数、工作过程、代码块语言、设置里的分区小标签
    static let caption: CGFloat = 11
    /// 名字、子页面标题
    static let title: CGFloat = 17
    /// 聊天气泡里的字（像 iMessage 一样大一点）
    static let bubble: CGFloat = 17
    /// 页面大标题（细字、宽字距）
    static let heading: CGFloat = 22
    /// 设置行的标题（UI-1）
    static let rowTitle: CGFloat = 15
    /// 设置行右边的当前值
    static let value: CGFloat = 13

    /// 主页画册里的大字（装饰性的大号，只在画册里用）
    enum Book {
        /// 动态、聊天列表这类页面的大标题（细字、宽字距）
        static let title: CGFloat = 26
        /// 封面上 TA 的那句话，和它的行距
        static let quote: CGFloat = 26
        static let quoteSpacing: CGFloat = 16
        /// 「此刻」那一页 TA 在做的事（宋体），和它的行距
        static let prose: CGFloat = 16
        static let proseSpacing: CGFloat = 14
        /// 日记正文的行距（很松，像本子）
        static let diarySpacing: CGFloat = 20
        /// 动态那一页的一句话
        static let post: CGFloat = 21
        /// 「此刻」那一页的心情词（很细的字）
        static let mood: CGFloat = 36
        /// 待办那一页的大数字
        static let count: CGFloat = 132
        /// 日记那一页的日期
        static let date: CGFloat = 64
        /// 日记正文
        static let diary: CGFloat = 18
        /// 一起听的歌名
        static let song: CGFloat = 23
    }

    /// 中文小标题、设置行的字距：新版设计的字都略微拉开
    static let tracking: CGFloat = 0.6
    /// 底栏英文小字的字距（全大写，拉得很开）
    static let tabTracking: CGFloat = 3.4
    /// 英文小标签（AI、App、分区名）的大字距
    static let labelTracking: CGFloat = 3
}

/// 统一圆角：所有页面只从这里取值，全部使用 iPhone 屏幕同款的连续曲率圆角（.continuous）。
enum Radius {
    /// iPhone 屏幕本身的圆角：整页在动时（侧滑返回）四角跟屏幕一样圆
    static let screen: CGFloat = 55
    /// 卡片、文字块
    static let card: CGFloat = 18
    /// 照片卡（画册、瀑布流）
    static let photo: CGFloat = 8
    /// 设置首页的角色卡
    static let cast: CGFloat = 22
    /// 小方块：表情、组件库图标、代码块
    static let tile: CGFloat = 18
    /// 聊天气泡
    static let bubble: CGFloat = 18
    /// 底部弹出面板顶部
    static let sheet: CGFloat = 38
    /// 小控件：头像底色块、分段内块
    static let control: CGFloat = 12
}

extension Shape where Self == RoundedRectangle {
    /// 统一的连续曲率圆角矩形
    static func rounded(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}

/// 统一间距
enum Space {
    /// 页面左右边距
    static let page: CGFloat = 18
    /// 卡片与卡片之间
    static let section: CGFloat = 14
    /// 主页画册：字离屏幕左右边、页眉离顶、正文离底（底栏在下面）
    static let book: CGFloat = 28
    static let bookTop: CGFloat = 64
    static let bookBottom: CGFloat = 132
    /// 底栏三个字之间、当前那页下面的小点
    static let tabGap: CGFloat = 52
    static let tabDot: CGFloat = 3
    /// 同一组气泡之间（像 iMessage 一样几乎贴着）
    static let bubbleGap: CGFloat = 2
    /// 设置里一组和一组之间：靠留白分开，不加线
    static let group: CGFloat = 24
    /// 滚动页最下面留的空
    static let bottom: CGFloat = 40
    /// 卡片内边距
    static let card: CGFloat = 16
    /// 元素之间
    static let item: CGFloat = 12
    /// 最紧的地方：图标和数字之间、几行小字之间
    static let tiny: CGFloat = 4
    /// 紧凑处
    static let tight: CGFloat = 8
    /// 列表行高
    static let row: CGFloat = 52
    /// 带副标题的行高
    static let rowTall: CGFloat = 60
    /// 输入框、按钮高度
    static let control: CGFloat = 42
    /// 搜索框的高度、未读小数字的最小尺寸
    static let search: CGFloat = 38
    static let badge: CGFloat = 18
    /// 聊天输入框（一行时）和加号的高度：照 iMessage
    static let field: CGFloat = 36
    /// 页面顶部到标题
    static let top: CGFloat = 16
}

/// 头像尺寸（UI-1）
enum AvatarSize {
    /// 聊天页头
    static let header: CGFloat = 36
    /// 画册封面右上角进设置的头像
    static let folio: CGFloat = 30
    /// 动态里带照片那一条的头像、纯文字那一条的头像
    static let post: CGFloat = 32
    static let tweet: CGFloat = 38
    /// 动态顶上那一排快拍
    static let story: CGFloat = 64
    /// 快拍环里面的头像、名字最宽多少
    static let storyFace: CGFloat = 56
    static let storyLabel: CGFloat = 76
    /// 动态详情里的评论头像、回复别人的那条（小一点、往里缩一格）
    static let comment: CGFloat = 30
    static let reply: CGFloat = 24
    static let replyIndent: CGFloat = 42
    /// TA 的主页上压在横幅下沿的头像
    static let profile: CGFloat = 76
    /// 这个头像有多少压进横幅里（一半）
    static let profileOverlap: CGFloat = 38
    /// 聊天列表的头像
    static let list: CGFloat = 50
    /// 设置首页「你」的头像
    static let me: CGFloat = 58
}

/// 图标和小按钮的尺寸（UI-1）
enum Icon {
    /// 输入栏的加号、话筒
    static let plus: CGFloat = 16
    /// 输入框里每个小按钮占的宽度（表情、话筒 / 发送）
    static let fieldButton: CGFloat = 32
    /// 蓝色发送圆
    static let send: CGFloat = 28
    /// 发送圆里的箭头
    static let sendGlyph: CGFloat = 13
    /// 动态里喜欢、评论的图标：带照片的大一号，纯文字的小一号
    static let postAction: CGFloat = 22
    static let tweetAction: CGFloat = 17
    /// 双击照片时中间冒出来的那颗心
    static let heartPop: CGFloat = 84
    /// 发动态的笔
    static let compose: CGFloat = 21
    /// 聊天列表里置顶的小图钉
    static let pin: CGFloat = 9
    /// 返回键的箭头
    static let back: CGFloat = 18
    /// 快拍里「你」那个头像右下角的加号
    static let storyPlus: CGFloat = 20
    /// 一起听的播放 / 暂停
    static let play: CGFloat = 18
    /// 加号菜单里的彩色圆图标
    static let menuCircle: CGFloat = 40
    /// 加号菜单圆图标里的符号
    static let menuGlyph: CGFloat = 18
}

/// 统一的弹簧动画
enum Motion {
    /// 主动画：稍慢、几乎不回弹，温柔地落位
    static let spring = Animation.spring(duration: 0.52, bounce: 0.06)
    /// 小切换（分段、筛选、按钮图标）：短一点，同样不弹
    static let snappy = Animation.spring(duration: 0.36, bounce: 0)
    /// 滚动、背景这类大面积变化：平滑淡入淡出
    static let glide = Animation.smooth(duration: 0.48)
    /// 按下：很快地沉下去
    static let pressIn = Animation.spring(duration: 0.2, bounce: 0)
    /// 松手：慢慢地回来，不弹跳
    static let pressOut = Animation.spring(duration: 0.5, bounce: 0)
    /// 拖动松手后的归位：跟着手势速度，柔和收尾
    static let settle = Animation.interpolatingSpring(mass: 1, stiffness: 170, damping: 24)
    /// 心情光晕的呼吸：很慢地一大一小，一直循环（MoodGlow；减弱动态效果时不用）
    static let breathe = Animation.easeInOut(duration: 7).repeatForever(autoreverses: true)
    /// 主页画册翻到一页时，那一页的字从糊到清楚地浮现出来
    static let reveal = Animation.easeOut(duration: 1.1)
    /// 同一页里的几行字依次浮现，每行比上一行晚多少秒
    static let revealStep: Double = 0.12
    /// 一串东西依次出现时，每个比上一个晚多少秒（加号菜单）
    static let stagger: Double = 0.03
    /// 很快地淡掉（或在原地换一样东西）：小点变字前淡出、切页前旧页淡出、键盘和面板互换
    static let fade = Animation.easeOut(duration: 0.18)
    /// 打开聊天：从点的那一行飞进去，一气呵成不回弹
    static var shuttleIn: Animation { reduced ? .easeInOut(duration: 0.3) : .spring(duration: 0.5, bounce: 0) }
    /// 返回：聊天页像雾一样散开，列表退回原位
    static var shuttleOut: Animation { reduced ? .easeInOut(duration: 0.3) : .timingCurve(0.25, 0.6, 0.3, 1, duration: 0.46) }
    /// 系统设置里打开了「减少动态效果」：放大、飞入、滑动都换成原地淡入淡出
    static var reduced: Bool { UIAccessibility.isReduceMotionEnabled }
    // 气泡（以 iMessage 为准）：所有气泡——你发的、TA 回的、正在输入的小点、表情、图片、语音、文件——都只用下面这两条，
    // 节奏完全一样。气泡本身轻轻一弹；被它带动的滚动（上面的消息让开）平稳不弹，不然整列消息会跟着晃

    /// 气泡带动的变化：新的一行进来时滚到最新、撤回、拿掉
    static let bubble = Animation.spring(duration: 0.42, bounce: 0)
    /// 气泡本身放大显现的那一下（新消息、小点变成文字）：同样的时长，带一点弹性
    static let bubblePop = Animation.spring(duration: 0.42, bounce: 0.2)

    // 等动画走完再做下一步（ARCH-5）：能用 onDismiss 回调的地方用回调，用不了的（推出去的页面退回、聊天层散开）才等这两个

    /// 页面退回、sheet 收起、聊天层散开要的时间：走完再删数据、再弹下一个（删了还在显示的东西会闪一下或变成空白页）
    static let dismissSettle = Duration.milliseconds(450)
    /// 长按菜单收起要的时间：收起后再展开别的，两个动画不撞在一起
    static let menuSettle = Duration.milliseconds(380)
}

