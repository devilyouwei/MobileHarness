#if WRITER_UI_ACCEPTANCE && os(iOS)
    import XCTest

    /// Actual app clicks against a simulator seeded only with synthetic Writer evidence.
    @MainActor final class WriterRecordsNativeAcceptance: XCTestCase {
        func capture(_ name: String, app: XCUIApplication) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        private func assertRequestHasNoDelegationLink(_ app: XCUIApplication) {
            XCTAssertTrue(app.navigationBars["Request details"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts["writer.detail.overview"].waitForExistence(timeout: 10))
            XCTAssertFalse(app.staticTexts["Assignment source"].exists)
            XCTAssertFalse(app.buttons["View assignment"].exists)
        }
        private func openSettings(_ app: XCUIApplication) {
            let skip = app.buttons["welcome.provider.skip"]
            if skip.waitForExistence(timeout: 30) {
                skip.tap()
                XCTAssertTrue(skip.waitForNonExistence(timeout: 20), app.debugDescription)
            }
            let settings = app.buttons["app.settings"]
            XCTAssertTrue(settings.waitForExistence(timeout: 30), app.debugDescription)
            settings.tap()
            XCTAssertTrue(app.buttons["settings.writer.records"].waitForExistence(timeout: 20), app.debugDescription)
        }
        func testDelegationWorkspaceSeparation() throws {
            let app = XCUIApplication(bundleIdentifier: "dev.mobileharness.app")
            app.launchArguments += ["-application.language", "en"]
            app.launch()
            defer { app.terminate() }
            openSettings(app)
            app.buttons["settings.writer.records"].tap()
            XCTAssertTrue(app.buttons["writer.delegations"].waitForExistence(timeout: 15))
            capture("writer-separated-overview", app: app)
            app.buttons["writer.delegations"].tap()
            XCTAssertTrue(app.navigationBars["Assignments"].waitForExistence(timeout: 10))
            let delegations = app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "writer.delegation."))
            XCTAssertTrue(delegations.firstMatch.waitForExistence(timeout: 10))
            XCTAssertTrue(delegations.firstMatch.label.contains("Pagination fixture delegation 25"))
            let delegation = delegations.matching(
                NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "writer.delegation.", "Create")
            )
            .firstMatch
            XCTAssertFalse(delegation.isHittable)
            for _ in 0..<25 where !delegation.isHittable { app.swipeUp() }
            XCTAssertTrue(delegation.isHittable, app.debugDescription)
            XCTAssertFalse(app.buttons["Load more"].exists)
            delegation.tap()
            XCTAssertTrue(app.staticTexts["Original input"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts["Messages before entering the workspace"].exists)
            capture("writer-delegation-detail", app: app)
            let preflight = app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "writer.preflight.request.")
            )
            .firstMatch
            for _ in 0..<10 where !preflight.isHittable { app.swipeUp() }
            XCTAssertTrue(preflight.isHittable)
            preflight.tap()
            assertRequestHasNoDelegationLink(app)
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.navigationBars["Assignment details"].exists)
            app.navigationBars.buttons.element(boundBy: 0).tap()
            app.navigationBars.buttons.element(boundBy: 0).tap()
            let workspace = app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "writer.workspace.workspace_")
            )
            .firstMatch
            XCTAssertTrue(workspace.waitForExistence(timeout: 10))
            workspace.tap()
            XCTAssertTrue(app.navigationBars["Workspace"].waitForExistence(timeout: 10))
            let messages = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "writer.request."))
            XCTAssertTrue(messages.firstMatch.waitForExistence(timeout: 10))
            XCTAssertTrue(messages.firstMatch.label.contains("Round 40"), messages.firstMatch.label)
            let row = messages.matching(
                NSPredicate(format: "label CONTAINS %@", "Round 1")
            ).firstMatch
            XCTAssertFalse(row.isHittable)
            for _ in 0..<25 where !row.isHittable { app.swipeUp() }
            XCTAssertTrue(row.isHittable, app.debugDescription)
            XCTAssertFalse(app.buttons["Load more"].exists)
            XCTAssertFalse(app.staticTexts["Assignment 1"].exists)
            capture("writer-workspace-last-page", app: app)
            let identity = row.identifier
            row.tap()
            assertRequestHasNoDelegationLink(app)
            capture("writer-request-without-delegation-link", app: app)
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.buttons[identity].waitForExistence(timeout: 10))
            XCTAssertFalse(app.buttons["Load more"].exists)
            capture("writer-pages-preserved-after-back", app: app)
        }
        func testWriterRecords() throws {
            let app = XCUIApplication(bundleIdentifier: "dev.mobileharness.app")
            app.launchArguments += ["-application.language", "en"]
            app.launch()
            defer { app.terminate() }
            openSettings(app)
            XCTAssertTrue(app.buttons["settings.assistant.records"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.buttons["settings.writer.records"].exists)
            XCTAssertFalse(app.buttons["settings.agent.records"].exists)
            XCTAssertTrue(app.navigationBars["Settings"].exists)
            let userEntries: [(String, String)] = [
                ("settings.user.album", "Album"),
                ("settings.assistant.records", "My Assistant"),
                ("settings.writer.records", "My Writer"),
                ("settings.user.memory", "Memory"),
            ]
            var previousY = -Double.infinity
            for (identifier, title) in userEntries {
                let entry = app.descendants(matching: .any)[identifier].firstMatch
                XCTAssertTrue(entry.exists)
                XCTAssertTrue(entry.label.contains(title), entry.label)
                XCTAssertGreaterThan(entry.frame.midY, previousY)
                previousY = entry.frame.midY
            }
            XCTAssertTrue(app.buttons["settings.bluetooth.open"].label.contains("Bluetooth"))
            capture("settings-separate-records", app: app)
            app.buttons["settings.assistant.records"].tap()
            XCTAssertTrue(app.navigationBars["My Assistant"].waitForExistence(timeout: 15), app.debugDescription)
            XCTAssertTrue(app.staticTexts["Current Conversation"].exists)
            XCTAssertTrue(app.staticTexts["Past Conversations"].exists)
            capture("assistant-conversation-list", app: app)
            app.navigationBars.buttons.element(boundBy: 0).tap()
            app.buttons["settings.writer.records"].tap()
            XCTAssertTrue(app.navigationBars["My Writer"].waitForExistence(timeout: 10))
            let task = app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "writer.workspace.workspace_")
            )
            .firstMatch
            XCTAssertTrue(task.waitForExistence(timeout: 15), app.debugDescription)
            capture("writer-task-list", app: app)
            task.tap()
            XCTAssertTrue(app.buttons["writer.workspace.files"].waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(app.buttons["writer.workspace.export"].exists)
            XCTAssertTrue(app.descendants(matching: .any)["writer.workspace.started"].exists)
            XCTAssertTrue(app.descendants(matching: .any)["writer.workspace.updated"].exists)
            XCTAssertFalse(app.staticTexts["Latest status"].exists)
            capture("writer-task-header", app: app)
            app.buttons["writer.workspace.files"].tap()
            XCTAssertTrue(app.staticTexts["index.html"].waitForExistence(timeout: 15), app.debugDescription)
            capture("writer-files", app: app)
            app.buttons["index.html"].tap()
            XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 15), app.debugDescription)
            capture("writer-file-preview", app: app)
            app.navigationBars.buttons.element(boundBy: 0).tap()
            for (label, name) in [
                ("Export project PDF", "writer-pdf-share"), ("Export all source files (ZIP)", "writer-zip-share"),
            ] {
                app.buttons[label].tap()
                XCTAssertTrue(
                    app.collectionViews["activityCollectionView"].waitForExistence(timeout: 20), app.debugDescription)
                capture(name, app: app)
                app.buttons["header.closeButton"].tap()
            }
            app.navigationBars.buttons.element(boundBy: 0).tap()
            let request = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "writer.request."))
                .firstMatch
            if !request.exists { app.swipeUp() }
            XCTAssertTrue(request.waitForExistence(timeout: 10), app.debugDescription)
            request.tap()
            XCTAssertTrue(app.navigationBars["Request details"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts["writer.detail.overview"].waitForExistence(timeout: 10))
            let metrics = app.buttons["writer.detail.generation"]
            for _ in 0..<20 where !metrics.isHittable { app.swipeUp() }
            XCTAssertTrue(metrics.exists)
            XCTAssertFalse(app.staticTexts["writer.request.ttft"].exists)
            metrics.tap()
            for _ in 0..<10 where !app.staticTexts["writer.request.ttft"].isHittable { app.swipeUp() }
            XCTAssertTrue(app.staticTexts["writer.request.ttft"].exists)
            XCTAssertTrue(app.staticTexts["writer.request.duration"].exists)
            capture("writer-native-request", app: app)
            app.navigationBars.buttons.element(boundBy: 0).tap()
            let candidates = app.buttons.matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "writer.request.", "Write index.html"))
            var tried = Set<String>()
            var foundContent = false
            var capturedRows = false
            for _ in 0..<10 {
                let next = candidates.allElementsBoundByIndex.map(\.identifier).first { !tried.contains($0) }
                guard let identifier = next else {
                    app.swipeUp()
                    if !capturedRows {
                        capture("writer-request-rows", app: app)
                        capturedRows = true
                    }
                    continue
                }
                tried.insert(identifier)
                app.buttons[identifier].tap()
                XCTAssertTrue(app.navigationBars["Request details"].waitForExistence(timeout: 10))
                if app.buttons["writer.request.content.toggle"].waitForExistence(timeout: 3) {
                    foundContent = true
                    break
                }
                app.navigationBars.buttons.element(boundBy: 0).tap()
                app.swipeUp()
                if !capturedRows {
                    capture("writer-request-rows", app: app)
                    capturedRows = true
                }
            }
            guard foundContent else {
                XCTFail(app.debugDescription)
                return
            }
            let content = app.staticTexts["writer.request.source"]
            XCTAssertTrue(app.buttons["writer.request.content.toggle"].label.contains("index.html"))
            XCTAssertFalse(content.exists, app.debugDescription)
            capture("writer-content-collapsed", app: app)
            app.buttons["writer.request.content.toggle"].tap()
            XCTAssertTrue(content.waitForExistence(timeout: 10), app.debugDescription)
            capture("writer-content-expanded", app: app)
            app.navigationBars.buttons.element(boundBy: 0).tap()
            let source = app.buttons["writer.detail.tool-source"].firstMatch
            let overview = app.staticTexts["writer.detail.overview"]
            var opened = Set<String>()
            var foundSource = false
            for _ in 0..<14 {
                guard
                    let identifier = app.buttons.matching(
                        NSPredicate(format: "identifier BEGINSWITH %@", "writer.request.")
                    )
                    .allElementsBoundByIndex.first(where: { $0.isHittable && !opened.contains($0.identifier) })?
                    .identifier
                else {
                    app.swipeUp()
                    continue
                }
                opened.insert(identifier)
                app.buttons[identifier].tap()
                XCTAssertTrue(overview.waitForExistence(timeout: 10))
                let current = overview.label
                for _ in 0..<3 where !source.isHittable { app.swipeUp() }
                if source.isHittable {
                    source.tap()
                    XCTAssertTrue(overview.waitForExistence(timeout: 10))
                    XCTAssertNotEqual(overview.label, current)
                    capture("writer-tool-source", app: app)
                    app.navigationBars.buttons.element(boundBy: 0).tap()
                    foundSource = true
                }
                app.navigationBars.buttons.element(boundBy: 0).tap()
                if foundSource { break }
            }
            XCTAssertTrue(foundSource)
            app.swipeDown()
            let export = app.buttons["writer.workspace.export"]
            XCTAssertTrue(export.waitForExistence(timeout: 10))
            export.tap()
            let share = app.collectionViews["activityCollectionView"]
            XCTAssertTrue(share.waitForExistence(timeout: 15), app.debugDescription)
            capture("writer-export", app: app)
        }
    }
#endif
