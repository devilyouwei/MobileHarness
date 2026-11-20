import Foundation
import StorageChat
import UI

/// Writer owns operation semantics; Storage only supplies invocation facts and UI only renders labels.
enum WriterRequestNaming {
    static func state(request: String, calls: [WriterToolPreview], pending: Bool = false) -> String {
        if ["failed", "cancelled", "interrupted"].contains(request) { return request }
        if calls.contains(where: { $0.state == "failed" }) { return "failed" }
        if calls.contains(where: { $0.state == "cancelled" }) { return "cancelled" }
        if pending || calls.contains(where: { $0.state == "received" }) { return "executing" }
        return request
    }
    static func summary(
        phase: String, path: String?, calls: [WriterToolPreview], domain: String? = nil,
        language: AppLanguage = .english
    ) -> String {
        func file(_ path: String?) -> String {
            guard let path, !path.isEmpty else { return language.text("File") }
            return path.count <= 40 ? path : (path as NSString).lastPathComponent
        }
        if phase == "File content request" { return language.text("Write ") + file(path) }
        var titles: [String] = []
        for call in calls {
            let args = (try? JSONDecoder().decode([String: String].self, from: Data(call.argumentsJSON.utf8))) ?? [:]
            let title: String
            switch call.name {
            case "workspace.search": title = language.text("Search the project library")
            case "workspace.create": title = language.text("Create and open workspace")
            case "workspace.enter": title = language.text("Open existing workspace")
            case "workspace.open": title = language.text("Open existing project")
            case "workspace.delete": title = language.text("Delete project")
            case "list": title = language.text("List workspace")
            case "read": title = language.text("Read ") + file(args["path"])
            case "search": title = language.text("Search files")
            case "edit":
                let instruction = args["instruction"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let brief =
                    !instruction.isEmpty && instruction.count <= 40
                    && !instruction.contains(where: { "\n\r<>{}".contains($0) || $0.asciiValue == 96 })
                title =
                    brief
                    ? instruction
                    : (args["reference"] == nil ? language.text("Write ") : language.text("Edit ")) + file(args["path"])
            case "replace": title = language.text("Edit ") + file(args["path"])
            case "move": title = language.text("Move ") + file(args["path"])
            case "remove", "removeTree": title = language.text("Delete ") + file(args["path"])
            case "render": title = language.text("Render and check the page")
            case "finish":
                title = domain == "library" ? language.text("Report library results") : language.text("Save project")
            case "ask": title = language.text("Wait for more information")
            case "rename": title = language.text("Rename project")
            case "savepoint": title = language.text("Save draft checkpoint")
            case "restore": title = language.text("Restore draft")
            case "diff": title = language.text("Check file changes")
            default: title = language.text("Process writing step")
            }
            if !titles.contains(title) {
                titles.append(title)
            }
        }
        guard let first = titles.first else { return language.text("Process writing step") }
        let title =
            titles.count == 1
            ? first
            : titles.prefix(2).joined(separator: (language == .simplifiedChinese ? "、" : ", "))
                + (titles.count > 2 ? language.format(" (%@ actions total)", String(titles.count)) : "")
        return title
    }
}
