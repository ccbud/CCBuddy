import SQLite3
import XCTest
@testable import CCBuddy

final class ConversationSessionLocationsTests: XCTestCase {
    func testDefaultRosterIsCompleteWhenNoProducerIsInstalledAndIncludesQoder() throws {
        let home = try HistoryTestSupport.temporaryDirectory("session-locations-roster")
        defer { try? FileManager.default.removeItem(at: home) }

        let layouts = ConversationSessionLocationLayout.defaults(
            homeDirectory: home,
            environment: [:]
        )
        let expected: [HistorySource] = [
            .claude, .codex, .qoder, .copilot, .cursor, .opencode, .kiro,
            .gemini, .pi, .omp, .grok, .kimi, .antigravity, .dsh,
        ]
        XCTAssertEqual(layouts.map(\.source), expected)
        XCTAssertTrue(layouts.allSatisfy { !$0.dataRoots.isEmpty })

        let qoder = try XCTUnwrap(layouts.first { $0.source == .qoder })
        XCTAssertEqual(qoder.ownerRoot, home.appendingPathComponent(".qoder"))
        XCTAssertEqual(qoder.dataRoots, [
            home.appendingPathComponent(".qoder/projects"),
            home.appendingPathComponent(".qoderwork/projects"),
        ])

        let database = try ConversationIndexDatabase(
            file: home.appendingPathComponent("app/conversation-index.sqlite3")
        )
        let repository = IndexedHistoryRepository(
            configuration: .init(
                historyDirs: [],
                homeDirectory: home,
                importsRoot: home.appendingPathComponent("app/imports")
            ),
            database: database
        )
        let rows = try repository.sessionLocationRows()
        XCTAssertEqual(Set(rows.map(\.source)), Set(expected))
        XCTAssertEqual(rows.filter { $0.source == .qoder }.count, 2)
    }

    func testOpenCodeXDGResolutionIsAnExistenceCheckedStartupSnapshot() throws {
        let home = try HistoryTestSupport.temporaryDirectory("session-locations-opencode-xdg")
        defer { try? FileManager.default.removeItem(at: home) }
        let xdg = home.appendingPathComponent("xdg-data")
        let database = xdg.appendingPathComponent("opencode/opencode.db")
        try FileManager.default.createDirectory(
            at: database.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: database)
        let environment = ["XDG_DATA_HOME": xdg.path]
        let configuration = HistoryConfiguration(
            historyDirs: [],
            homeDirectory: home,
            environment: environment
        )
        XCTAssertEqual(configuration.openCodeDefaultDatabase, database.standardizedFileURL)

        try FileManager.default.removeItem(at: database)
        let layouts = ConversationSessionLocationLayout.defaults(
            homeDirectory: home,
            environment: environment,
            openCodeDatabase: configuration.openCodeDefaultDatabase
        )
        XCTAssertEqual(
            layouts.first { $0.source == .opencode }?.dataRoots,
            [database.standardizedFileURL],
            "The UI must retain the same startup root after the filesystem changes"
        )
        XCTAssertEqual(
            ConversationSessionLocationLayout.defaultOpenCodeDatabase(
                homeDirectory: home,
                environment: environment
            ),
            home.appendingPathComponent(".local/share/opencode/opencode.db")
        )
    }

    func testLocationNormalizerRejectsRelativePathsBeforeFoundationCanAbsolutizeThem() throws {
        let home = try HistoryTestSupport.temporaryDirectory("session-locations-relative-path")
        defer { try? FileManager.default.removeItem(at: home) }
        for path in ["", "sessions", "./sessions", "../sessions", "~other/sessions"] {
            XCTAssertNil(ConversationSessionLocationValidator.normalizedLocation(
                source: .claude,
                path: path,
                homeDirectory: home
            ), path)
        }
        XCTAssertEqual(
            ConversationSessionLocationValidator.normalizedLocation(
                source: .claude,
                path: "~/sessions",
                homeDirectory: home
            )?.path,
            home.appendingPathComponent("sessions").path
        )
        let absolute = home.appendingPathComponent("absolute-sessions")
        XCTAssertEqual(
            ConversationSessionLocationValidator.normalizedLocation(
                source: .claude,
                path: absolute.path,
                homeDirectory: home
            )?.path,
            absolute.path
        )
    }

    func testCodexCustomRootNormalizationMatchesWakeHomeAndBareTreeRules() throws {
        let root = try HistoryTestSupport.temporaryDirectory("session-locations-codex")
        defer { try? FileManager.default.removeItem(at: root) }

        let codexHome = root.appendingPathComponent("codex-home")
        try FileManager.default.createDirectory(
            at: codexHome.appendingPathComponent("sessions/2026"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: codexHome.appendingPathComponent("archived_sessions"),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(
            to: codexHome.appendingPathComponent("archived_sessions/rollout-a.jsonl")
        )
        try Data("state".utf8).write(to: codexHome.appendingPathComponent("state_5.sqlite"))

        XCTAssertEqual(
            ConversationSessionLocationLayout.normalizedCustomRoot(
                source: .codex,
                selected: codexHome.appendingPathComponent("sessions")
            ).path,
            codexHome.path
        )
        XCTAssertEqual(
            ConversationSessionLocationLayout.normalizedCustomRoot(
                source: .codex,
                selected: codexHome.appendingPathComponent("archived_sessions")
            ).path,
            codexHome.path
        )

        let layout = ConversationSessionLocationLayout.custom(
            source: .codex,
            selected: codexHome.appendingPathComponent("sessions")
        )
        XCTAssertEqual(layout.ownerRoot.path, codexHome.path)
        XCTAssertEqual(layout.dataRoots.map(\.path), [
            codexHome.appendingPathComponent("sessions").path,
            codexHome.appendingPathComponent("archived_sessions").path,
        ])
        XCTAssertEqual(
            layout.companionFiles["state"]?.path,
            codexHome.appendingPathComponent("state_5.sqlite").path
        )

        let bare = root.appendingPathComponent("codex-copy")
        try FileManager.default.createDirectory(
            at: bare.appendingPathComponent("2027"),
            withIntermediateDirectories: true
        )
        XCTAssertEqual(
            ConversationSessionLocationLayout.normalizedCustomRoot(
                source: .codex,
                selected: bare
            ).path,
            bare.path,
            "A bare rollout tree is already a data root and must not be lifted"
        )

        let emptyHome = root.appendingPathComponent("empty-home")
        try FileManager.default.createDirectory(
            at: emptyHome.appendingPathComponent("sessions"),
            withIntermediateDirectories: true
        )
        try Data("state".utf8).write(to: emptyHome.appendingPathComponent("state_5.sqlite"))
        XCTAssertEqual(
            ConversationSessionLocationLayout.normalizedCustomRoot(
                source: .codex,
                selected: emptyHome.appendingPathComponent("sessions")
            ).path,
            emptyHome.path,
            "An empty sessions directory still lifts when its parent has independent home evidence"
        )

        let lone = root.appendingPathComponent("lone/sessions")
        try FileManager.default.createDirectory(at: lone, withIntermediateDirectories: true)
        XCTAssertEqual(
            ConversationSessionLocationLayout.normalizedCustomRoot(
                source: .codex,
                selected: lone
            ).path,
            lone.path,
            "An isolated empty sessions directory has no evidence that its parent is CODEX_HOME"
        )
        XCTAssertEqual(
            ConversationSessionLocationLayout.normalizedCustomRoot(
                source: .claude,
                selected: bare
            ).path,
            bare.path
        )
    }

    func testAddEditRemoveSuppressAndRestoreLocationOverridesPersistAcrossReopen() throws {
        let root = try HistoryTestSupport.temporaryDirectory("session-locations-persistence")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("conversation-index.sqlite3")
        let codex = root.appendingPathComponent("roots/a/../codex")
        let claude = root.appendingPathComponent("roots/claude")
        let grok = root.appendingPathComponent("roots/grok")
        let cursor = root.appendingPathComponent("roots/cursor")

        var database: ConversationIndexDatabase? = try .init(file: file)
        try database?.addCustomSessionLocation(.init(source: .codex, path: codex.path))
        try database?.addCustomSessionLocation(.init(source: .codex, path: codex.path))
        try database?.addCustomSessionLocation(.init(source: .claude, path: claude.path))
        try database?.replaceSessionLocation(
            oldSource: .codex,
            oldCustomPath: codex.path,
            with: .init(source: .grok, path: grok.path)
        )
        try database?.replaceSessionLocation(
            oldSource: .kiro,
            oldCustomPath: nil,
            with: .init(source: .cursor, path: cursor.path)
        )
        try database?.removeCustomSessionLocation(source: .claude, path: claude.path)
        try database?.removeDefaultSessionLocation(source: .codex)
        database = nil

        database = try .init(file: file)
        var overrides = try XCTUnwrap(database).sessionLocationOverrides()
        XCTAssertEqual(Set(overrides.custom), Set([
            ConversationSessionLocation(source: .grok, path: grok.standardizedFileURL.path),
            ConversationSessionLocation(source: .cursor, path: cursor.standardizedFileURL.path),
        ]))
        XCTAssertEqual(overrides.removedDefaults, [.codex, .kiro])

        try database?.removeCustomSessionLocation(source: .grok, path: grok.path)
        database = nil
        database = try .init(file: file)
        overrides = try XCTUnwrap(database).sessionLocationOverrides()
        XCTAssertEqual(overrides.custom, [
            ConversationSessionLocation(source: .cursor, path: cursor.standardizedFileURL.path),
        ])
        XCTAssertEqual(overrides.removedDefaults, [.codex, .kiro])

        let replacement = ConversationSessionLocationOverrides(
            custom: [ConversationSessionLocation(source: .qoder, path: claude.path)],
            removedDefaults: [.grok]
        )
        try database?.replaceSessionLocationOverrides(replacement)
        database = nil
        database = try .init(file: file)
        XCTAssertEqual(try XCTUnwrap(database).sessionLocationOverrides(), replacement)

        try database?.restoreDefaultSessionLocations()
        database = nil
        database = try .init(file: file)
        XCTAssertEqual(
            try XCTUnwrap(database).sessionLocationOverrides(),
            ConversationSessionLocationOverrides()
        )
    }

    func testVersionThreeMigrationPreservesWarmCatalogAndUserMetadata() throws {
        let root = try HistoryTestSupport.temporaryDirectory("session-locations-v3-migration")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("conversation-index.sqlite3")
        let transcript = root.appendingPathComponent("sessions/warm.jsonl")

        var database: ConversationIndexDatabase? = try .init(file: file)
        let indexed = indexedSession(
            file: transcript,
            id: "v3-warm",
            source: .codex,
            scope: "warm-scope",
            text: "warm location migration"
        )
        _ = try database?.replace(indexed)
        _ = try database?.updateUserMetadata(
            for: transcript,
            patch: .init(title: "Preserved title", starred: true, pinned: true)
        )
        let expectedEntry = try XCTUnwrap(database?.entry(for: transcript))
        let expectedDocuments = try XCTUnwrap(database?.documents(for: transcript))
        let expectedGeneration = try XCTUnwrap(database?.generation())
        database = nil

        try executeSQLite(
            """
            PRAGMA wal_checkpoint(TRUNCATE);
            BEGIN IMMEDIATE;
            DROP TABLE conversation_custom_roots;
            DROP TABLE conversation_removed_default_roots;
            PRAGMA user_version = 3;
            COMMIT;
            """,
            file: file
        )

        database = try .init(file: file)
        let migrated = try XCTUnwrap(database)
        XCTAssertEqual(try readSQLiteInteger("PRAGMA user_version", file: file), 4)
        XCTAssertEqual(try migrated.generation(), expectedGeneration)
        XCTAssertEqual(try migrated.entry(for: transcript), expectedEntry)
        XCTAssertEqual(try migrated.documents(for: transcript), expectedDocuments)
        let userMetadata = try migrated.userMetadata(for: transcript)
        XCTAssertEqual(userMetadata.title, "Preserved title")
        XCTAssertTrue(userMetadata.starred)
        XCTAssertTrue(userMetadata.pinned)
        XCTAssertEqual(try migrated.sessionLocationOverrides(), .init())

        try migrated.addCustomSessionLocation(.init(source: .codex, path: root.path))
        XCTAssertEqual(
            try migrated.sessionLocationOverrides().custom,
            [.init(source: .codex, path: root.standardizedFileURL.path)]
        )
    }

    func testSessionCountsRespectSourceComponentBoundariesNestedRootsAndSQLiteStorage() throws {
        let root = try HistoryTestSupport.temporaryDirectory("session-locations-counts")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try ConversationIndexDatabase(
            file: root.appendingPathComponent("conversation-index.sqlite3")
        )
        let claudeRoot = root.appendingPathComponent(".claude/projects")
        let codexRoot = claudeRoot.appendingPathComponent("codex/sessions")
        let nestedCodexRoot = codexRoot.appendingPathComponent("nested")
        let copilotDatabase = root.appendingPathComponent("copilot/session-store.db")
        let copilotLogical = WakeHistoryAdapterSupport.virtualSessionURL(
            database: copilotDatabase,
            nativeID: "sqlite-row"
        )

        let rows: [(URL, String, HistorySource)] = [
            (claudeRoot.appendingPathComponent("one.jsonl"), "claude-one", .claude),
            (codexRoot.appendingPathComponent("codex.jsonl"), "codex-one", .codex),
            (nestedCodexRoot.appendingPathComponent("nested.jsonl"), "codex-nested", .codex),
            (codexRoot.deletingLastPathComponent()
                .appendingPathComponent("sessions-old/sibling.jsonl"), "codex-sibling", .codex),
            (codexRoot.appendingPathComponent("claude-inside.jsonl"), "claude-inside", .claude),
            (copilotLogical, "copilot-row", .copilot),
        ]
        for row in rows {
            _ = try database.replace(indexedSession(
                file: row.0,
                id: row.1,
                source: row.2,
                scope: "scope-\(row.1)",
                text: row.1
            ))
        }

        let counts = try database.sessionCounts(for: [
            (source: .codex, root: nestedCodexRoot),
            (source: .codex, root: codexRoot),
            (source: .claude, root: claudeRoot),
            (source: .copilot, root: copilotDatabase),
        ])
        XCTAssertEqual(counts, [1, 1, 2, 1])
        XCTAssertTrue(ConversationSessionLocationLayout.pathOwns(
            root: copilotDatabase.path,
            path: copilotDatabase.path + "#sqlite-row"
        ))
        XCTAssertFalse(ConversationSessionLocationLayout.pathOwns(
            root: codexRoot.path,
            path: codexRoot.deletingLastPathComponent()
                .appendingPathComponent("sessions-old/sibling.jsonl").path
        ))
        XCTAssertTrue(ConversationSessionLocationLayout.pathOwns(root: "/", path: "/tmp/a"))
    }

    func testSameSourceExactParentAndChildLocationsOverlapButOtherSourcesDoNot() throws {
        let root = try HistoryTestSupport.temporaryDirectory("session-locations-overlap")
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("claude/projects")
        let rows = [ConversationSessionLocationRow(
            source: .claude,
            dataRoot: existing,
            storedCustomRoot: nil,
            sessionCount: 0,
            exists: false
        )]

        for path in [
            existing,
            existing.deletingLastPathComponent(),
            existing.appendingPathComponent("nested"),
        ] {
            XCTAssertTrue(ConversationSessionLocationValidator.overlapsExisting(
                .init(source: .claude, path: path.path),
                rows: rows
            ), path.path)
        }
        XCTAssertFalse(ConversationSessionLocationValidator.overlapsExisting(
            .init(source: .claude, path: existing.path + "-old"),
            rows: rows
        ))
        XCTAssertFalse(ConversationSessionLocationValidator.overlapsExisting(
            .init(source: .codex, path: existing.path),
            rows: rows
        ), "Different producers may intentionally use nested or identical roots")
    }

    func testEditingLocationExcludesItsWholeInstanceButStillRejectsAnotherInstance() throws {
        let root = try HistoryTestSupport.temporaryDirectory("session-locations-edit-overlap")
        defer { try? FileManager.default.removeItem(at: root) }
        let customOwner = root.appendingPathComponent("codex-copy")
        let otherOwner = root.appendingPathComponent("other-codex")
        let original = ConversationSessionLocationRow(
            source: .codex,
            dataRoot: customOwner.appendingPathComponent("sessions"),
            storedCustomRoot: customOwner,
            sessionCount: 0,
            exists: false
        )
        let rows = [
            original,
            ConversationSessionLocationRow(
                source: .codex,
                dataRoot: customOwner.appendingPathComponent("archived_sessions"),
                storedCustomRoot: customOwner,
                sessionCount: 0,
                exists: false
            ),
            ConversationSessionLocationRow(
                source: .codex,
                dataRoot: otherOwner.appendingPathComponent("sessions"),
                storedCustomRoot: otherOwner,
                sessionCount: 0,
                exists: false
            ),
        ]
        let unchanged = ConversationSessionLocation(
            source: .codex,
            path: customOwner.path
        )

        XCTAssertTrue(ConversationSessionLocationValidator.isUnchanged(
            unchanged,
            editing: original
        ))
        XCTAssertFalse(ConversationSessionLocationValidator.overlapsExisting(
            unchanged,
            rows: rows,
            editing: original
        ))
        XCTAssertTrue(ConversationSessionLocationValidator.overlapsExisting(
            .init(source: .codex, path: otherOwner.path),
            rows: rows,
            editing: original
        ))
    }

    func testEditingDefaultExcludesAllItsDerivedRootsButNotCustomRoots() throws {
        let root = try HistoryTestSupport.temporaryDirectory("session-locations-default-edit")
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultOwner = root.appendingPathComponent("default-codex")
        let customOwner = root.appendingPathComponent("custom-codex")
        let original = ConversationSessionLocationRow(
            source: .codex,
            dataRoot: defaultOwner.appendingPathComponent("sessions"),
            storedCustomRoot: nil,
            sessionCount: 0,
            exists: false
        )
        let rows = [
            original,
            ConversationSessionLocationRow(
                source: .codex,
                dataRoot: defaultOwner.appendingPathComponent("archived_sessions"),
                storedCustomRoot: nil,
                sessionCount: 0,
                exists: false
            ),
            ConversationSessionLocationRow(
                source: .codex,
                dataRoot: customOwner.appendingPathComponent("sessions"),
                storedCustomRoot: customOwner,
                sessionCount: 0,
                exists: false
            ),
        ]

        XCTAssertFalse(ConversationSessionLocationValidator.overlapsExisting(
            .init(source: .codex, path: defaultOwner.path),
            rows: rows,
            editing: original
        ))
        XCTAssertTrue(ConversationSessionLocationValidator.overlapsExisting(
            .init(source: .codex, path: customOwner.path),
            rows: rows,
            editing: original
        ))
    }

    func testCustomDirectoryAndSQLiteLocationsDiscoverAndRouteToTheirOwnInstances() throws {
        let root = try HistoryTestSupport.temporaryDirectory("session-locations-adapters")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let imports = root.appendingPathComponent("app/imports")
        let claudeOwner = root.appendingPathComponent("custom-claude")
        let claudeTranscript = claudeOwner
            .appendingPathComponent("projects/-work-custom/custom.jsonl")
        try HistoryTestSupport.write([
            HistoryTestSupport.claudeLine(
                type: "user",
                role: "user",
                contentJSON: #""Custom Claude location""#,
                sessionID: "custom-claude",
                cwd: "/work/custom",
                timestamp: "2026-08-24T10:00:00Z"
            ),
        ], to: claudeTranscript)

        let copilotDatabase = root.appendingPathComponent("custom-copilot/session-store.db")
        try createSQLiteDatabase(
            at: copilotDatabase,
            sql: """
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY, cwd TEXT, branch TEXT, summary TEXT,
                created_at TEXT, updated_at TEXT
            );
            CREATE TABLE turns (
                id INTEGER PRIMARY KEY, session_id TEXT, turn_index INTEGER,
                user_message TEXT, assistant_response TEXT, timestamp TEXT
            );
            INSERT INTO sessions VALUES (
                'custom-copilot', '/work/copilot', 'main', 'Custom Copilot location',
                '2026-08-24T10:00:00Z', '2026-08-24T10:01:00Z'
            );
            INSERT INTO turns VALUES (
                1, 'custom-copilot', 0, 'custom sqlite question', 'custom sqlite answer',
                '2026-08-24T10:01:00Z'
            );
            """
        )

        let claudeLayout = ConversationSessionLocationLayout.custom(
            source: .claude,
            selected: claudeOwner
        )
        let copilotLayout = ConversationSessionLocationLayout.custom(
            source: .copilot,
            selected: copilotDatabase
        )
        let configuration = HistoryConfiguration(
            historyDirs: [],
            homeDirectory: home,
            importsRoot: imports,
            sessionLocationOverrides: .init(
                custom: [
                    .init(source: .claude, path: claudeOwner.path),
                    .init(source: .copilot, path: copilotDatabase.path),
                ],
                removedDefaults: [.claude, .copilot]
            )
        )
        let loader = HistorySessionLoader(configuration: configuration)
        let candidates = loader.discoverCandidates(activeOnly: false)

        let claudeCandidate = try XCTUnwrap(candidates.first {
            $0.file.standardizedFileURL == claudeTranscript.standardizedFileURL
        })
        XCTAssertEqual(claudeCandidate.directory.id, claudeLayout.scopeID)
        let claudeAdapter = try XCTUnwrap(loader.adapters.adapter(
            for: .claude,
            candidate: claudeCandidate,
            configuration: configuration
        ))
        XCTAssertEqual(claudeAdapter.sessionLocation?.ownerRoot.path, claudeOwner.path)
        let claudeSession = try loader.load(claudeCandidate).session
        XCTAssertEqual(claudeSession.metadata.source, .claude)
        XCTAssertEqual(claudeSession.metadata.dirID, claudeLayout.scopeID)
        XCTAssertEqual(claudeSession.metadata.title, "Custom Claude location")

        let copilotCandidate = try XCTUnwrap(candidates.first {
            $0.formatHint == .copilot && $0.nativeID == "custom-copilot"
        })
        XCTAssertEqual(copilotCandidate.backingFile, copilotDatabase)
        XCTAssertEqual(copilotCandidate.directory.id, copilotLayout.scopeID)
        let copilotAdapter = try XCTUnwrap(loader.adapters.adapter(
            for: .copilot,
            candidate: copilotCandidate,
            configuration: configuration
        ))
        XCTAssertEqual(copilotAdapter.sessionLocation?.ownerRoot, copilotDatabase)
        let copilot = try loader.load(copilotCandidate, consistency: .bestEffort)
        XCTAssertEqual(copilot.session.metadata.source, .copilot)
        XCTAssertEqual(copilot.session.metadata.dirID, copilotLayout.scopeID)
        XCTAssertEqual(copilot.session.metadata.title, "Custom Copilot location")
        XCTAssertTrue(copilot.manifest.dependencies.contains {
            $0.role == .primaryDatabase && $0.file == copilotDatabase.standardizedFileURL
        })
        XCTAssertFalse(copilot.manifest.dependencies.contains {
            $0.file.path.hasPrefix(home.appendingPathComponent(".copilot").path)
        })
    }

    func testRoutingUsesLongestOwningPrefixAndHonorsComponentBoundaries() throws {
        let root = try HistoryTestSupport.temporaryDirectory("session-locations-longest-prefix")
        defer { try? FileManager.default.removeItem(at: root) }
        let broad = root.appendingPathComponent("claude-copy")
        let nested = broad.appendingPathComponent("nested")
        let configuration = HistoryConfiguration(
            historyDirs: [],
            homeDirectory: root.appendingPathComponent("home"),
            importsRoot: root.appendingPathComponent("imports"),
            sessionLocationOverrides: .init(custom: [
                .init(source: .claude, path: broad.path),
                .init(source: .claude, path: nested.path),
            ])
        )
        let registry = ConversationSourceAdapterRegistry()
        let nestedCandidate = candidate(
            nested.appendingPathComponent("project/session.jsonl"),
            format: .claude
        )
        let nestedAdapter = try XCTUnwrap(registry.adapter(
            for: .claude,
            candidate: nestedCandidate,
            configuration: configuration
        ))
        XCTAssertEqual(nestedAdapter.sessionLocation?.ownerRoot, nested)

        let siblingCandidate = candidate(
            URL(fileURLWithPath: broad.path + "-old/project/session.jsonl"),
            format: .claude
        )
        let fallback = try XCTUnwrap(registry.adapter(
            for: .claude,
            candidate: siblingCandidate,
            configuration: configuration
        ))
        XCTAssertNil(fallback.sessionLocation)
    }

    func testDiscoveryAssignsNestedTranscriptToLongestOwningProducerRoot() throws {
        let root = try HistoryTestSupport.temporaryDirectory("session-locations-owner-arbitration")
        defer { try? FileManager.default.removeItem(at: root) }
        let broad = root.appendingPathComponent("broad-kiro", isDirectory: true)
        let nested = broad.appendingPathComponent("pi-copy", isDirectory: true)
        let transcript = nested.appendingPathComponent("2026-08-25_shared.jsonl")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: transcript)
        let configuration = HistoryConfiguration(
            historyDirs: [],
            homeDirectory: root.appendingPathComponent("home"),
            importsRoot: root.appendingPathComponent("imports"),
            sessionLocationOverrides: .init(
                custom: [
                    .init(source: .kiro, path: broad.path),
                    .init(source: .pi, path: nested.path),
                ],
                removedDefaults: [.kiro, .pi]
            )
        )

        let discovery = ConversationSourceAdapterRegistry().discover(
            configuration: configuration,
            activeOnly: false
        )
        let matches = discovery.candidates.filter {
            $0.file.standardizedFileURL == transcript.standardizedFileURL
        }

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.formatHint, .pi)
        XCTAssertEqual(
            matches.first?.directory.id,
            ConversationSessionLocationLayout.custom(source: .pi, selected: nested).scopeID
        )
    }

    func testDiscoveryKeepsNewestSameSourceCopyAndOrdersOlderFallback() throws {
        let root = try HistoryTestSupport.temporaryDirectory("session-locations-copy-arbitration")
        defer { try? FileManager.default.removeItem(at: root) }
        let olderRoot = root.appendingPathComponent("pi-older", isDirectory: true)
        let newerRoot = root.appendingPathComponent("pi-newer", isDirectory: true)
        let older = olderRoot.appendingPathComponent("2026-08-24_shared.jsonl")
        let newer = newerRoot.appendingPathComponent("2026-08-25_shared.jsonl")
        try FileManager.default.createDirectory(at: olderRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newerRoot, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: older)
        try Data("{}\n".utf8).write(to: newer)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
            ofItemAtPath: older.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_800_000_000)],
            ofItemAtPath: newer.path
        )
        let configuration = HistoryConfiguration(
            historyDirs: [],
            homeDirectory: root.appendingPathComponent("home"),
            importsRoot: root.appendingPathComponent("imports"),
            sessionLocationOverrides: .init(
                custom: [
                    .init(source: .pi, path: olderRoot.path),
                    .init(source: .pi, path: newerRoot.path),
                ],
                removedDefaults: [.pi]
            )
        )

        let discovery = ConversationSourceAdapterRegistry().discover(
            configuration: configuration,
            activeOnly: false
        )

        let winner = try XCTUnwrap(
            discovery.candidates.first { $0.formatHint == .pi }
        )
        XCTAssertEqual(
            winner.file.resolvingSymlinksInPath(),
            newer.resolvingSymlinksInPath()
        )
        XCTAssertEqual(
            discovery.fallbackCandidatesByWinnerPath[winner.file.standardizedFileURL.path]?
                .map { $0.file.resolvingSymlinksInPath() },
            [older.resolvingSymlinksInPath()]
        )
    }

    func testCodexTimestampedCopiesArbitrateByProducerUUIDAcrossLocations() throws {
        let root = try HistoryTestSupport.temporaryDirectory("session-locations-codex-arbitration")
        defer { try? FileManager.default.removeItem(at: root) }
        let nativeID = "019c8ac7-8496-7620-99f3-eb9d0689f1aa"
        let olderRoot = root.appendingPathComponent("codex-older", isDirectory: true)
        let newerRoot = root.appendingPathComponent("codex-newer", isDirectory: true)
        let older = olderRoot.appendingPathComponent(
            "2026/08/24/rollout-2026-08-24T10-11-12-\(nativeID).jsonl"
        )
        let newer = newerRoot.appendingPathComponent(
            "2026/08/25/rollout-2026-08-25T13-14-15-\(nativeID).jsonl"
        )
        for file in [older, newer] {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("{}\n".utf8).write(to: file)
        }
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
            ofItemAtPath: older.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_800_000_000)],
            ofItemAtPath: newer.path
        )
        let configuration = HistoryConfiguration(
            historyDirs: [],
            homeDirectory: root.appendingPathComponent("home"),
            importsRoot: root.appendingPathComponent("imports"),
            sessionLocationOverrides: .init(
                custom: [
                    .init(source: .codex, path: olderRoot.path),
                    .init(source: .codex, path: newerRoot.path),
                ],
                removedDefaults: [.codex]
            )
        )

        let discovery = ConversationSourceAdapterRegistry().discover(
            configuration: configuration,
            activeOnly: false
        )

        XCTAssertEqual(
            CodexHistoryParser.rolloutNativeID(
                fromStem: older.deletingPathExtension().lastPathComponent
            ),
            nativeID
        )
        let winner = try XCTUnwrap(
            discovery.candidates.first { $0.formatHint == .codex }
        )
        XCTAssertEqual(
            winner.file.resolvingSymlinksInPath(),
            newer.resolvingSymlinksInPath()
        )
        XCTAssertEqual(winner.nativeID, nativeID)
        XCTAssertEqual(
            discovery.fallbackCandidatesByWinnerPath[winner.file.standardizedFileURL.path]?
                .map { $0.file.resolvingSymlinksInPath() },
            [older.resolvingSymlinksInPath()]
        )
    }

    func testRemovedDefaultIsNotDiscoveredButImportedTranscriptStillParses() throws {
        let root = try HistoryTestSupport.temporaryDirectory("session-locations-removed-default")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let defaultTranscript = home
            .appendingPathComponent(".claude/projects/-work-default/default.jsonl")
        let imports = root.appendingPathComponent("app/imports")
        let importedTranscript = imports
            .appendingPathComponent("projects/-work-imported/imported.jsonl")
        try writeClaudeSession(
            to: defaultTranscript,
            id: "default-session",
            text: "Default transcript must be suppressed"
        )
        try writeClaudeSession(
            to: importedTranscript,
            id: "imported-session",
            text: "Imported transcript remains available"
        )

        let configuration = HistoryConfiguration(
            historyDirs: ["~/.claude"],
            homeDirectory: home,
            importsRoot: imports,
            sessionLocationOverrides: .init(removedDefaults: [.claude])
        )
        let loader = HistorySessionLoader(configuration: configuration)
        let candidates = loader.discoverCandidates(activeOnly: false)
        XCTAssertFalse(candidates.contains {
            $0.file.standardizedFileURL == defaultTranscript.standardizedFileURL
        })
        let imported = try XCTUnwrap(candidates.first {
            $0.file.standardizedFileURL == importedTranscript.standardizedFileURL
        })
        XCTAssertEqual(imported.directory.id, "__imported__")

        let session = try loader.load(imported).session
        XCTAssertEqual(session.metadata.source, .claude)
        XCTAssertEqual(session.metadata.sessionID, "imported-session")
        XCTAssertEqual(session.metadata.title, "Imported transcript remains available")
        XCTAssertTrue(session.metadata.imported)
    }

    func testDiscoveryKeepsImportedCopyIndependentFromMatchingLiveSession() throws {
        let root = try HistoryTestSupport.temporaryDirectory("session-locations-import-arbitration")
        defer { try? FileManager.default.removeItem(at: root) }
        let liveRoot = root.appendingPathComponent("live")
        let live = liveRoot.appendingPathComponent("projects/-work/shared.jsonl")
        let imports = root.appendingPathComponent("app/imports")
        let imported = imports.appendingPathComponent("projects/-work/shared.jsonl")
        try writeClaudeSession(to: live, id: "shared-native-id", text: "Live copy")
        try writeClaudeSession(to: imported, id: "shared-native-id", text: "Imported copy")

        let configuration = HistoryConfiguration(
            historyDirs: [liveRoot.path],
            homeDirectory: root.appendingPathComponent("home"),
            importsRoot: imports
        )
        let registry = ConversationSourceAdapterRegistry()
        let discovered = registry.discover(
            configuration: configuration,
            activeOnly: false
        ).candidates.filter { $0.file.lastPathComponent == "shared.jsonl" }

        XCTAssertEqual(discovered.count, 2)
        XCTAssertEqual(Set(discovered.map(\.directory.id)), [liveRoot.path, "__imported__"])

        var importedConfiguration = configuration
        importedConfiguration.active = "__imported__"
        let importedOnly = registry.discover(
            configuration: importedConfiguration,
            activeOnly: true
        ).candidates
        XCTAssertEqual(importedOnly.map(\.file.standardizedFileURL), [imported.standardizedFileURL])
    }

    private func candidate(
        _ file: URL,
        format: HistoryTranscriptFormat
    ) -> HistoryFileCandidate {
        let directory = HistoryDirectory(
            id: "fixture",
            label: "Fixture",
            baseURL: file.deletingLastPathComponent(),
            projectsURL: file.deletingLastPathComponent(),
            sessionsURL: file.deletingLastPathComponent()
        )
        return HistoryFileCandidate(
            file: file,
            projectDirectoryName: nil,
            directory: directory,
            formatHint: format
        )
    }

    private func writeClaudeSession(to file: URL, id: String, text: String) throws {
        try HistoryTestSupport.write([
            HistoryTestSupport.claudeLine(
                type: "user",
                role: "user",
                contentJSON: "\"\(text)\"",
                sessionID: id,
                cwd: "/work/\(id)",
                timestamp: "2026-08-24T10:00:00Z"
            ),
        ], to: file)
    }

    private func indexedSession(
        file: URL,
        id: String,
        source: HistorySource,
        scope: String,
        text: String
    ) -> ConversationIndexedSession {
        ConversationIndexedSession(
            metadata: metadata(file: file, id: id, source: source, scope: scope),
            scope: scope,
            fingerprint: .init(
                modificationTime: Date(timeIntervalSince1970: 1_800_000_000),
                sizeBytes: UInt64(text.utf8.count)
            ),
            documents: [.init(
                transcriptID: ConversationIndexDocument.mainTranscriptID,
                sortOrder: 0,
                text: text,
                messageSpans: []
            )]
        )
    }

    private func metadata(
        file: URL,
        id: String,
        source: HistorySource,
        scope: String
    ) -> HistorySessionMetadata {
        HistorySessionMetadata(
            id: "\(source.rawValue):\(id)",
            file: file,
            source: source,
            dirID: scope,
            dirLabel: scope,
            sessionID: id,
            threadID: nil,
            rootSessionID: nil,
            parentThreadID: nil,
            forkedFromID: nil,
            canonicalThreadIDValid: false,
            cwd: "/work/\(id)",
            project: id,
            gitBranch: nil,
            version: nil,
            title: id,
            autoTitle: id,
            tags: [],
            summary: nil,
            model: nil,
            isSubagent: false,
            skill: nil,
            agentPath: nil,
            agentNickname: nil,
            agentRole: nil,
            agentDepth: nil,
            subagentCount: 0,
            imported: false,
            deleted: false,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            lastActivity: Date(timeIntervalSince1970: 1_800_000_100),
            sizeBytes: 1,
            totals: .init(),
            messageCount: 1,
            diagnostics: .init()
        )
    }

    private func createSQLiteDatabase(at file: URL, sql: String) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try executeSQLite(sql, file: file)
    }

    private func executeSQLite(_ sql: String, file: URL) throws {
        var database: OpaquePointer?
        let openStatus = sqlite3_open_v2(
            file.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openStatus == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw sqliteError("open", status: openStatus)
        }
        defer { sqlite3_close(database) }

        var detail: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(database, sql, nil, nil, &detail)
        defer { if let detail { sqlite3_free(detail) } }
        guard status == SQLITE_OK else {
            let message = detail.map { String(cString: $0) } ?? "SQLite \(status)"
            throw sqliteError(message, status: status)
        }
    }

    private func readSQLiteInteger(_ sql: String, file: URL) throws -> Int32 {
        var database: OpaquePointer?
        let openStatus = sqlite3_open_v2(file.path, &database, SQLITE_OPEN_READONLY, nil)
        guard openStatus == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw sqliteError("open read-only", status: openStatus)
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        let prepareStatus = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareStatus == SQLITE_OK, let statement else {
            throw sqliteError("prepare", status: prepareStatus)
        }
        defer { sqlite3_finalize(statement) }
        let stepStatus = sqlite3_step(statement)
        guard stepStatus == SQLITE_ROW else {
            throw sqliteError("step", status: stepStatus)
        }
        return sqlite3_column_int(statement, 0)
    }

    private func sqliteError(_ detail: String, status: Int32) -> NSError {
        NSError(
            domain: "ConversationSessionLocationsTests",
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: detail]
        )
    }
}
