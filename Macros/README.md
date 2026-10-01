# Compile-time macros

Purpose: build-time source generation shared by Actions and Tools. No runtime device, Agent or UI dependencies.

✅ BehaviorDefinitions generates explicit metadata factories from `@Action` / `@Tool` on static functions. Host bindings and Agent JSON permissions stay explicit.
❌ Automatic discovery, dependency construction and device policies are intentionally unsupported.
