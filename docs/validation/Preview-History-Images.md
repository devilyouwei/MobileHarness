# 预览照片在聊天记录中的读取回归

2026-11-06。用户提供的对话详情截图显示“重试图片”，而模型的多轮请求仍能使用照片。

## 原因与修复范围

ConversationHistoryWorkflow 只接受 BusinessRecordID.media，新 preview_UUID 引用在读取前即被拒绝；Actions 装配的历史图片回调也只调用 StorageMedia.readForInput。两处均未随着照片进入内存缓存／多模态 State 的变化更新。

历史图片现在沿记录引用校验 → Camera 只读图片端口 → 当前缓存或精确已收录所有权查询读取。已保存照片利用已有 camera/album/previewID 关联找回；没有新增数据库字段或图片副本。未保存且已忽略、淘汰或随进程释放的照片显示“图片已释放”，实际 I/O／解码失败仍可重试。历史读取展示原图，不改变模型的最新图／显式选择，不发起推理。旧 media_N 图片保留原有 source/input 验证。

## 自动回归

- ConversationHistoryWorkflowTests：media_N 与 preview_UUID 的记录引用／原始输入校验；未引用和非法 ID 拒绝；预览过期、实际读取错误与后续成功可区分；既有四读取上限和取消测试保持通过。
- StorageSchemaTests.sqlitePreviewHistoryReadsCacheThenSavedOriginalAcrossOwnerReplacement：真实 SQLite 请求详情记录两轮相同预览引用，历史从缓存读到原图而不改变 State；保存后读取；关闭／重开数据库与缓存后仍能从相册找到原图；错误 source/session/input、未收录记录和删除分别不可读。图像为字节读取夹具，原生解码验收独立。
- PhotoFeedbackTests：读取未选择的旧图不加载 State；忽略后不复活。原有多轮图片与持久日志不含临时二进制的测试仍纳入全量检查。

首次定向编译因测试夹具遗漏 capturedAt 参数失败，补齐后定向回归 6 项通过。`./scripts/check.sh` 退出码 0：主集成套件 1060 项及独立原生／时序套件 227 项通过，其他 Swift 套件、Python、边界、严格格式与 plist 检查均通过。`./scripts/build-ios.sh` 退出码 0，MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero 四个构建和资源校验通过。修改文档本地路径检查通过；交付前另检查 diff 格式。

本机自动验证日志：`/tmp/mh-preview-history-targeted.log`、`/tmp/mh-preview-history-check.log`、`/tmp/mh-preview-history-ios.log`。

## 真机与验收边界

签名真机构建 0.1.0 / 2026110607 通过；严格签名、30 项最终 Agent/Skill 资源及 Live Activity 嵌入/版本校验通过。首次安装因 RSD 设备通道分配失败（CoreDeviceError -1 / mobiledevice -402653181）未完成；重新确认连接后重试安装成功（installation sequence 6144）。独立设备清单确认 iPhone 17 Pro 上 dev.mobileharness.app 为 2026110607，未卸载或清空数据。

启动请求因手机锁定被系统拒绝（FBSOpenApplicationErrorDomain / Locked），没有确认启动或截图页面的真机展示。安装和启动不等同截图页面已人工验收；未使用真实视觉模型做新一轮视觉质量测试。更新应用会结束旧进程，只在旧进程内存在且未保存的照片不会因此恢复；已保存的照片通过既有持久关联读取。

当前实现见 [History](../../MobileHarness/Actions/History/README.md#preview-references-in-history)、[Camera](../../MobileHarness/Actions/Camera/README.md#memory-previews-and-multimodal-state)、[UI Settings](../../MobileHarness/UI/Settings/README.md) 和 [Media](../../MobileHarness/Storage/Database/MediaFiles/README.md)。


本机真机证据：`/tmp/mh-preview-history-2026110607-build.log`、`-install.json`、`-install-retry.json`、`-apps-after.json`、`-launch.json`（后四项沿用同一文件名前缀）。
