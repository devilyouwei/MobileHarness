# Application localization validation

## 2026-11-14

- `./scripts/build-ios.sh` built the Simulator application and three ModelKit schemes. The bundle checks found both sets of permission strings, the Simplified Chinese UI catalog, both WidgetKit status catalogs, and 73 Agent and Skill assets. The template check compares English and Simplified Chinese template keys and placeholders.
- On an isolated iPhone 18 Pro simulator running iOS 27.0, XCUITest used the App Language picker to switch from English to Simplified Chinese, checked that the Settings page stayed visible, relaunched the app, verified the Chinese setting persisted, and switched back to English. One test passed against the final build. The Xcode result bundle is `/tmp/mobileharness-i18n-ui/LanguageRetest.xcresult`.
- The automated locale checks exercise first-language selection, unsupported-language fallback, explicit overrides, translated UI and model resources, reserved history markers, tool identity and schema compatibility, speech sample editing, and selection of the Apple recognition resource through the managed speech selector. Writer tests cover bilingual labels for legacy and current request phases, English recovery evidence, and Chinese Markdown diagram labels with English renderer diagnostics. These use fixtures and bundled resources.
- `./scripts/check.sh` passed when run without a concurrent iOS build. The integration, app workflow and Live Runtime runs reported 1,153, 192 and 228 tests, respectively. A previous concurrent run had seven timing or ordering failures across five tests. All five passed a focused serial rerun before the full check passed.
- The existing D3 artifact tokenizer measured 267–303 tokens for four short photo-confirmation samples covering both prompt locales and both input languages. All four fit the 512-token limit. This measures tokenization for those samples.
- A local Core AI smoke test used the installed D3 artifact and the app's Decision templates in eight combinations of prompt locale, input language, and intent. All four confirmation cases returned `enqueue`. Both locales returned `interrupt` for the English stop request. The Simplified Chinese template returned `interrupt` for the Chinese stop request after reinforcing the immediate-stop instruction. The English template and the pre-change baseline both returned `enqueue` for that Chinese stop sample. The final requests used 291–319 tokens. This was an exploratory four-input test; it does not establish classification accuracy.

Physical-device permission dialogs, Lock Screen and Dynamic Island presentation, microphone recognition in both Apple locales, Nemotron automatic recognition, and real-model cross-language Assistant and Writer behavior require separate device and model acceptance.

The later [Decision language comparison](Decision-Model-Mac-Comparison.md#decision-prompt-language-split) runs the current Swift classifier with both prompt locales and the prior mixed prompt on the same bilingual scenarios. It records both raw classifications and adopted dispositions.

## Execution Log title and download-source copy (2026-11-14)

The Execution Log panel title and entry accessibility label now resolve the environment locale through AppLanguage. English displays Execution Log; Chinese displays 执行日志. The shared download-source label displays Hugging Face in both languages without Official/官方.

The focused `applicationLanguageResolvesSystemFallbackAndRestoresOverrides` test passed, including both titles and both source labels. Final `scripts/build-ios.sh` passed all four targets and bundle checks. Swift formatting, catalog parsing and `git diff --check` passed. `scripts/check.sh` was attempted but blocked at manifest inspection by sandbox writes to compiler caches; this follow-up does not claim a full-suite pass. Logs: `/tmp/mobileharness-title-tests.log`, `/tmp/mobileharness-title-ios.log`, `/tmp/mobileharness-title-check.log`. No new native UI interaction acceptance was performed.

## Role and Skill resource ownership (2026-11-28)

Verified one Xcode file reference per localized declaration and membership in the same group as its canonical sibling for all six roles and eight Skills. All five simulator schemes built. The rebuilt app passed the byte-for-byte check for 92 Agent and Skill assets and the compiled English and Simplified Chinese checks for App, UI and Live Activity. Three focused Swift tests passed, covering language selection, localized interruption history, and prompt markers and tool schemas. The engineering check advanced past project grouping and stopped at the separate production model catalog check.

## Markdown descriptions for discovery (2026-11-28)

Verified all 28 description files for six Agents and eight Skills against the owner-specific paths in the Xcode project and simulator bundle. The bilingual discovery test reads each language through the production loader. The filtered Swift runs completed 119 and 2 tests successfully. All five simulator schemes built; the main App passed the 107-asset Agent/Skill bundle check and compiled English and Simplified Chinese localization checks. The full engineering check stopped at the separate production model catalog check.

## Agent and Skill bilingual resource audit / Agent 与 Skill 双语资源核对

All six roles and eight Skills have localized public descriptions. Across the eight English and Simplified Chinese tutorials, example calls resolve to the loaded Skill aliases and use declared parameter names. The prompt, Skill and localization test selection passed 121 Swift tests. All five simulator schemes built. The rebuilt App matched all 105 Agent bundle assets byte for byte and excluded the developer guides.

六个角色及八个 Skill 均有双语公开简介。八份教程的中英文调用示例均能匹配已加载的别名和声明参数。相关 Swift 测试通过 121 项，五个模拟器 scheme 构建通过。最终 App 中的 105 份 Agent 资源与源码逐字节一致，开发指南已排除。

The full repository check stopped at the production model catalog assertion. Its expected package set omits kokoro-82m, smart-turn and zipformer-kws. No physical-device or real-model run was performed.
全量仓库检查在生产模型清单断言处停止。检查脚本的预期集合缺少 kokoro-82m、smart-turn 和 zipformer-kws。本次未运行真机或真实模型。
