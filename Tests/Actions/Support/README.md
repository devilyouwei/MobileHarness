# Support tests

## 执行与时钟隔离

普通用例并发执行，LiveRuntimeTests 与原生窗口用例在独立阶段串行执行；任一阶段失败仍执行另一阶段并返回失败。涉及真实捕获新鲜度、机械期限、媒体到期和进程级 AppKit 状态的用例使用该阶段，用例内部业务并发仍保留。合成突发用例可显式注入采样间隔；默认 cadence／freshness 用例继续校验生产预算。

## 文件归属

- [ActionCatalogFixture.swift](ActionCatalogFixture.swift)
- [ActionTestRegistry.swift](ActionTestRegistry.swift)
- [BehaviorContractFixtures.swift](BehaviorContractFixtures.swift)
- [ResolvedCallSupport.swift](ResolvedCallSupport.swift)
