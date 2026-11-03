import FunctionContracts

@ActionCatalog
public struct WebModule: CapabilityModule {
    private let web: any WebCapability
    public init(web: any WebCapability) { self.web = web }
    public var definitions: [ActionFunction] {
        [
            WebActions.browseDefinition(completing: { [web] in
                .value(try await WebActions.browse(invocation: $0, using: web))
            }),
            WebActions.snapshotDefinition(completing: { [web] in
                .value(try await WebActions.snapshot(invocation: $0, using: web))
            }),
            WebActions.inspectDefinition(completing: { [web] in
                .value(try await WebActions.inspect(invocation: $0, using: web))
            }),
            WebActions.navigateDefinition(completing: { [web] in
                .value(try await WebActions.navigate(invocation: $0, using: web))
            }),
            WebActions.developDefinition(completing: { [web] in
                .value(try await WebActions.develop(invocation: $0, using: web))
            }),
            WebActions.openDefinition(completing: { [web] in
                .value(try await WebActions.open(invocation: $0, using: web))
            }),
            WebActions.projectsDefinition(completing: { [web] in
                .value(try await WebActions.projects(invocation: $0, using: web))
            }),
            WebActions.deleteDefinition(completing: { [web] in
                .value(try await WebActions.delete(invocation: $0, using: web))
            }),
        ]
    }
}
