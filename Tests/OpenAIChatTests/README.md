# Cloud chat tests

## 职责与边界

使用 URLProtocol 夹具验证 OpenAI-compatible Responses 适配器的请求、流解析和 ModelManager 生命周期。默认运行不访问网络或凭据；Agent Task/Skill、Gateway 和 UI 的行为由各自测试目录覆盖。

## 当前覆盖

| 范围 | 用例契约 |
| --- | --- |
| 请求与配置 | URL/auth、空端点与空凭据、模型列表及替换失败保留、原始发现 ID、store=false、可选 token 预算 |
| 消息与媒体 | 连续 user 消息边界、text/image 顺序、assistant output_text、图片限制、原生 call/output 完整配对、已释放函数的历史配对 |
| 函数定义 | strict=false、required 保持可选属性语义、当前定义/输出映射与历史名称分离 |
| 流与背压 | 字节级 Unicode、CRLF/多行 SSE、慢消费和暂停、终态 usage、取消/卸载/关闭后复用与拒绝 |
| 失败 | HTTP 安全分类、credit_balance_exhausted、缺失/错误/重复 usage、拒绝/截断/未知或超限输出、无效配置 |
| reasoning | Alibaba reasoning item/delta/done 的结构验证与私有文本过滤、native 输出 index 与配对保持、非思考请求选项及强制思考模型拒绝 |
| 计时与清理 | 首个有效文本时间、幂等 start、实际清理屏障、并发请求拒绝、共享句柄替换与卸载 |

## 显式在线探针

liveProviderPreservesConsecutiveUsers 从调用进程获取 HARNESS_LIVE_CHAT_URL/KEY/MODEL，用合成连续 user 历史调用实际 Chat 能力并加入资源清理。失败时执行一次显式诊断请求，保留有界且脱敏的错误；不输出密钥、用户历史或私有 reasoning。探针结果归 [validation](../../docs/validation/README.md)。

## 待实现

- 真实第三方 Provider 兼容性、认证与 iPhone 网络生命周期验收，需要显式提供端点/凭据。
