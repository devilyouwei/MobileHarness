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
            capture("settings-separate-records", app: app)
            app.buttons["settings.writer.records"].tap()
            let task = app.buttons["writer.task.task_6"]
            XCTAssertTrue(task.waitForExistence(timeout: 15), app.debugDescription)
            capture("writer-task-list", app: app)
            task.tap()
            XCTAssertTrue(app.buttons["writer.task.files"].waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(app.buttons["writer.task.export"].exists)
            XCTAssertTrue(app.descendants(matching: .any)["writer.task.started"].exists)
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
            capture("writer-native-request", app: app)
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
