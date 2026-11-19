# Experiment Instructions

Applies to all work under experiments. Read this file together with the repository-root AGENTS.md and the owning task README before changing or running experiments.

## Scope and implementation

- Use Python only for experiment runners and their offline regressions. Evaluate model cases, prompt variants, accuracy, task success and inference performance.
- Run local Apple Core AI / Core ML artifacts through Python interfaces. Explicit cloud or Apple system-model backends also run directly from Python.
- Do not compile or launch Swift, App code or Tests. App unit tests, business flows, model management and adapter integration belong in Tests.
- Do not import engineering helpers or read Tests data, configurations or results, including indirectly through scripts. Duplicate small mechanisms when necessary to preserve independence.

## Files and ownership

- Organize by task. Task roots own runners, prompts, scoring and configuration; datasets owns input cases, labels and frozen requests.
- Write raw results to `experiments/<Task>/results/`: per-case responses, request traces, scores, machine-generated metrics and environment snapshots.
- Write authored or summarized experiment reports to `docs/validation/`: methods, comparisons, findings, conclusions and limitations. Link to raw results in results; do not copy datasets or raw output into docs. Agent-written reports follow the same rule.
- Use lowercase snake_case directory names, snake_case Python filenames and kebab-case configuration/data/result filenames. Follow the task's existing schemas and naming conventions.
- Shared downloaded artifacts belong in root `Models/<Model>/`. Reuse verified versions from Hugging Face or other explicit URLs instead of downloading another copy. Do not store project helper libraries, datasets or results in Models.
- scripts owns agent-facing batch orchestration, not experiment logic. Use existing script entry points when available; otherwise invoke the task runner directly. Do not import scripts as a shared business library.

## Execution and evidence

- Select the task, input set, model/version, prompt/configuration, request budget, timeout and new output path explicitly. Keep credentials out of source, configuration files and results.
- Keep labels and scoring assertions out of model requests. Preserve input/configuration provenance, raw failures and incomplete runs; never fabricate success or overwrite existing evidence.
- Distinguish offline runner checks from real model evaluation. Report failed and unexecuted cases, sample counts, warmups, environment and comparison limitations. Do not infer model quality from a single communication check.
- Run heavy model experiments separately from timing-sensitive engineering tests. Batch execution must retain each task's failure status.
- When cleaning or merging data, inspect contents and references, preserve meaningful failure evidence and provenance, and update consumers and report links. Matching schemas alone do not establish duplicate data.

Shared research-only transports, execution and decoding mechanisms belong in `utils/`. Task-specific adapters, prompts and scoring stay with their task. Do not move engineering helpers here.
