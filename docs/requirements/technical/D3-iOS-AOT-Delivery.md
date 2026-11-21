# D3 iOS AOT delivery

## Goal

Publish pinned iOS ahead-of-time compiled Edge/Lite artifacts to their existing Hugging Face repositories and make the application acquire and load the correct device variant. Preserve source artifacts and Mac benchmark inputs. Do not change prompts, decision semantics or adoption rules.

## Plan and ownership

- Compile the existing fixed source graphs using Xcode 27.2 / Metal Toolchain 27B47, iOS 27.0, default compute placement. First verify Lite compilation and SDK architecture support before extending to other variants.
- Publish complete compiled bundles, tokenizer/configuration/license files and build provenance under versioned iOS paths. Pin resulting remote commits only after upload verification.
- ModelKit CoreAI owns native architecture discovery; D3 owns graph-file selection and explicit missing/incompatible variant failures. The first AOT variant targets h18p (the existing iPhone 17 Pro / Pro Max production hardware contract). Optional catalog architecture variants override source, required files and size before configuration; other architectures retain the existing source package. D3 manifests with compiled_models require an exact native architecture match and never silently use another compiled graph. Source manifests remain supported for Mac tests and devices without an AOT variant. Defaults supplies the native architecture through D3/CoreAI; Runtime only resolves declarative variants. Acquisition/storage retain current integrity and atomic publication contracts.
- Update Resources/Models/model-catalog.json with verified revisions, file patterns, required files and sizes. Avoid downloading every architecture onto each phone. Existing Mac benchmark profiles retain source graphs.
- Reconcile the owning ModelKit, CoreAI, JEV, Resources documentation with implemented changes; update overall design if cross-module wiring changes.

## Validation

Verify AOT compile completion, full bundle inventory/hashes, remote uploaded revision, and cold physical-device loading before claiming the Lite issue resolved. Compare existing native fixtures and decision test scores; cover missing/incompatible architecture and selection behavior in automated tests. Run scripts/check.sh and scripts/build-ios.sh after code changes. Compilation alone does not prove inference parity or physical-device acceptance.

## Progress

Edge and Lite h18p AOT compilation and HF publication completed. Every remote file size and content hash matches the local inventory. The production catalog pins per-architecture revisions and full required-file inventories. Architecture resolution and compiled-manifest loading are implemented; source defaults remain for other architectures and Mac benchmarks. Technical READMEs describe these contracts.

All five build-ios targets and the signed physical-device build passed. ModelKit runtime and isolated timing regression tests passed. Full check.sh has AppWorkflowTests missing-resource failures and a stalled Writer cancellation test; details are preserved in [validation](../../validation/D3-iOS-AOT.md). Final production-catalog tests passed (49 ModelKitRuntime tests plus 2 isolated timing regressions); packaged resources were verified and the signed App was installed on iPhone 17 Pro. Physical-device cold-load/inference parity remains tracked there. The loading issue is not declared fixed by compilation alone.

## 2026-11-15 Lite native load crash investigation

User reports Edge AOT loads normally but Lite crashes. Two device reports at 23:42 show the same EXC_BAD_ACCESS/SIGSEGV in MPSGraphAICodeCompilerDelegate getInitializedAICodeBytecodeWithPayloadPrefix:delegateId:, reached through D3Graph/GraphModel initialization. The installed receipt pins the published Lite AOT commit and all 19 required paths/sizes match. This establishes a native load crash, not a jetsam termination, but does not yet isolate compiler compatibility, graph structure, options or content integrity. Preserve device artifacts while checking full resource hashes. No model preference, source profile or published package should be replaced by an unvalidated workaround. A GPU-preference compile can be used as an isolated comparison if needed; it must not be described as a proven fix or an exclusion of ANE.

Investigation result: full SHA-256 verification of all 19 installed files passed. Two identical native compiler crashes establish failed Lite device acceptance; root trigger and remediation remain unresolved. Preserve the published evidence and do not claim success from compile/build alone. Details and limitations are in the linked validation report.

## 2026-11-16 Edge 改回源图下载

用户要求 App D3 Edge 与 Mac 实验使用相同的原始 Core AI 制品。删除 catalog 中 Edge 的 h18p architectureVariants 覆盖，所有架构统一固定 hugging-mac/d3-edge-CoreAI revision 0690c04ee1640c1c3fa11a882323751dda6d086a 的 decision.aimodel 与配套tokenizer/config/manifest。保留 Lite 的配置和通用架构选择能力，不修改提示词和采纳策略。远端固定revision与Mac本地文件逐项核对；更新生产catalog回归和Resources说明。旧AOT收据应失配，不能把改配置表述为已替换手机模型；使用原有删除/下载流程更新模型，不手改收据。执行check.sh/build-ios.sh，记录限制和历史提示实验成绩。

Edge源图选择已实施；远端固定版本与Mac本地12文件内容匹配，生产目录回归通过。构建及设备部署状态见[验证记录](../../validation/D3-iOS-AOT.md#edge-source-package-selection-restored--2026-11-17)。

## 2026-11-17 独立发布者制品真机对照

用户要求改用第三方D3 Edge CoreAI制品供真机测试。选择maxffarrell/d3-edge-CoreAI固定revision ffa8431fe8dd5209f3ec2c8bf59afc829ec96c31，只替换Edge的source/revision和下载大小，保留模型ID、目录、提示及采纳策略。只下载decision.aimodel与文本配套文件，不下载vision图。现有D3Graph支持其五输入接口，并为纯文本传零visual_embeddings/visual_mask；无需增加推理兜底。更新catalog回归与Resources现行说明，核对远端manifest/readout/tokenizer兼容，构建安装后用户通过Agent Models移除旧Edge并下载第三方版本。

该制品的上游revision与hugging-mac旧制品不同，不能把测试解释为“只改变编译器、权重完全相同”；发布方也未声明iPhone验收通过。保存已取得的Hello请求与手机原制品元数据证据，剩余实验不阻塞本次配置切换。

第三方来源已配置并完成真机App安装启动，生产catalog回归、五个iOS构建和签名资源校验通过；全量检查失败范围及用户需重下模型的步骤见验证记录。未声称第三方制品已在手机完成推理验收。

## 2026-11-17 恢复自有源图并开展提示对照

用户反馈第三方制品也频繁discard，要求恢复自己的repo及文件清单。将Edge完整source/requiredFiles恢复为experiments/decision/benchmark/models.json中已固定的hugging-mac原始decision.aimodel声明，大小恢复1013189709，不启用iOS AOT，不改变Lite。同步目录回归和现行说明。本轮提示优化只在实验请求中进行，先对现有minimal、仅补充入队定义中的问候/命令、仅明确discard不可理解边界、两项合并进行单因素/组合对照；使用原48条样例和6条诊断并补Hello，历史留出已多次观察，称回归集，不称新独立留出。保留输入/输出和错误，不新增模型结果覆盖代码，不自动把最优实验方案写入App。

首轮220条完成，minimal基线18/48，收窄discard为24/48但继续聆听仍0/16，补问候定义仅8/48。追加预先固定对照：历史utterance_status原样参考、仅将ASR marker短语替换为unintelligible text、仅保留无待答问题的hesitation定义、替换为无可识别话语定义；其余上下文和选项不变。历史ASR描述只作已存档控制，绝不恢复生产噪声词表或声称ASR提供该标签。

自有repo与文件清单已恢复并安装真机；锁屏未启动。两轮440条提示评分完成，未发现可上线候选，生产提示保持原样。结果与验证限制见原Mac报告的discard边界对照及D3制品记录。

## D3 超长输入裁剪

- ModelKit 的 `Language/JEV/D3Decision.swift` 在完整聊天模板分词后保留末尾最多 512 个 token，再生成左填充的输入、注意力掩码及四组位置；不由 Assistant 或调用者裁剪。短输入保持原样，空 token 序列和无法表示的 token ID 仍明确失败。裁剪可能移除系统提示、上下文或极长问题及选项的前部，不保证模型效果。
- 在现有 `DecisionAdapterNativeTests.swift` 使用无权重测试覆盖短、恰好 512、超长及无效 token，以及张量输入布局；`D3NativeTests.swift` 的可选真实模型用例验证超长请求完成，保留原短输入回归。
- 实现后同步 JEV 和 Defaults 测试 README，执行定向测试与 `scripts/check.sh`；完整 Xcode 可用时执行 `scripts/build-ios.sh`。真实模型和物理设备结果单独报告。

实现及 Mac 真实模型验证完成；全量检查未通过，真机验收未执行，见[验证记录](../../validation/D3-iOS-AOT.md#d3-input-truncation--2026-11-21)。
