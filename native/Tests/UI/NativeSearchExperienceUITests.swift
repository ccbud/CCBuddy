import AppKit
import XCTest

/// Exercises the production search bridge and local model inside a disposable app home.
/// No provider is started and the UI-testing runtime never changes the user's CLI configuration.
final class NativeSearchExperienceUITests: XCTestCase {
    private var app: XCUIApplication!
    private var fixtureRoot: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        fixtureRoot = try UITestFixtureDirectory.make(named: "native-experience")
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
        XCTAssertTrue(waitUntil {
            self.element("conversation.search.result.0").value as? String == "2 matches"
                && self.element("conversation.search.result.1").value as? String == "1 match"
        }, "Finished results must expose exact occurrence totals, not a first-match lower bound")

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

    func testUnavailableSearchCacheExplainsFallbackAndStillFindsChineseText() throws {
        // Fail the real persistent-cache initialization without a test-only engine switch.
        // This reproduces an unavailable cache, not actual disk exhaustion on the CI host.
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 8))
        let cache = fixtureRoot.appendingPathComponent("app-home/conversation-catalog-v1/tgrep-groups-v1")
        // The test app may already have created this disposable index. Replace only
        // this test's cache after termination; its source history and file catalog remain.
        if FileManager.default.fileExists(atPath: cache.path) {
            try FileManager.default.removeItem(at: cache)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        try Data("fixture blocks cache directory creation".utf8).write(to: cache, options: .withoutOverwriting)
        let project = fixtureRoot.appendingPathComponent("history/projects/experience")
        // Require fallback to scan a genuinely long transcript before a hit beyond the
        // old per-message cutoff. Long message tails must not disappear from global search.
        var contents = Data()
        for turn in 0..<600 {
            contents.append(try liveTurn(turn, answerOverride:
                String(repeating: "Ordinary text before the exact match. ", count: 50)))
        }
        contents.append(try liveTurn(600, answerOverride:
            String(repeating: "Long message context. ", count: 4_000)
                + "系统代理 " + String(repeating: "Separate context. ", count: 40)
                + "当前版本 remains searchable."))
        try contents.write(to: project.appendingPathComponent("live-anchor.jsonl"))
        app.launch()
        app.activate()
        XCTAssertTrue(element("app.shell").waitForExistence(timeout: 10))
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(app.buttons["conversation.session.disk:live-anchor"].waitForExistence(timeout: 20))

        openSearch(query: nil)
        let searchField = app.textFields["conversation.search.palette.field"]
        pasteReplacingFocusedText("系统代理", in: searchField)
        XCTAssertTrue(element("conversation.search.result.0").waitForExistence(timeout: 15))
        XCTAssertTrue(element("search.performance.fallback").waitForExistence(timeout: 5),
                      "A failed accelerator must not silently appear to be healthy local search")
        XCTAssertFalse(element("conversation.search.result.1").exists)
        pasteReplacingFocusedText("当前版本", in: searchField)
        XCTAssertEqual(searchField.value as? String, "当前版本")
        XCTAssertTrue(waitUntil(timeout: 15) {
            self.element("conversation.search.result.0").label.contains("当前版本")
        }, "The replacement query must publish its own snippet, not leave the stale result visible")
        app.buttons["search.performance.details"].click()
        XCTAssertTrue(element("search.performance.fallback.reason").waitForExistence(timeout: 5))
        XCTAssertFalse(text(element("search.performance.fallback.reason")).isEmpty)
        keepScreenshot("native-search-explicit-cache-fallback")
    }

    func testGlobalSearchFindsFragmentBeyondOldSingleMessageLimit() throws {
        let project = fixtureRoot.appendingPathComponent("history/projects/experience")
        let fragment = "singlemessagetailneedle"
        try writeSession("long-single", title: "Complete long message", day: 4,
            answer: String(repeating: "Ordinary content before the searchable tail. ", count: 4_000)
                + fragment + " — 系统代理 — 当前版本", to: project)
        let refresh = app.buttons["conversation.library.refresh"]
        XCTAssertTrue(waitUntil { refresh.isEnabled })
        refresh.click()
        XCTAssertTrue(app.buttons["conversation.session.disk:long-single"].waitForExistence(timeout: 20))
        openSearch(query: fragment)
        let hit = element("conversation.search.result.0")
        XCTAssertTrue(waitUntil(timeout: 15) {
            hit.exists && hit.label.contains(fragment) && hit.value as? String == "1 match"
        }, "An exact fragment after 160 KB must be searchable and have a complete count")
        XCTAssertFalse(element("conversation.search.result.1").exists)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(element("conversation.search.palette").waitForNonExistence(timeout: 5))
        XCTAssertTrue(waitUntil {
            self.text(self.element("conversation.title")) == "Complete long message"
        })
        let detailField = app.textFields["conversation.detail.search"]
        XCTAssertTrue(detailField.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil { detailField.isEnabled && detailField.isHittable })
        detailField.click()
        pasteReplacingFocusedText(fragment, in: detailField)
        XCTAssertTrue(waitUntil(timeout: 15) {
            self.text(self.element("conversation.detail.search.count")).contains("1/1")
        })
        app.buttons["conversation.session.disk:beta"].click()
        XCTAssertTrue(waitUntil {
            self.text(self.element("conversation.title")) == "Beta implementation"
        })
    }

    func testGlobalSearchOpensPairedToolResultTailAtVisibleOwner() throws {
        let file = fixtureRoot.appendingPathComponent("history/projects/experience/live-anchor.jsonl")
        let fragment = "pairedtooltailneedle"
        let ownerIndex = 1_200
        var contents = Data()
        for turn in 0..<(ownerIndex / 2) {
            contents.append(try liveTurn(turn, answerOverride: "Ordinary prelude answer \(turn)."))
        }
        // Eight long lines keep the rendered tail within the tool card's viewport while
        // placing its only match beyond 160 KiB. Neither the input nor an earlier message
        // contains the query. Global search must therefore anchor to the hidden result.
        let prefixLine = String(repeating: "ordinary-output-", count: 1_400)
        let output = Array(repeating: prefixLine, count: 8).joined(separator: "\n")
            + "\n" + fragment + ": complete paired output tail."
        let tailRange = try XCTUnwrap(output.range(of: fragment))
        XCTAssertGreaterThan(tailRange.lowerBound.utf16Offset(in: output), 160 * 1_024)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let records: [[String: Any]] = [
            ["type": "assistant", "uuid": "paired-owner", "timestamp": timestamp,
             "sessionId": "live-anchor",
             "message": ["id": "paired-owner-response", "role": "assistant", "model": "local-fixture",
                         "content": [["type": "tool_use", "id": "paired-tail-tool", "name": "Bash",
                                      "input": ["command": "printf 'fixture output'"]]]]],
            ["type": "user", "uuid": "paired-result", "timestamp": timestamp,
             "sessionId": "live-anchor",
             "message": ["role": "user", "content": [["type": "tool_result",
                         "tool_use_id": "paired-tail-tool", "content": output]]]],
            ["type": "assistant", "uuid": "paired-finished", "timestamp": timestamp,
             "sessionId": "live-anchor",
             "message": ["id": "paired-finished-response", "role": "assistant", "model": "local-fixture",
                         "content": [["type": "text", "text": "Finished reading the tool output."]]]],
        ]
        for record in records {
            contents.append(try JSONSerialization.data(withJSONObject: record, options: .sortedKeys))
            contents.append(0x0a)
        }
        try contents.write(to: file)
        let refresh = app.buttons["conversation.library.refresh"]
        XCTAssertTrue(waitUntil { refresh.isEnabled })
        refresh.click()
        XCTAssertTrue(app.buttons["conversation.session.disk:live-anchor"].waitForExistence(timeout: 20))

        openSearch(query: fragment)
        let hit = element("conversation.search.result.0")
        XCTAssertTrue(waitUntil(timeout: 15) {
            hit.exists && hit.label.contains(fragment) && hit.value as? String == "1 match"
        }, "Only the hidden paired result's long tail contains the exact query")
        XCTAssertFalse(element("conversation.search.result.1").exists)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(element("conversation.search.palette").waitForNonExistence(timeout: 5))
        let owner = element("conversation.message.\(ownerIndex)")
        XCTAssertTrue(waitUntil(timeout: 20) { owner.exists && owner.isHittable },
                      "Opening the global result must jump directly to its visible tool owner, not message 0")
        XCTAssertFalse(element("conversation.message.\(ownerIndex + 1)").exists,
                       "A paired tool result has no independent timeline row to scroll to")
        XCTAssertEqual(app.textFields["conversation.detail.search"].value as? String, "",
                       "This regression must be satisfied by the global anchor without a manual detail search")

        let disclosure = app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@ AND value == %@", "Result", "已折叠")).firstMatch
        XCTAssertTrue(waitUntil { disclosure.exists && disclosure.isHittable },
                      "The collapsed result disclosure must be reachable at the anchored owner")
        disclosure.click()
        let preparedOutput = app.descendants(matching: .staticText).matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", fragment, fragment)).firstMatch
        XCTAssertTrue(waitUntil(timeout: 15) { preparedOutput.exists && preparedOutput.isHittable },
                      "Expanding the visible tool must render the exact output tail without another search")
        XCTAssertEqual(app.textFields["conversation.detail.search"].value as? String, "")
        keepScreenshot("native-global-search-paired-result-owner")
    }

    func testTwelveThousandMessageTranscriptCanFindItsTailAndReturnToSmallSession() throws {
        let file = fixtureRoot.appendingPathComponent("history/projects/experience/live-anchor.jsonl")
        var contents = Data()
        for turn in 0..<6_000 {
            contents.append(try liveTurn(turn, answerOverride: turn == 5_999
                ? "系统代理 — 当前版本 — final searchable answer." : nil))
        }
        try contents.write(to: file)
        let refresh = app.buttons["conversation.library.refresh"]
        XCTAssertTrue(waitUntil { refresh.isEnabled })
        refresh.click()
        let large = app.buttons["conversation.session.disk:live-anchor"]
        XCTAssertTrue(large.waitForExistence(timeout: 30))
        large.click()
        let statistics = element("conversation.statistics")
        XCTAssertTrue(waitUntil(timeout: 20) { statistics.label.contains("12000 messages") },
                      "The real parser and reader must publish all 12,000 messages")
        // Keyboard focus/shortcut ownership has separate tests. This case verifies
        // the large-document parser, exact search, tail navigation, and session switch.
        let detailField = app.textFields["conversation.detail.search"]
        XCTAssertTrue(detailField.waitForExistence(timeout: 5))
        detailField.click()
        pasteReplacingFocusedText("系统代理", in: detailField)
        pasteReplacingFocusedText("当前版本", in: detailField)
        XCTAssertEqual(detailField.value as? String, "当前版本")
        XCTAssertTrue(waitUntil(timeout: 15) {
            self.text(self.element("conversation.detail.search.count")).contains("1/1")
        })
        let tail = element("conversation.message.11999")
        XCTAssertTrue(waitUntil(timeout: 15) { tail.exists && tail.isHittable },
                      "The exact tail hit must be reachable without materializing every earlier row")
        // SwiftUI can propagate the row identifier to several leaf AX elements rather
        // than expose one parent container. Match the unique fixture prose directly.
        let preparedTail = app.descendants(matching: .staticText)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
                                  "final searchable answer.", "final searchable answer.")).firstMatch
        XCTAssertTrue(preparedTail.waitForExistence(timeout: 10),
                      "A visible message shell is insufficient: its asynchronous prose must finish preparing")
        XCTAssertTrue(tail.isHittable,
                      "The searched tail must remain visible after its prose replaces the loading placeholder")
        app.buttons["conversation.session.disk:beta"].click()
        XCTAssertTrue(waitUntil(timeout: 8) { self.text(self.element("conversation.title")) == "Beta implementation" })
        XCTAssertTrue(element("conversation.message.1").waitForExistence(timeout: 8))
        XCTAssertEqual(app.textFields["conversation.detail.search"].value as? String, "",
                       "A completed or cancelled large search must not leak into the next session")
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

    func testLiveSearchAnchorSurvivesAppendsUntilLatestResumesFollowing() throws {
        let file = fixtureRoot.appendingPathComponent("history/projects/experience/live-anchor.jsonl")
        var initial = Data()
        for turn in 0..<30 { initial.append(try liveTurn(turn)) }
        try initial.write(to: file)
        let refresh = app.buttons["conversation.library.refresh"]
        XCTAssertTrue(waitUntil { refresh.isEnabled })
        refresh.click()
        XCTAssertTrue(app.buttons["conversation.session.disk:live-anchor"].waitForExistence(timeout: 20))

        openSearch(query: "anchorstayneedle")
        XCTAssertTrue(element("conversation.search.result.0").waitForExistence(timeout: 15))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(element("conversation.search.palette").waitForNonExistence(timeout: 5))
        XCTAssertTrue(waitUntil { self.text(self.element("conversation.title")) == "Live anchor fixture" })
        let firstHit = element("conversation.message.1")
        let viewport = element("conversation.timeline.scroll")
        func visible(_ message: XCUIElement) -> Bool {
            message.exists && message.isHittable && viewport.frame.intersects(message.frame)
        }
        XCTAssertTrue(waitUntil { visible(firstHit) }, "Opening a live search result must honor its early message anchor")
        XCTAssertFalse(visible(element("conversation.message.59")))

        let statistics = element("conversation.statistics")
        XCTAssertTrue(statistics.waitForExistence(timeout: 5))
        XCTAssertTrue(statistics.label.contains("60 messages"),
                      "The visible exact statistics must also have a readable accessibility label")
        try appendLiveTurn(30, to: file)
        XCTAssertTrue(waitUntil(timeout: 20) { statistics.label.contains("62 messages") },
                      "Wait for the real live-file refresh, not an arbitrary delay")
        let movedAway = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !visible(firstHit) }, object: nil)
        movedAway.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [movedAway], timeout: 2), .completed,
                       "Appending live turns must not take the reader away from a search hit")
        keepScreenshot("native-live-search-anchor")

        app.buttons["conversation.jump.latest"].click()
        XCTAssertTrue(waitUntil { visible(self.element("conversation.message.61")) })
        XCTAssertFalse(visible(firstHit))
        keepScreenshot("native-live-latest-footer-clearance")
        try appendLiveTurn(31, to: file)
        XCTAssertTrue(waitUntil(timeout: 20) {
            statistics.label.contains("64 messages") && visible(self.element("conversation.message.63"))
        }, "Latest explicitly resumes following subsequent live turns")
        keepScreenshot("native-live-latest-following")
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
            XCTAssertFalse(app.buttons["layout.focus.exit"].exists, "Every covered overlay must join the modal accessibility boundary")

            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(element("conversation.search.palette").waitForNonExistence(timeout: 5))
            if focusedLayout { XCTAssertTrue(app.buttons["layout.focus.exit"].waitForExistence(timeout: 5)) }
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
        let original = window.frame
        // The CI desktop constrains a fresh window to 1024 × 674. That already has enough
        // room for a real two-axis shrink; demanding 1100 × 740 first exceeds that display.
        XCTAssertGreaterThan(original.width, 968, "The fresh window must allow a measurable width reduction: \(original)")
        XCTAssertGreaterThan(original.height, 648, "The fresh window must allow a measurable height reduction: \(original)")
        // Drag straight-edge midpoints independently. A point two pixels inside the rounded
        // bottom-right corner can be outside the actual window and never start live resizing.
        let rightEdge = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: -1, dy: 0))
        rightEdge.press(forDuration: 0.2, thenDragTo:
            window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
                .withOffset(CGVector(dx: 939, dy: 0)))
        XCTAssertTrue(waitUntil { abs(window.frame.width - 940) <= 8 },
                      "Dragging the right edge must resize the window: \(window.frame)")
        let bottomEdge = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1))
            .withOffset(CGVector(dx: 0, dy: -1))
        bottomEdge.press(forDuration: 0.2, thenDragTo:
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
                .withOffset(CGVector(dx: 0, dy: 619)))
        XCTAssertTrue(waitUntil {
            abs(window.frame.width - 940) <= 8 && abs(window.frame.height - 620) <= 8
        }, "Compact layout must really run at the app's 940 × 620 minimum: \(window.frame)")
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

    private func liveTurn(_ index: Int, answerOverride: String? = nil) throws -> Data {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let answer = answerOverride ?? (index == 0 ? "anchorstayneedle: Keep reading this early answer."
            : "Live tail \(index). " + String(repeating:
                "Streaming updates should never move a reader away from a deliberate search position. ", count: 6))
        let records: [[String: Any]] = [
            ["type": "user", "uuid": "live-user-\(index)", "timestamp": timestamp,
             "sessionId": "live-anchor", "cwd": "/workspace/native-experience",
             "message": ["role": "user", "content": "Live turn \(index)"],
             "__ccbud__": ["title": "Live anchor fixture"]],
            ["type": "assistant", "uuid": "live-assistant-\(index)", "timestamp": timestamp,
             "sessionId": "live-anchor",
             "message": ["id": "live-response-\(index)", "role": "assistant", "model": "local-fixture",
                         "content": [["type": "text", "text": answer]],
                         "usage": ["input_tokens": 12, "output_tokens": 8]]],
        ]
        var data = Data()
        for record in records {
            data.append(try JSONSerialization.data(withJSONObject: record, options: .sortedKeys))
            data.append(0x0a)
        }
        return data
    }

    private func appendLiveTurn(_ index: Int, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: liveTurn(index))
    }

    private func pasteReplacingFocusedText(
        _ value: String,
        in field: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(field.waitForExistence(timeout: 5), file: file, line: line)
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        defer {
            pasteboard.clearContents()
            let items = saved.map { entries in
                let item = NSPasteboardItem()
                for (type, data) in entries { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { pasteboard.writeObjects(items) }
        }
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        app.typeKey("a", modifierFlags: .command)
        app.typeKey("v", modifierFlags: .command)
        // Event synthesis can return before the field editor consumes the pasteboard.
        // Keep these bytes available until the actual target acknowledges the edit.
        XCTAssertTrue(waitUntil(timeout: 10) { field.value as? String == value },
                      "The target field must consume the requested pasted text before restoring the clipboard",
                      file: file, line: line)
    }
}
