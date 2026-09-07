import AppKit
import XCTest

/// Exercises the production search bridge and local model inside a disposable app home.
/// No provider is started and the UI-testing runtime never changes the user's CLI configuration.
final class NativeSearchExperienceUITests: XCTestCase {
    private var app: XCUIApplication!
    private var fixtureRoot: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-native-experience-\(UUID().uuidString)", isDirectory: true)
        let history = fixtureRoot.appendingPathComponent("history", isDirectory: true)
        let project = history.appendingPathComponent("projects/experience", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try writeSession("alpha", title: "Alpha architecture", day: 1,
                         answer: "nimbusneedle: an architecture decision about local vector search.", to: project)
        try writeSession("beta", title: "Beta implementation", day: 2,
                         answer: "nimbusneedle: the implementation keeps every exact result. nimbusneedle remains searchable.", to: project)
        try writeSession("other", title: "Unrelated session", day: 3,
                         answer: "A separate discussion of window geometry.", to: project)

        app = XCUIApplication()
        if app.state != .notRunning {
            app.terminate()
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 8))
        }
        app.launchEnvironment["CCBUD_UI_TESTING"] = "1"
        app.launchEnvironment["CCBUD_HOME"] = fixtureRoot.appendingPathComponent("app-home").path
        app.launchEnvironment["CCBUD_UI_HISTORY_DIR"] = history.path
        app.launchEnvironment["CCBUD_UI_LANGUAGE"] = "en"
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO"]
        app.launch()
        app.activate()
        XCTAssertTrue(element("app.shell").waitForExistence(timeout: 10))
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(app.buttons["conversation.session.disk:beta"].waitForExistence(timeout: 15))
    }

    override func tearDownWithError() throws {
        if let app, app.state != .notRunning {
            app.terminate()
            _ = app.wait(for: .notRunning, timeout: 8)
        }
        app = nil
        if let fixtureRoot { try? FileManager.default.removeItem(at: fixtureRoot) }
        fixtureRoot = nil
    }

    func testFullTextSearchReportsTgrepAndKeyboardOpensSelectedResult() {
        openSearch(query: "nimbusneedle")
        let engine = element("search.performance.engine")
        XCTAssertTrue(waitUntil { self.text(engine) == "tgrep" }, "The packaged tgrep bridge must execute the query")
        XCTAssertTrue(element("search.performance.duration").waitForExistence(timeout: 10))
        XCTAssertTrue(text(element("search.performance.duration")).contains("ms"))
        XCTAssertTrue(element("conversation.search.result.1").waitForExistence(timeout: 10))
        XCTAssertFalse(element("conversation.search.result.2").exists, "Only message bodies containing the exact query match")

        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.upArrow, modifierFlags: [])
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(element("conversation.search.palette").waitForNonExistence(timeout: 5))
        XCTAssertTrue(element("conversation.message.1").waitForExistence(timeout: 10))
        let alpha = app.buttons["conversation.session.disk:alpha"]
        XCTAssertTrue(alpha.isSelected, "Return should open Alpha, the second result selected with arrow keys")
        XCTAssertTrue(app.staticTexts["Alpha architecture"].exists)
    }

    func testLocalSemanticRankingPreservesResultsAndExplainsComputePolicy() {
        openSearch(query: "nimbusneedle")
        XCTAssertTrue(element("conversation.search.result.1").waitForExistence(timeout: 10))
        let toggle = element("search.semantic.toggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let previousValue = String(describing: toggle.value)
        toggle.click()
        XCTAssertTrue(waitUntil { String(describing: toggle.value) != previousValue }, "The switch must expose its changed state")

        // Opening diagnostics after inference settled verifies the real model or its explicit
        // graceful fallback. The lexical result set must remain intact in both cases.
        let details = app.buttons["search.performance.details"]
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        details.click()
        XCTAssertTrue(element("search.performance.popover").waitForExistence(timeout: 5))
        XCTAssertTrue(element("search.semantic.status").waitForExistence(timeout: 45))
        XCTAssertFalse(text(element("search.semantic.status")).isEmpty)
        keepScreenshot("native-search-local-compute")
        app.typeKey(.escape, modifierFlags: [])
        if !element("conversation.search.palette").exists { openSearch(query: nil) }
        XCTAssertTrue(element("conversation.search.result.0").exists)
        XCTAssertTrue(element("conversation.search.result.1").exists)
        XCTAssertFalse(element("conversation.search.result.2").exists)
    }

    func testSearchCanReachEveryMatchInALargeResultSet() throws {
        let project = fixtureRoot.appendingPathComponent("history/projects/experience", isDirectory: true)
        for index in 0..<96 {
            let suffix = String(format: "%03d", index)
            try writeSession("bulk-\(suffix)", title: "Bulk session \(suffix)", day: 1,
                             answer: "deepcatalogneedle is present in the complete result set.", to: project)
        }
        let refresh = app.buttons["conversation.library.refresh"]
        XCTAssertTrue(waitUntil { refresh.isEnabled })
        refresh.click()
        XCTAssertTrue(waitUntil(timeout: 20) { self.text(self.element("conversation.list.count")) == "99 sessions" })
        openSearch(query: "deepcatalogneedle")
        XCTAssertTrue(element("conversation.search.result.0").waitForExistence(timeout: 15))
        for _ in 0..<12 { app.typeKey(.pageDown, modifierFlags: []) }
        let last = element("conversation.search.result.95")
        XCTAssertTrue(last.waitForExistence(timeout: 10), "A large result set must not be silently capped at 80")
        XCTAssertTrue(last.isSelected)
        XCTAssertTrue(last.isHittable)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(element("conversation.message.1").waitForExistence(timeout: 10))
        XCTAssertEqual(text(element("conversation.title")), "Bulk session 095")
    }

    func testFocusReadingRestoresCustomLayoutAndFindsWithinTranscript() {
        app.buttons["conversation.session.disk:beta"].click()
        XCTAssertTrue(element("conversation.message.1").waitForExistence(timeout: 10))
        let stream = element("conversation.list")
        let originalWidth = stream.frame.width
        app.buttons["layout.toggle.stream"].click()
        XCTAssertTrue(stream.waitForNonExistence(timeout: 5))

        app.typeKey("s", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.buttons["layout.focus.exit"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["conversation.library.all"].exists)
        XCTAssertFalse(stream.exists)
        XCTAssertFalse(element("conversation.overview").exists)
        app.typeKey("s", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.buttons["conversation.library.all"].waitForExistence(timeout: 5))
        XCTAssertFalse(stream.exists, "Focus must restore the previously hidden stream")
        app.buttons["layout.toggle.stream"].click()
        XCTAssertTrue(stream.waitForExistence(timeout: 5))
        XCTAssertEqual(stream.frame.width, originalWidth, accuracy: 1)

        app.typeKey("f", modifierFlags: .command)
        app.typeText("nimbusneedle")
        let search = app.textFields["conversation.detail.search"]
        XCTAssertEqual(search.value as? String, "nimbusneedle")
        let matchCount = element("conversation.detail.search.count")
        XCTAssertTrue(waitUntil { self.text(matchCount).contains("1/1") })
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["conversation.jump.latest"].isHittable)
        app.buttons["conversation.jump.latest"].click()
    }

    func testDestinationShortcutsAndSearchRoundTrip() {
        XCTAssertTrue(app.menuBars.menuBarItems["Sessions"].exists,
                      "Scene commands must use the app's English locale even on a Chinese system")
        XCTAssertTrue(app.menuBars.menuBarItems["Go"].exists)
        let destinations = [
            ("2", "view.timeline"), ("3", "view.providers"), ("4", "view.monitor"),
            ("5", "view.skills"), ("6", "view.plugins"), ("1", "conversations.view"),
        ]
        for (key, identifier) in destinations {
            app.typeKey(XCUIKeyboardKey(rawValue: key), modifierFlags: .command)
            XCTAssertTrue(element(identifier).waitForExistence(timeout: 10), identifier)
        }
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(element("conversation.search.palette").waitForExistence(timeout: 5))
        XCTAssertTrue(element("conversation.search.result.0").waitForExistence(timeout: 5), "Empty search offers recent conversations")
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(element("conversation.search.palette").waitForNonExistence(timeout: 5))
    }

    func testCommandKClaimsTypingFromDetailSearchAndEscapeRestoresInsertionPoint() {
        app.buttons["conversation.session.disk:beta"].click()
        XCTAssertTrue(element("conversation.message.1").waitForExistence(timeout: 10))
        let detail = app.textFields["conversation.detail.search"]

        for focusedLayout in [false, true] {
            if focusedLayout {
                app.typeKey("s", modifierFlags: [.command, .shift])
                XCTAssertTrue(app.buttons["layout.focus.exit"].waitForExistence(timeout: 5))
            }
            app.typeKey("f", modifierFlags: .command)
            app.typeKey("a", modifierFlags: .command)
            app.typeText("nimbusneedle")
            XCTAssertEqual(detail.value as? String, "nimbusneedle")

            app.typeKey("k", modifierFlags: .command)
            let paletteField = app.textFields["conversation.search.palette.field"]
            XCTAssertTrue(paletteField.waitForExistence(timeout: 5))
            // No click, Tab, or explicit field targeting: Cmd-K itself must own typing.
            app.typeText(focusedLayout ? "implementation" : "architecture")
            XCTAssertEqual(paletteField.value as? String, focusedLayout ? "implementation" : "architecture")
            XCTAssertFalse(detail.exists, "VoiceOver must not reach the covered reader while search is modal")

            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(element("conversation.search.palette").waitForNonExistence(timeout: 5))
            XCTAssertEqual(detail.value as? String, "nimbusneedle", "The covered reader must not receive palette typing")
            app.typeText("x")
            XCTAssertEqual(detail.value as? String, "nimbusneedlex", "Escape restores the prior field and caret, not a selected-all replacement")
        }
    }

    func testModalSearchOwnsFindShortcutAndTabCannotEditTheCoveredReader() {
        app.buttons["conversation.session.disk:beta"].click()
        XCTAssertTrue(element("conversation.message.1").waitForExistence(timeout: 10))
        app.typeKey("f", modifierFlags: .command)
        app.typeText("nimbusneedle")
        let detail = app.textFields["conversation.detail.search"]
        XCTAssertEqual(detail.value as? String, "nimbusneedle")

        openSearch(query: "implementation")
        app.typeKey("f", modifierFlags: .command)
        app.typeText("architecture")
        let paletteField = app.textFields["conversation.search.palette.field"]
        XCTAssertEqual(paletteField.value as? String, "architecture", "Find belongs to the visible search task")
        XCTAssertFalse(detail.exists)
        XCTAssertFalse(app.buttons["conversation.library.all"].exists)

        // A keyboard user can move among palette controls, but not the disabled background.
        for _ in 0..<8 { app.typeKey(.tab, modifierFlags: []) }
        app.typeText("modaltyping")
        XCTAssertTrue(element("conversation.search.palette").exists)
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(element("conversation.search.palette").waitForNonExistence(timeout: 5))
        XCTAssertEqual(detail.value as? String, "nimbusneedle")
        app.typeText("x")
        XCTAssertEqual(detail.value as? String, "nimbusneedlex", "Cmd-K toggle also restores the original caret")
    }

    func testLightDarkAndCompactSearchScreenshots() {
        app.buttons["conversation.session.disk:beta"].click()
        XCTAssertTrue(element("conversation.message.1").waitForExistence(timeout: 10))
        let title = element("conversation.title")
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(title.frame.width, 80, "Header actions must not squeeze the session title away")
        let overview = element("conversation.overview")
        if overview.exists {
            let project = element("conversation.overview.value.2")
            XCTAssertTrue(project.exists)
            XCTAssertTrue(overview.frame.insetBy(dx: -1, dy: -1).contains(project.frame), "Long paths must stay inside the inspector")
        }
        keepScreenshot("native-workbench-first-appearance")
        app.buttons["sidebar.theme"].click()
        keepScreenshot("native-workbench-alternate-appearance")

        let window = app.windows.firstMatch
        if window.frame.width < 1_000 || window.frame.height < 680 {
            // Even a previously compact window must exercise an actual resize in this test.
            window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
                .withOffset(CGVector(dx: -2, dy: -2))
                .press(forDuration: 0.2, thenDragTo:
                    window.coordinate(withNormalizedOffset: .zero)
                        .withOffset(CGVector(dx: 1_100, dy: 740)))
            XCTAssertTrue(waitUntil { window.frame.width >= 1_080 && window.frame.height >= 720 })
        }
        let original = window.frame
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -2, dy: -2))
        let compact = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 940, dy: 620))
        corner.press(forDuration: 0.2, thenDragTo: compact)
        XCTAssertTrue(waitUntil {
            abs(window.frame.width - 940) <= 8 && abs(window.frame.height - 620) <= 8
        }, "Compact layout must really run at the app's 940 × 620 minimum, not an unchanged wide window")
        XCTAssertLessThan(window.frame.width, original.width - 20)
        XCTAssertLessThan(window.frame.height, original.height - 20)
        openSearch(query: "nimbusneedle")
        let field = app.textFields["conversation.search.palette.field"]
        let footer = element("search.semantic.toggle")
        let first = element("conversation.search.result.0")
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        for control in [field, footer, first] {
            XCTAssertTrue(control.isHittable)
            XCTAssertTrue(window.frame.insetBy(dx: -1, dy: -1).contains(control.frame), "Search controls must fit in the window")
        }
        keepScreenshot("native-compact-search")
    }

    private func openSearch(query: String?) {
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(element("conversation.search.palette").waitForExistence(timeout: 5))
        let field = app.textFields["conversation.search.palette.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        if let query {
            app.typeKey("a", modifierFlags: .command)
            app.typeText(query)
            XCTAssertEqual(field.value as? String, query, "Cmd-K must focus search without clicking its field")
        }
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func text(_ element: XCUIElement) -> String {
        (element.value as? String) ?? element.label
    }

    private func waitUntil(timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func keepScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func writeSession(_ id: String, title: String, day: Int, answer: String, to project: URL) throws {
        let timestamp = String(format: "2026-01-%02dT12:00:00.000Z", day)
        let lines = [
            #"{"type":"user","uuid":"\#(id)-user","timestamp":"\#(timestamp)","sessionId":"\#(id)","cwd":"/workspace/native-experience","message":{"role":"user","content":"Discuss this approach."},"__ccbud__":{"title":"\#(title)"}}"#,
            #"{"type":"assistant","uuid":"\#(id)-assistant","timestamp":"\#(timestamp)","sessionId":"\#(id)","message":{"id":"\#(id)-response","role":"assistant","model":"local-fixture","content":[{"type":"text","text":"\#(answer)"}],"usage":{"input_tokens":12,"output_tokens":8}}}"#,
        ]
        let file = project.appendingPathComponent("\(id).jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        // Catalog recency follows file activity, so explicitly fix file dates as well as JSON.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = try XCTUnwrap(formatter.date(from: timestamp))
        try FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: file.path)
    }
}
