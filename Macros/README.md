# Compile-time Macros

Purpose: generate intrinsic metadata for callable Actions. Design goals: one attribute and no runtime device, Agent or UI dependency.

✅ BehaviorDefinitions emits ActionFunction factories from @Action. Functions share FunctionInput/ActionExecutionContext. Protocol policy is absent from macro arguments and generated metadata; host registration creates ActionBinding separately.

❌ Automatic discovery, dependency construction and permission inference are unsupported. See [macro design](BehaviorDefinitions/README.md) for the generation diagram.
