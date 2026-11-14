# English and Simplified Chinese

Keep the existing modules, targets, routes, databases, and execution contracts. Use existing resource directories and add no package dependencies.

- **App and UI.** Store System, Simplified Chinese, or English in one local preference. Resolve the first system preferred language to Simplified Chinese for Chinese and English otherwise. Refresh on foreground. Pass the resolved locale into the existing SwiftUI root and an instance-scoped language reader into the existing Agent and speech composition. Changing language preserves the application scope, navigation, and in-flight work.
- **Presentation and packaging.** Use English-source String Catalogs in the existing UI, app and extension targets. Localize built-in controls, accessibility, operation notices, model display names and speech examples. Resolve Bluetooth status and recovery summaries in the settings view and keep protocol failure details in English. Use the Writer delegation language snapshot for progress and the app language for new history views. Keep entered, generated and recorded text verbatim. Normalize earlier Writer phase labels when restoring and presenting history, and keep English diagnostic details, error codes and actual model request evidence. The OS selects localized permission strings. An optional Live Activity locale lets the extension render status labels from snapshots, including legacy snapshots.
- **Agents and Resources.** Resolve English and Simplified Chinese resources in the existing Agent prompt loader. Keep instruction, example and template ownership by role and Skill. Snapshot application language for a model operation and its continuations. Keep XML, JSON and Tool identifiers, history attribution rules and routing contracts stable. Use the user’s explicitly requested language or the language of trusted user content for replies and artifacts, with application language as the default. Use the original conversation for titles.
  The Simplified Chinese Decision instructions explicitly distinguish an immediate stop during playback from an answer or a filler. Continue to use the existing conservative admission rules for uncertain or misclassified input.
- **ModelKit.** Preserve native model ownership and leases. The existing speech selector supplies the application’s Apple recognition locale for future segments. Nemotron keeps automatic multilingual recognition and speech synthesis follows the output text. Model IDs, cloud configuration and diagnostic evidence retain their existing roles.

Update the owning App, UI, Agents, Actions, Resources, and ModelKit READMEs and overall design after implementation. Keep existing documentation in its current language and document the new technical behavior in English.

## Acceptance

Verify preference resolution, immediate UI switching and persistence, record compatibility, catalog and template parity, placeholder and protocol stability, bilingual model requests, English diagnostic infrastructure and Apple recognition selection. Run repository checks and the iOS build. Record simulator, physical device and real model evidence separately. Device and real model scenarios include cross-language conversation and Writer output, photography, interruptions, native permission prompts, Live Activity, Apple recognition and Nemotron auto recognition. See [validation evidence](../validation/App-Localization.md).

For Decision, run an opt-in local D3 experiment through the production request renderer, model and adoption policy. Run paired English and Chinese synthetic transcripts under both shipped prompt locales and the previously recorded mixed prompt. Report model choices and adopted outcomes by language pair, alongside false discards, false and missed interruptions, fallbacks, and warm latency. Probe the context limit with saturated examples. Keep the runner in `scripts/`, the native test in `Tests/IntegrationTests/`, and the fixture and results in `docs/measurements/`. See the [Decision comparison report](../validation/Decision-Model-Mac-Comparison.md#decision-prompt-language-split).

## Remaining coverage

On device, verify system permissions and Live Activity presentation, Apple recognition in both locales, and Nemotron automatic recognition. Run the Assistant and Writer cross-language flows with the configured real models. The local D3 smoke test still misses one sample of a Chinese stop request with English prompts, also reproduced on the previous configuration.

## Execution Log 标题修正（2026-11-14）

RuntimeLogView 的面板标题和首页入口 accessibility label 通过环境 locale 与 AppLanguage 解析；共享字符串目录增加 Execution Log → 执行日志。应用语言切换后标题随视图刷新，日志数据、筛选和导航状态保持原有契约。更新 RuntimeLog README，并在已有语言测试验证中英标题。
