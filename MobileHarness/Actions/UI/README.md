# UI — Caption and Expression Actions

Purpose: present captions and facial expressions using App-injected callbacks. Design goals: keep validation and output selection inside each function, remain independent of SwiftUI, and use one function for all expressions.

- ✅ `Print.swift` / `UI.print`: required nonblank text, at most 2000 UTF-8 bytes; preserves original formatting.
- ✅ `Express.swift` / `UI.express`: required, case-sensitive `emotion`: smile (🙂), happy (😊), laugh (😄), thinking (🤔), surprised (😮), sad (😔), love (🥰).
- ✅ Missing or unsupported emotion throws `ExpressionError.invalidEmotion` before presentation; no default or fallback. The separate smile function and registration are removed.
- ✅ Both functions check cancellation before and after presentation and propagate callback failures. No shared TextAction helper is used.
- ✅ Default Display Channel; explicit scopes can override it. Gateway owns ordering and module exclusion.
- ❌ Physical facial control, general show actions and animation-completion acknowledgments.

App injects separate expression and caption callbacks. Success means MainActor display state has been updated, not that the decorative animation has completed. One current expression replaces the previous state; no extra queue or timer is created. The circle clears on new user speech or session stop. XML example: `<express emotion="smile"/> Hello.`

Maintain this README alongside implementation, Agent JSON and App handler bindings. Add new supported emotions to express rather than adding a separate Action for each face.
