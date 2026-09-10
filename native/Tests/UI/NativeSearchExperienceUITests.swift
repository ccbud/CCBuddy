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

    func testVisibleProgressiveRowsUpdateEveryFinalCountWithoutRemountingPalette() throws {
        let project = fixtureRoot.appendingPathComponent("history/projects/experience", isDirectory: true)
        let query = "visiblecountneedle"
        // Real production counting, not an injected delay: all three sources match immediately
        // and each has a slow full count. One slow source followed by tiny sources can coalesce
        // every final update into one UI transaction and fail to exercise mounted-row refresh.
        try writeSession("count-slow", title: "Slow exact count", day: 6,
            answer: String(repeating: query + " ", count: 1_000_000), to: project)
        try writeSession("count-middle", title: "Second slow exact count", day: 5,
            answer: String(repeating: query + " ", count: 1_000_001), to: project)
        try writeSession("count-last", title: "Third slow exact count", day: 4,
            answer: String(repeating: query + " ", count: 1_000_002), to: project)
        let refresh = app.buttons["conversation.library.refresh"]
        XCTAssertTrue(waitUntil { refresh.isEnabled })
        refresh.click()
        XCTAssertTrue(waitUntil(timeout: 20) {
            self.text(self.element("conversation.list.count")) == "6 sessions"
                && !self.element("conversation.indexing.progress").exists && refresh.isEnabled
        }, "The immutable fixtures must finish catalog publication before the measured search")
        XCTAssertFalse(element("conversation.indexing.incomplete").exists)
        XCTAssertFalse(element("conversation.indexing.failure").exists)

        openSearch(query: nil)
        pasteReplacingFocusedText(query, in: app.textFields["conversation.search.palette.field"])
        let rows = (0..<3).map { element("conversation.search.result.\($0)") }
        let lowerBounds = Array(repeating: "At least 1 match", count: 3)
        let expected = ["1000000 matches", "1000001 matches", "1000002 matches"]
        var sawInitial = false
        var sawMiddle = false
        var sawFinal = false
        var originalFrames: [CGRect]?
        var observed: [[String]] = []
        // Do not dismiss/reopen, scroll, or change selection: any of those can recreate a lazy
        // row and hide the stale captured-input defect. One shared deadline preserves the 15s
        // query budget. NSPredicate's coarser polling can miss the real split-completion window;
        // the test process only pumps its own run loop, without delaying the production worker.
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            if rows.allSatisfy({ $0.exists && $0.isHittable }) {
                let values = rows.map { $0.value as? String ?? "" }
                if observed.last != values { observed.append(values) }
                if values == lowerBounds {
                    sawInitial = true
                    if originalFrames == nil { originalFrames = rows.map(\.frame) }
                }
                if sawInitial, values == [expected[0], lowerBounds[1], lowerBounds[2]] {
                    sawMiddle = true
                }
                if values == expected {
                    sawFinal = true
                    break
                }
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.025))
        }
        XCTAssertTrue(sawInitial, "Three mounted rows must first show real lower bounds: \(observed)")
        XCTAssertTrue(sawMiddle, "The first count must finish while both trailing rows are still lower bounds: \(observed)")
        XCTAssertTrue(sawFinal, "Every same mounted row must reach its exact count within 15s: \(observed)")
        let frames = try XCTUnwrap(originalFrames)
        XCTAssertTrue(element("conversation.search.palette").exists)
        XCTAssertFalse(element("conversation.search.partial.error").exists)
        for (row, frame) in zip(rows, frames) {
            // The activity line can disappear and move the whole result region. Relative
            // positions must stay fixed; requiring its old absolute Y would test that banner.
            XCTAssertEqual(row.frame.minY - rows[0].frame.minY,
                frame.minY - frames[0].minY, accuracy: 1, "A count update must not change row order")
        }
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
        let clearFilter = app.buttons["conversation.list.filter.clear"]
        XCTAssertTrue(waitUntil {
            clearFilter.exists && clearFilter.isEnabled && clearFilter.isHittable
        })
        clearFilter.click()
        let beta = app.buttons["conversation.session.disk:beta"]
        XCTAssertTrue(waitUntil {
            beta.exists && beta.isEnabled && beta.isHittable
        })
        beta.click()
        XCTAssertTrue(waitUntil {
            self.text(self.element("conversation.title")) == "Beta implementation"
        })
    }

    func testGlobalSearchOpensPairedToolResultTailAtVisibleOwner() throws {
        let file = fixtureRoot.appendingPathComponent("history/projects/experience/live-anchor.jsonl")
        let fragment = "pairedtooltailneedle"
        let ownerIndex = 1_200
        var contents = Data()
        for turn in 0..<((ownerIndex - 20) / 2) {
            contents.append(try liveTurn(turn, answerOverride: "Ordinary prelude answer \(turn)."))
        }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        // The last twenty messages have very different placeholder/final heights. These
        // are real asynchronous Markdown and lazy tool-input views, not delayed test doubles.
        for index in (ownerIndex - 20)..<ownerIndex {
            let block: [String: Any]
            if index.isMultiple(of: 2) {
                let paragraphs = (0..<14).map { paragraph in
                    "Reading neighbor \(index) paragraph \(paragraph). **Prepared Markdown** changes the lazy row height. "
                        + "Keep the explicit search destination steady while this readable context is laid out."
                }.joined(separator: "\n\n")
                block = ["type": "text", "text": "## Neighbor \(index)\n\n" + paragraphs]
            } else {
                let command = (0..<8).map { "printf 'neighbor \(index) input line \($0)'" }.joined(separator: "\n")
                block = ["type": "tool_use", "id": "neighbor-tool-\(index)", "name": "Bash",
                         "input": ["command": command]]
            }
            let record: [String: Any] = ["type": "assistant", "uuid": "neighbor-\(index)",
                "timestamp": timestamp, "sessionId": "live-anchor",
                "message": ["id": "neighbor-response-\(index)", "role": "assistant", "model": "local-fixture",
                            "content": [block]]]
            contents.append(try JSONSerialization.data(withJSONObject: record, options: .sortedKeys))
            contents.append(0x0a)
        }
        // Eight long lines keep the rendered tail within the tool card's viewport while
        // placing its only match beyond 160 KiB. Neither the input nor an earlier message
        // contains the query. Global search must therefore anchor to the hidden result.
        let prefixLine = String(repeating: "ordinary-output-", count: 1_400)
        let output = Array(repeating: prefixLine, count: 8).joined(separator: "\n")
            + "\n" + fragment + ": complete paired output tail."
        let tailRange = try XCTUnwrap(output.range(of: fragment))
        XCTAssertGreaterThan(tailRange.lowerBound.utf16Offset(in: output), 160 * 1_024)
        let records: [[String: Any]] = [
            ["type": "assistant", "uuid": "paired-owner", "timestamp": timestamp,
             "sessionId": "live-anchor",
             "message": ["id": "paired-owner-response", "role": "assistant", "model": "local-fixture",
                         "content": [["type": "text", "text": "**Anchor owner prepared.**\n\nThe global result belongs to this tool card."],
                                     ["type": "tool_use", "id": "paired-tail-tool", "name": "Bash",
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
        let viewport = element("conversation.timeline.scroll")
        func ownerIsVisible() -> Bool {
            owner.exists && owner.isHittable && viewport.frame.intersects(owner.frame)
        }
        XCTAssertTrue(waitUntil(timeout: 20) { ownerIsVisible() },
                      "Opening the global result must jump directly to its visible tool owner, not message 0")
        let preparedOwner = app.descendants(matching: .staticText).matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", "Anchor owner prepared.", "Anchor owner prepared.")).firstMatch
        XCTAssertTrue(waitUntil(timeout: 15) {
            preparedOwner.exists && self.app.descendants(matching: .any)
                .matching(identifier: "conversation.message.preparing").allElementsBoundByIndex
                .allSatisfy { !$0.isHittable }
        }, "Wait for real visible prose preparation, not merely the first placeholder geometry")
        XCTAssertTrue(ownerIsVisible(), "Prepared neighbor/owner heights must not push the global destination offscreen")
        let drifted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !ownerIsVisible() }, object: nil)
        drifted.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [drifted], timeout: 2), .completed,
                       "The initial global anchor must remain visible through subsequent lazy layout transactions")
        XCTAssertFalse(element("conversation.message.\(ownerIndex + 1)").exists,
                       "A paired tool result has no independent timeline row to scroll to")
        XCTAssertEqual(app.textFields["conversation.detail.search"].value as? String, "",
                       "This regression must be satisfied by the global anchor without a manual detail search")

        let disclosure = app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@ AND value == %@", "Result", "collapsed")).firstMatch
        XCTAssertTrue(waitUntil { disclosure.exists && disclosure.isHittable },
                      "The collapsed result disclosure must be reachable at the anchored owner")
        disclosure.click()
        let preparedOutput = viewport.descendants(matching: .staticText)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", fragment, fragment)).firstMatch
        XCTAssertTrue(waitUntil(timeout: 15) { preparedOutput.exists && preparedOutput.isHittable },
                      "Expanding the visible tool must render the exact output tail without another search")
        XCTAssertEqual(text(preparedOutput), output,
                       "The code view must retain the complete output, including its exact tail offset")
        XCTAssertTrue(viewport.frame.intersects(preparedOutput.frame))
        XCTAssertTrue(app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@ AND value == %@", "Result", "expanded")).firstMatch.exists)
        XCTAssertEqual(app.textFields["conversation.detail.search"].value as? String, "")
        keepScreenshot("native-global-search-paired-result-owner")

        // A deliberate wheel scroll cancels the persistent layout correction. Changing the
        // reader width then forces actual Markdown reflow, which must not resurrect the jump.
        for _ in 0..<3 {
            if !ownerIsVisible() { break }
            viewport.scroll(byDeltaX: 0, deltaY: 600)
        }
        XCTAssertTrue(waitUntil { !ownerIsVisible() }, "Manual scrolling must be able to leave the search anchor")
        let previousWidth = viewport.frame.width
        app.buttons["layout.toggle.stream"].click()
        XCTAssertTrue(waitUntil { abs(viewport.frame.width - previousWidth) > 20 },
                      "The cancellation assertion must follow a real reader-width/layout change")
        let reclaimed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in ownerIsVisible() }, object: nil)
        reclaimed.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [reclaimed], timeout: 2), .completed,
                       "Layout changes after a user scroll must not pull the reader back to the old global hit")
        XCTAssertEqual(app.textFields["conversation.detail.search"].value as? String, "")
        keepScreenshot("native-global-search-user-scroll-cancels-anchor")
    }

    func testToolNotesTodosAndDiffSupportNativeTextSelectionCopy() throws {
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 8))
        // Keep this transcript and catalog separate from the three-session search fixture.
        let history = fixtureRoot.appendingPathComponent("tool-selection-history", isDirectory: true)
        let project = history.appendingPathComponent("projects/selection", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try writeToolSelectionSession(to: project)
        app.launchEnvironment["CCBUD_UI_HISTORY_DIR"] = history.path
        app.launchEnvironment["CCBUD_HOME"] = fixtureRoot.appendingPathComponent("selection-app-home").path
        app.launch()
        app.activate()
        XCTAssertTrue(element("app.shell").waitForExistence(timeout: 10))
        app.typeKey("1", modifierFlags: .command)
        let session = app.buttons["conversation.session.disk:select-copy"]
        XCTAssertTrue(waitUntil(timeout: 15) { session.exists && session.isEnabled && session.isHittable })
        session.click()
        XCTAssertTrue(waitUntil { self.text(self.element("conversation.title")) == "Tool text selection fixture" })
        let viewport = element("conversation.timeline.scroll")
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil { viewport.isHittable })
        viewport.scroll(byDeltaX: 0, deltaY: 1_000)

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
        let targets = [
            ("in notecopyneedle", "notecopyneedle"),
            ("todopendingcopyneedle", "todopendingcopyneedle"),
            ("todoworkingcopyneedle", "todoworkingcopyneedle"),
            ("tododonecopyneedle", "tododonecopyneedle"),
            ("- diffoldcopyneedle", "diffoldcopyneedle"),
            ("+ diffnewcopyneedle", "diffnewcopyneedle"),
        ]
        for (body, needle) in targets {
            // Match the rendered text itself inside the reader, not a flattened row/tool AX ID.
            let target = viewport.descendants(matching: .staticText)
                .matching(NSPredicate(format: "label == %@ OR value == %@", body, body)).firstMatch
            func targetIsVisible() -> Bool {
                target.exists && target.isHittable && viewport.frame.contains(
                    CGPoint(x: target.frame.minX + 32, y: target.frame.midY))
            }
            for _ in 0..<6 {
                if targetIsVisible() { break }
                viewport.scroll(byDeltaX: 0, deltaY: -120)
                if waitUntil(timeout: 1, { targetIsVisible() }) { break }
            }
            XCTAssertTrue(waitUntil { targetIsVisible() }, "The actual \(needle) body must be visible")
            XCTAssertEqual(text(target), body)
            XCTAssertGreaterThan(target.frame.width, 32)
            let sentinel = "not-copied-\(UUID().uuidString)"
            pasteboard.clearContents()
            XCTAssertTrue(pasteboard.setString(sentinel, forType: .string))
            XCTAssertEqual(pasteboard.string(forType: .string), sentinel)
            // Diff rows can expose their full-width frame. Double-click inside the alphabetic
            // word near its leading edge, not that frame's potentially empty horizontal center.
            target.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
                .withOffset(CGVector(dx: 32, dy: 0)).doubleClick()
            app.typeKey("c", modifierFlags: .command)
            XCTAssertTrue(waitUntil { pasteboard.string(forType: .string) == needle },
                          "Native selection and Command-C must copy exactly \(needle), not a stale clipboard or whole row")
        }
        keepScreenshot("native-tool-body-text-selection-copy")
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
        XCTAssertEqual(app.textFields.matching(identifier: "conversation.detail.search").count, 1,
                       "Responsive toolbar layout must keep one native field editor")
        detailField.click()
        pasteReplacingFocusedText("系统代理", in: detailField)
        pasteReplacingFocusedText("当前版本", in: detailField)
        XCTAssertEqual(detailField.value as? String, "当前版本")
        XCTAssertEqual(app.textFields.matching(identifier: "conversation.detail.search").count, 1)
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
        // A display-wide window has its right resize band outside the desktop. A point just
        // inside that edge hits the content instead (the CI event recording confirms this).
        // Move the real title bar left first, then grab the exposed native resize band.
        let titleBar = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
            .withOffset(CGVector(dx: 0, dy: 12))
        titleBar.press(forDuration: 0.2,
                       thenDragTo: titleBar.withOffset(CGVector(dx: -48, dy: 0)))
        XCTAssertTrue(waitUntil { window.frame.minX < original.minX - 24 },
                      "Expose the native resize edge by moving the window: \(window.frame)")
        XCTAssertEqual(window.frame.width, original.width, accuracy: 1)
        XCTAssertEqual(window.frame.height, original.height, accuracy: 1)
        let rightEdge = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: 1, dy: 0))
        let widthDelta = 940 - window.frame.width
        rightEdge.press(forDuration: 0.2, thenDragTo:
            rightEdge.withOffset(CGVector(dx: widthDelta, dy: 0)))
        XCTAssertTrue(waitUntil { abs(window.frame.width - 940) <= 8 },
                      "Dragging the right edge must resize the window: \(window.frame)")
        // Return the shrunken window fully onto the desktop before checking compact controls.
        let restoreTitleBar = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
            .withOffset(CGVector(dx: 0, dy: 12))
        let restoreOffset = original.minX - window.frame.minX
        restoreTitleBar.press(forDuration: 0.2,
                              thenDragTo: restoreTitleBar.withOffset(CGVector(dx: restoreOffset, dy: 0)))
        XCTAssertTrue(waitUntil { abs(window.frame.minX - original.minX) <= 8 },
                      "The compact window must be fully back on screen: \(window.frame)")
        let bottomEdge = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1))
            .withOffset(CGVector(dx: 0, dy: 1))
        let heightDelta = 620 - window.frame.height
        bottomEdge.press(forDuration: 0.2, thenDragTo:
            bottomEdge.withOffset(CGVector(dx: 0, dy: heightDelta)))
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

    private func writeToolSelectionSession(to project: URL) throws {
        let records: [[String: Any]] = [
            ["type": "user", "uuid": "selection-user", "timestamp": "2026-09-10T02:00:00.000Z",
             "sessionId": "select-copy", "cwd": "/workspace/tool-selection",
             "message": ["role": "user", "content": "Verify local tool text selection."],
             "__ccbud__": ["title": "Tool text selection fixture"]],
            ["type": "assistant", "uuid": "selection-assistant", "timestamp": "2026-09-10T02:00:01.000Z",
             "sessionId": "select-copy",
             "message": ["id": "selection-response", "role": "assistant", "model": "local-fixture",
                         "content": [
                            ["type": "tool_use", "id": "selection-note", "name": "Grep",
                             "input": ["pattern": "publicfixture", "path": "notecopyneedle"]],
                            ["type": "tool_use", "id": "selection-todos", "name": "TodoWrite",
                             "input": ["todos": [
                                ["content": "todopendingcopyneedle", "status": "pending"],
                                ["content": "todoworkingcopyneedle", "status": "in_progress"],
                                ["content": "tododonecopyneedle", "status": "completed"],
                             ]]],
                            ["type": "tool_use", "id": "selection-diff", "name": "Edit",
                             "input": ["file_path": "/workspace/public-selection.txt",
                                       "old_string": "diffoldcopyneedle", "new_string": "diffnewcopyneedle"]],
                         ], "usage": ["input_tokens": 8, "output_tokens": 8]]],
        ]
        var data = Data()
        for record in records {
            data.append(try JSONSerialization.data(withJSONObject: record, options: .sortedKeys))
            data.append(0x0a)
        }
        try data.write(to: project.appendingPathComponent("select-copy.jsonl"))
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
