import Foundation
import Testing

@testable import Agents

private func declaration(_ json: String) throws -> AgentStateDeclaration {
    try JSONDecoder().decode(AgentStateDeclaration.self, from: Data(json.utf8))
}

private func schema() throws -> AgentStateSchema {
    try AgentStateSchema([
        declaration(
            #"{"name":"task","kind":"semantic","access":"readWrite","type":"text","meaning":"goal","trigger":"task"}"#),
        declaration(#"{"name":"quiet","kind":"typed","access":"readOnly","type":"bool","meaning":"silence"}"#),
        declaration(
            #"{"name":"energy","kind":"typed","access":"readWrite","type":"enum","values":["low","high"],"meaning":"energy"}"#
        ),
    ])
}

@Test func bundledAssistantDeclaresTaskAndQuiet() throws {
    let schema = try AgentConfigurations.stateSchema(named: "Assistant")
    #expect(schema.declaration(boundTo: .task)?.name == "task")
    #expect(schema.declarations["task"]?.access == .readWrite)
    #expect(schema.declarations["quiet"]?.kind == .typed)
    #expect(schema.declarations["quiet"]?.access == .readOnly)
    for name in ["Memory", "Writer", "Photographer", "ApplicationControl", "SpeechPerception", "VisionPerception"] {
        #expect(try AgentConfigurations.stateSchema(named: name).declarations.isEmpty)
    }
}

@Test(
    arguments: [
        #"{"name":"Mood","kind":"semantic","access":"readWrite","type":"text","meaning":"m"}"#,
        #"{"name":"mood","kind":"semantic","access":"readWrite","type":"bool","meaning":"m"}"#,
        #"{"name":"mood","kind":"typed","access":"readWrite","type":"enum","meaning":"m"}"#,
        #"{"name":"mood","kind":"typed","access":"readWrite","type":"text","meaning":" "}"#,
        #"{"name":"mood","kind":"typed","access":"readWrite","type":"text","meaning":"m","extra":1}"#,
        #"{"name":"mood","kind":"typed","access":"readWrite","meaning":"m"}"#,
    ])
func invalidDeclarationsAreRejected(json: String) {
    #expect(throws: (any Error).self) { try declaration(json) }
}

@Test func unknownTriggerAndDuplicateNamesAreRejected() throws {
    let unknown = try declaration(
        #"{"name":"mood","kind":"typed","access":"readWrite","type":"text","meaning":"m","trigger":"alarm"}"#)
    #expect(throws: AgentStateError.invalidDeclaration) { try AgentStateSchema([unknown]) }
    let plain = try declaration(#"{"name":"mood","kind":"typed","access":"readWrite","type":"text","meaning":"m"}"#)
    #expect(throws: AgentStateError.invalidDeclaration) { try AgentStateSchema([plain, plain]) }
}

@Test func modelWritesFreeAndReadWriteVariablesButNotReadOnlyOnes() throws {
    let schema = try schema()
    var variables = AgentStateVariables()
    try variables.set("mood", "  You are angry  ", source: .model, schema: schema)
    #expect(variables.value("mood") == "You are angry")
    try variables.set("energy", "high", source: .model, schema: schema)
    #expect(throws: AgentStateError.readOnly("quiet")) {
        try variables.set("quiet", "true", source: .model, schema: schema)
    }
    #expect(throws: AgentStateError.readOnly("quiet")) { try variables.clear("quiet", source: .model, schema: schema) }
    #expect(variables.value("quiet") == nil)
}

@Test func hostWritesReadOnlyVariablesButOnlyDeclaredOnes() throws {
    let schema = try schema()
    var variables = AgentStateVariables()
    let change = try variables.set("quiet", "TRUE", source: .host, schema: schema)
    #expect(variables.value("quiet") == "true")
    #expect(change.old == nil && change.new == "true" && change.changed)
    #expect(throws: AgentStateError.unknownVariable("mood")) {
        try variables.set("mood", "x", source: .host, schema: schema)
    }
}

@Test func typedValuesAreParsedAndRejectedWithoutChangingTheVariable() throws {
    let schema = try schema()
    var variables = AgentStateVariables()
    try variables.set("energy", "low", source: .model, schema: schema)
    #expect(throws: AgentStateError.invalidValue("energy")) {
        try variables.set("energy", "medium", source: .model, schema: schema)
    }
    #expect(variables.value("energy") == "low")
    try variables.set("quiet", "false", source: .host, schema: schema)
    #expect(throws: AgentStateError.invalidValue("quiet")) {
        try variables.set("quiet", "maybe", source: .host, schema: schema)
    }
    #expect(variables.value("quiet") == "false")
}

@Test(arguments: ["", "Mood", "1mood", "a.b", "has space", String(repeating: "a", count: 33)])
func invalidNamesAreRejected(name: String) throws {
    var variables = AgentStateVariables()
    #expect(throws: AgentStateError.invalidName(name)) {
        try variables.set(name, "x", source: .model, schema: try schema())
    }
}

@Test func emptyAndOverlongValuesAreRejected() throws {
    let schema = try schema()
    var variables = AgentStateVariables()
    #expect(throws: AgentStateError.invalidValue("mood")) {
        try variables.set("mood", "   ", source: .model, schema: schema)
    }
    let long = String(repeating: "x", count: AgentStateVariables.maximumValueBytes + 1)
    #expect(throws: AgentStateError.valueTooLong("mood")) {
        try variables.set("mood", long, source: .model, schema: schema)
    }
    try variables.set(
        "mood", String(repeating: "x", count: AgentStateVariables.maximumValueBytes), source: .model, schema: schema)
}

@Test func clearingAnUnsetVariableChangesNothing() throws {
    var variables = AgentStateVariables()
    #expect(try variables.clear("mood", source: .model, schema: try schema()) == nil)
    try variables.set("mood", "calm", source: .model, schema: try schema())
    let change = try variables.clear("mood", source: .model, schema: try schema(), note: "done")
    #expect(change?.old == "calm" && change?.new == nil && change?.note == "done")
    #expect(variables.value("mood") == nil)
}

@Test func freeVariablesBeyondTheCountEvictTheEarliestWrittenWithoutFailing() throws {
    let schema = try schema()
    var variables = AgentStateVariables()
    try variables.set("energy", "low", source: .model, schema: schema)
    for index in 0..<(AgentStateVariables.maximumFreeVariables + 3) {
        try variables.set("note_\(index)", "v", source: .model, schema: schema)
    }
    let free = variables.entries.keys.filter { $0.hasPrefix("note_") }
    #expect(free.count == AgentStateVariables.maximumFreeVariables)
    #expect(variables.value("note_0") == nil && variables.value("note_2") == nil)
    #expect(variables.value("note_3") == "v")
    #expect(variables.value("note_\(AgentStateVariables.maximumFreeVariables + 2)") == "v")
    #expect(variables.value("energy") == "low")
}

@Test func freeVariablesBeyondTheByteBudgetEvictTheEarliestWritten() throws {
    let schema = try schema()
    var variables = AgentStateVariables()
    let value = String(repeating: "x", count: 1000)
    for index in 0..<10 { try variables.set("note_\(index)", value, source: .model, schema: schema) }
    #expect(variables.value("note_0") == nil && variables.value("note_1") == nil)
    #expect(variables.value("note_9") == value)
    let bytes = variables.entries.reduce(0) { $0 + $1.key.utf8.count + $1.value.value.utf8.count }
    #expect(bytes <= AgentStateVariables.maximumFreeBytes)
}

@Test func rewritingAVariableMovesItToTheEndOfTheOrder() throws {
    let schema = try schema()
    var variables = AgentStateVariables()
    let start = Date(timeIntervalSince1970: 1_000)
    try variables.set("a", "1", source: .model, schema: schema, at: start)
    try variables.set("b", "2", source: .model, schema: schema, at: start.addingTimeInterval(60))
    try variables.set("a", "3", source: .model, schema: schema, at: start.addingTimeInterval(120))
    #expect(variables.ordered.map(\.name) == ["b", "a"])
    let shown = variables.showing("task", value: "goal", writtenAt: start.addingTimeInterval(30))
    #expect(shown.ordered.map(\.name) == ["task", "b", "a"])
    #expect(variables.value("task") == nil)
}

@Test func promptBlockListsVariablesInWriteOrderWithNaturalLanguageTime() throws {
    let schema = try schema()
    var variables = AgentStateVariables()
    #expect(try AgentStatePrompt.block(variables).isEmpty)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    try variables.set("mood", "You are angry", source: .model, schema: schema, at: start)
    try variables.set("energy", "low", source: .model, schema: schema, at: start.addingTimeInterval(3600))
    let utc = TimeZone(identifier: "UTC")!
    for language in ["en", "zh-Hans"] {
        let block = try AgentPrompts.$language.withValue(language) {
            try AgentStatePrompt.block(variables, timeZone: utc)
        }
        let mood = try #require(block.range(of: "mood"))
        let energy = try #require(block.range(of: "energy"))
        #expect(mood.lowerBound < energy.lowerBound)
        #expect(block.contains("\"You are angry\""))
        #expect(!block.contains("1800000000"))
    }
    let english = try AgentPrompts.$language.withValue("en") { try AgentStatePrompt.block(variables, timeZone: utc) }
    #expect(english.contains("January 15, 2027"))
    let chinese = try AgentPrompts.$language.withValue("zh-Hans") {
        try AgentStatePrompt.block(variables, timeZone: utc)
    }
    #expect(chinese.contains("2027年1月15日"))
}

@Test func declarationsSectionDescribesMeaningAndValuesButNotAccess() throws {
    let text = try AgentPrompts.$language.withValue("en") { try AgentStatePrompt.declarations(try schema()) }
    #expect(
        text.contains("energy") && text.contains("low, high") && text.contains("quiet") && text.contains("true, false"))
    #expect(!text.localizedCaseInsensitiveContains("read-only") && !text.contains("readOnly"))
    #expect(try AgentStatePrompt.declarations(AgentStateSchema()).isEmpty)
}

@Test func storedVariablesValidateAgainstTheSchema() throws {
    let schema = try schema()
    var variables = AgentStateVariables()
    try variables.set("energy", "low", source: .model, schema: schema)
    try variables.validate(schema: schema)
    let other = try AgentStateSchema([
        declaration(
            #"{"name":"energy","kind":"typed","access":"readWrite","type":"enum","values":["x"],"meaning":"e"}"#)
    ])
    #expect(throws: AgentStateError.invalidValue("energy")) { try variables.validate(schema: other) }
}
