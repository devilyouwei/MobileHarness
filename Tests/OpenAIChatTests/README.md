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
| 计时与清理 | 首个有效文本时间、幂等 start、实际清理屏障、并发请求拒绝、共享句柄替换与卸载；native 参数增量首样本、空增量/私有推理忽略、文本/native 先到者及终态前不发布调用 |

## 显式在线探针

liveProviderPreservesConsecutiveUsers 从调用进程获取 HARNESS_LIVE_CHAT_URL/KEY/MODEL，用合成连续 user 历史调用实际 Chat 能力并加入资源清理。失败时执行一次显式诊断请求，保留有界且脱敏的错误；不输出密钥、用户历史或私有 reasoning。探针结果归 [validation](../../docs/validation/README.md)。

## 待实现

- 真实第三方 Provider 兼容性、认证与 iPhone 网络生命周期验收，需要显式提供端点/凭据。

✅ 离线 SSE fixtures 覆盖缓存读取/写入缺失、零、有效值和非法类型/范围，不访问真实 API。

✅ 离线编码验证固定 system、完整 native 调用/结果组和后置 system 事实的顺序保持，不混入用户正文。

✅ 将千问实测的无后缀/未声明 native 名称归一为合成身份 fixture，验证当前解码器在 output_item.added 明确拒绝并不输出调用；这描述当前失败边界，不将其记为名称兼容已修复。


## 分类异常诊断

✅ 离线 SSE 回归精确断言未声明/缺失名称、身份、顺序、参数格式及增量不一致、终态、用量和脱敏有界诊断；不放宽错误为接受，不运行云请求。

✅ providerAcceptsHTTPAndHTTPSIPAddressesWithoutChangingRequestScheme 覆盖 HTTP/HTTPS IPv4、IPv6 与端口路径，验证 Responses 请求保留 scheme；无效协议、URL 凭据和 query 仍拒绝。不调用真实网络。


Reasoning summary regressions cover filtering, malformed indices/parts, truncation and preserved native-call indices. liveOllamaResponsesReasoningCompatibility is opt-in via HARNESS_LIVE_OLLAMA=1 plus HARNESS_LIVE_CHAT_URL/MODEL; it uses no API key, synthetic prompts/tool receipts, and validates text, one native call and a continuation without device effects. [Validation evidence](../../docs/validation/Provider-Management.md).

思考策略编码测试分别验证 minimum/enabled：关闭、最低支持档位、启用推理时 temperature 兼容、普通模型不接收未知参数及 DashScope 参数隔离。仅离线构造实际请求 JSON，不冒称远程模型已接受。

HTTP/传输诊断回归覆盖实际URLSession请求路径的timeout数值、DNS/TLS/离线/断连/取消分类、HTTP状态与请求ID/参数/服务端错误的脱敏保留；持续SSE心跳可超过idle timeout总时长完成，资源时限不被设成idle值。网络由URLProtocol替身提供，不能作为真实服务端验收。

Responses framing regressions cover deltas and repeated terminal output exceeding64KiB, valid Unicode chunk boundaries and streams exceeding8MiB. Bounded event queues remain separate from total output; malformed protocol and native arguments still fail explicitly.

Shared-client concurrency uses twelve held URLProtocol requests against one actual OpenAIChat/resource context. It verifies per-session cancellation, continued occupancy by other requests and joined root shutdown; no real provider requests are issued.

Large native-argument regression streams payloads beyond 4 KiB and 64 KiB, validates terminal identity/arguments and reserializes a paired transcript without truncation.
