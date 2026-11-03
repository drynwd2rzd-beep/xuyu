import XCTest

/// 云端自动操作测试：用示例数据打开 App，把主要的点击流程走一遍，中途闪退就会失败
final class FlowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ screen: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "YES", "-demoScreen", screen]
        app.launch()
        return app
    }

    private func tapIfExists(_ element: XCUIElement, wait: TimeInterval = 5) {
        if element.waitForExistence(timeout: wait) { element.tap() }
    }

    func testChatFlow() {
        let app = launch("chats")
        let row = app.buttons["chatRow"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "聊天列表没有出现")
        row.tap()

        // 表情面板 ↔ 键盘 ↔ 加号菜单来回切
        tapIfExists(app.buttons["表情"])
        sleep(1)
        tapIfExists(app.buttons["键盘"])
        sleep(1)
        let plus = app.buttons["更多"]
        XCTAssertTrue(plus.waitForExistence(timeout: 5), "输入栏没有加号")
        plus.tap()
        XCTAssertTrue(app.buttons["照片"].waitForExistence(timeout: 5), "加号菜单没有浮出来")
        plus.tap()
        sleep(1)
        XCTAssertFalse(app.buttons["照片"].exists, "加号菜单没有收起")

        // 打字发送
        let field = app.textFields.firstMatch
        if field.waitForExistence(timeout: 5) {
            field.tap()
            field.typeText("你好")
            tapIfExists(app.buttons["发送"])
        }
        sleep(2)

        // 往上翻、点一下聊天区域收起键盘
        app.swipeDown()
        sleep(1)
        tapIfExists(app.buttons["返回"])
        XCTAssertEqual(app.state, .runningForeground, "App 闪退了")
    }

    func testTodayAndSettings() {
        let app = launch("today")
        let month = app.buttons["monthToggle"]
        XCTAssertTrue(month.waitForExistence(timeout: 10), "Today 页没有出现")

        // 点封面上的日期弹出月历，翻一个月再翻回来；点这个月 1 号去看那一天，再回到今天
        month.tap()
        sleep(1)
        tapIfExists(app.buttons["上个月"])
        tapIfExists(app.buttons["下个月"])
        tapIfExists(app.buttons["1"].firstMatch)
        sleep(1)
        tapIfExists(app.buttons["回到今天"])
        sleep(1)

        // 画册往下翻到待办页，在清单末尾写一条新待办，再翻回封面
        app.swipeUp()
        app.swipeUp()
        let add = app.textFields["新待办"]
        XCTAssertTrue(add.waitForExistence(timeout: 5), "画册里没有翻到待办页")
        add.tap()
        add.typeText("测试待办\n")
        sleep(1)
        app.swipeDown()
        app.swipeDown()
        sleep(1)

        // 封面右上角的头像进设置
        let settings = app.buttons["设置"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "封面上没有进设置的头像")
        settings.tap()
        tapIfExists(app.buttons["备份与恢复"])
        sleep(1)
        tapIfExists(app.buttons["返回"])
        tapIfExists(app.buttons["外观与背景"])
        sleep(1)
        tapIfExists(app.buttons["返回"])
        tapIfExists(app.buttons["通知"])
        sleep(1)

        // 切换底部三个页面
        tapIfExists(app.buttons["返回"])
        tapIfExists(app.buttons["返回"])
        let moments = app.buttons["Moments"]
        XCTAssertTrue(moments.waitForExistence(timeout: 5), "底栏没有 Moments")
        moments.tap()
        XCTAssertTrue(app.buttons["发动态"].firstMatch.waitForExistence(timeout: 5), "动态页没有出现")
        tapIfExists(app.buttons["Chats"])
        tapIfExists(app.buttons["Today"])
        XCTAssertEqual(app.state, .runningForeground, "App 闪退了")
    }
}
