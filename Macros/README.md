# Compile-time Macros

Purpose: generate intrinsic metadata for callable Actions. Design goals: one attribute and no runtime device, Agent or UI dependency.

✅ BehaviorDefinitions emits ActionFunction factories from @Action. Functions share FunctionInput/ActionExecutionContext. Protocol policy is absent from macro arguments and generated metadata; host registration creates ActionBinding separately.

❌ Automatic discovery, dependency construction and permission inference are unsupported. See [macro design](BehaviorDefinitions/README.md) for the generation diagram.

## Action-owned documentation and Skill instruction contract

✅ `@Action` 生成同名 Declaration 值与两个 Definition 工厂，二者使用同一声明。`@ActionCatalog` 读取被标注模块的现有函数工厂调用，生成 declarations；仅本地 AST 分析，无反射或全局自动注册。域组合仍由 CapabilityModules 显式完成。

## Channel-owned Action ordering

✅ @Action and generated ActionFunction factories have no serialization argument or implicit exclusion. Host scheduling stays outside macro generation.

## Action timeout contract (2026-10-12)

✅ @Action 动态预算参数统一为 dynamicTimeout；生成工厂保留静态 timeout，缺省归一由 ActionFunction 处理。
