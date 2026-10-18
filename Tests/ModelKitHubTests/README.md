# ModelKitHub tests

Purpose: verify the concrete Hub download integration. Design goals: reject unsafe paths, select regular files only, and distinguish network acceptance from offline regression checks.

Offline tests cover directory exclusion, glob selection and unsafe/oversized remote metadata rejection.
HARNESS_TEST_HUB_ENDPOINT enables an actual Silero download through the production adapter, asserts intermediate progress and required files, and cleans its temporary staging.

Persisted complete-file plans resume without network access; unsafe/reserved/oversized plans fail.

## 待实现

- iPhone 下载进度呈现、后台生命周期和大文件续传验收。

✅ 完整文件／持久计划的离线恢复及元数据边界回归覆盖本地复用；网络下载和 iPhone 后台验收独立进行，不由离线测试替代。
