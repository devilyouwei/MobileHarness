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
        func testWriterRecords() throws {
            let app = XCUIApplication(bundleIdentifier: "dev.mobileharness.app")
            app.launch()
            defer { app.terminate() }
            let settings = app.buttons["app.settings"]
            XCTAssertTrue(settings.waitForExistence(timeout: 30), app.debugDescription)
            settings.tap()
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
            let task = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "writer.task.task_"))
                .firstMatch
            XCTAssertTrue(task.waitForExistence(timeout: 15), app.debugDescription)
            capture("writer-task-list", app: app)
            task.tap()
            XCTAssertTrue(app.buttons["writer.task.files"].waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(app.buttons["writer.task.export"].exists)
            XCTAssertTrue(app.descendants(matching: .any)["writer.task.started"].exists)
            XCTAssertTrue(app.descendants(matching: .any)["writer.task.duration"].exists)
            XCTAssertTrue(app.staticTexts["最新状态"].exists)
            capture("writer-task-header", app: app)
            app.buttons["writer.task.files"].tap()
            XCTAssertTrue(app.staticTexts["index.html"].waitForExistence(timeout: 15), app.debugDescription)
            capture("writer-files", app: app)
            app.buttons["index.html"].tap()
            XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 15), app.debugDescription)
            capture("writer-file-preview", app: app)
            app.navigationBars.buttons.element(boundBy: 0).tap()
            for (label, name) in [("导出作品 PDF", "writer-pdf-share"), ("导出全部源文件（ZIP）", "writer-zip-share")] {
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
            XCTAssertTrue(app.navigationBars["请求详情"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts["writer.request.ttft"].exists)
            XCTAssertTrue(app.staticTexts["writer.request.duration"].exists)
            capture("writer-native-request", app: app)
            app.navigationBars.buttons.element(boundBy: 0).tap()
            let candidates = app.buttons.matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "writer.request.", "编写 index.html"))
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
                XCTAssertTrue(app.navigationBars["请求详情"].waitForExistence(timeout: 10))
                if app.buttons["writer.request.content"].waitForExistence(timeout: 3) {
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
            let content = app.buttons["writer.request.content"]
            XCTAssertTrue(content.waitForExistence(timeout: 10), app.debugDescription)
            let generatedSource = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "<!doctype"))
                .firstMatch
            XCTAssertFalse(generatedSource.exists)
            capture("writer-content-collapsed", app: app)
            content.tap()
            XCTAssertTrue(generatedSource.waitForExistence(timeout: 10), app.debugDescription)
            capture("writer-content-expanded", app: app)
            app.navigationBars.buttons.element(boundBy: 0).tap()
            app.swipeDown()
            let export = app.buttons["writer.task.export"]
            XCTAssertTrue(export.waitForExistence(timeout: 10))
            export.tap()
            let share = app.collectionViews["activityCollectionView"]
            XCTAssertTrue(share.waitForExistence(timeout: 15), app.debugDescription)
            capture("writer-export", app: app)
        }
    }
#endif
