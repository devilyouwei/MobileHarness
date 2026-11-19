# System tests

函数契约与能力执行中本目录能力的测试。测试通过真实接口及显式替身验证可观察行为、失败、取消和清理；真实模型及设备用例保留显式 gate。

## 文件归属

- [ProviderDiscoveryTests.swift](ProviderDiscoveryTests.swift)
- [ProviderSettingsTests.swift](ProviderSettingsTests.swift)
- [ResourceInventoryTests.swift](ResourceInventoryTests.swift)
- [ResourcePreferencesTests.swift](ResourcePreferencesTests.swift)

Provider 设置新增多 URL 配置重开恢复、删除清理及普通文档无密钥回归。

Provider 名称持久化、默认名称生成、独立弹窗草稿、重复 URL 和空名称校验由自动化回归覆盖；原生弹窗布局与粘贴需设备验收。

providerSettingsStagesHTTPIPConfiguration 覆盖 HTTP/HTTPS IP provider 的私有保存请求准入；使用替身服务，不代表真机局域网连通性。
