# Function Contract Tests

Purpose: verify standard callable contracts independently of Gateway, execution SDKs and business modules. Design goals: concrete standard inputs, injected reporting and intrinsic metadata preservation.

This target depends only on FunctionContracts. The fixture invokes one function with an ordinary FunctionInvocation and a test-owned bounded report sink.

## Action timeout contract

验证基础默认 timeout、动态优先与异常不回退、无效静态值和预算上限，独立于 Gateway。

## Committed business references

Runtime fixtures use opaque UUID strings; committed business entities use dialog/message/task/media/device database IDs. Independent repository interfaces preserve ownership/cancellation and foundation boundaries. Completed messages (including each ReACT message) persist individually, without delta fragments or old allocator/file-index compatibility. See the project SQLite business-record plan.

## 待实现

- 暂无本目录独立实现待办；Agent 授权与物理/模型验收由上层负责。
