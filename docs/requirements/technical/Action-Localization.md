# Action 多语言说明内聚需求

## 目标

Action 面向模型的说明（`doc`、参数描述、`constraints`）归 Actions 拥有。默认语言文案仍写在 `@Action` 声明里；其他语言的翻译作为 Actions 资源，放在 `Actions/Resources` 并与 Actions 代码目录镜像（实现后由 Actions 自有 target 打包，见 [Module-Owned-Resources](Module-Owned-Resources.md)）。Agents 只按语言向 Actions 取得本地化后的声明，不再持有 `Resources/Agents/Shared/FunctionCopy.zh-Hans.json`。

## 现状与问题

- 74 个函数的中文说明集中在 `FunctionCopy.zh-Hans.json`，由 `AgentConfigurations.functionCopy()` 与 `localized(_:copy:)` 叠加到 Actions 目录上。
- 翻译离声明远，没有 key、参数名、约束一致性的校验；缺文件、缺条目静默回退。
- 新增语言需要在 Agents 共享目录新增整份大文件。

## 设计

### 资源布局

```
Actions/Resources/
  Localization/
    UI/Runtime/Island.zh-Hans.json      // 与 Actions/UI/Runtime 的 Island 模块镜像
    Camera/Capture.zh-Hans.json
    ...
```

- 文件名 `<Module>.<language>.json`，路径为 `Localization/<Domain>/<Module>.<language>.json`，与声明的 domain、module 对应。`en` 不建文件，默认语言就是 `@Action` 中的文本。
- 内容以模块内函数名为 key：`description`、`parameters.<name>.description`、`parameters.<name>.constraints`；不含路径前缀、流程教学或示例（示例仍归 Skill 的 Instructions）。
- `Actions/Resources` 还可承载 Action 需要的其他随包资源，语言只是其中一类。

### 打包与加载

- `Actions/Resources` 只放静态文件（无 Swift），由 `Actions` target 以 `.copy("Resources/Localization")` 打入 `HarnessKit_Actions.bundle` 的 `Localization/`。Actions 提供 `ActionLocalization.translations(for:)`，经 `Bundle.module` 读取，由 App 连同声明注入 Agents（Agents 不依赖 Actions）。
- Actions 提供 `localized(declaration, language:)`：先取 `@Action` 声明（默认语言），再用对应语言翻译覆盖。语言无翻译文件、模块无条目、函数或参数缺条目时，该部分保持声明里的文本。
- 接口只读，不引入 Agents、Gateway、App 依赖。

### 校验

- 离线测试（Tests/）校验每个翻译 key 对应实际存在的 Action 与参数，没有孤立 key，约束与参数集合一致；缺失翻译不阻断运行；测试要求所有被 Skill `useActions` 绑定的模型可见 Action 都有 zh-Hans 翻译，仅应用内部 Action（UI 呈现、历史与设置等）可只保留英文默认文案。
- 文件解码失败、重复 key 为明确配置错误，不静默回退。仅“文件不存在”视为该语言无翻译。

### Agents 侧

- `AgentConfigurations` 删除 `functionCopy`、`AgentFunctionCopy`、`localized(_:copy:)`，改为调用 Actions 的本地化接口。
- `Agent.Writer.*` 属于 Agents 自有的原生 Tool 声明，4 条翻译从 FunctionCopy 迁到 Agents 自己的 Writer 资源（`Resources/Agents/Writer` 的 `.zh-Hans` sibling），由 Writer 拥有，不进入 `Actions/Resources`。

## 范围与迁移

一次迁完 FunctionCopy 全部条目（Actions 域条目拆到各模块文件，Writer 条目迁到 Agents Writer 资源），然后删除 FunctionCopy。

## 受影响文档与文件

- `Package.swift`：`Actions` target 增加 `.copy("Resources/Localization")`，不再有独立资源 target。
- `Resources/README.md`、`Resources/Agents/README.md`：删除 FunctionCopy 描述，补 `Actions/Resources` 的布局和打包契约。
- `Actions/README.md`：边界改为 Actions 拥有函数契约说明及其翻译，流程教学与示例仍归 Skill；新增本地化接口说明。
- `Agents` 相关 README：Agents 通过 Actions 接口取本地化声明。
- `MobileHarness/README.md`：如涉及模块依赖与资源流则同步。

## 验收

- `./scripts/check.sh` 通过，完整 Xcode 可用时 `./scripts/build-ios.sh` 通过。
- 中文模型提示中的 Action 声明与迁移前逐项一致（用迁移前后的目录快照比较）。
- 删除 FunctionCopy 后无残留引用。
