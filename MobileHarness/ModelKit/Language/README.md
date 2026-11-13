# Language Capability Contracts

## Responsibilities

Language owns provider-neutral conversation and candidate-selection interfaces. Chat consumers supply message history, prompts, tools and optional attachments. Decision consumers supply a question, current text and ordered candidates. The calling Agent owns continuation and interprets model output.

## Data flow

```mermaid
flowchart LR
    Caller["Capability consumer"] -->|ChatRequest| Chat["ChatCapability"]
    Chat --> Gemma["Gemma4 · local text"]
    Chat --> Cloud["OpenAI Responses · configured cloud"]
    Gemma -->|ChatEvent stream| Caller
    Cloud -->|ChatEvent stream| Caller
    Caller -->|DecisionRequest| Decision["DecisionCapability"]
    Decision --> D3["D3Decision · local candidate scoring"]
    D3 -->|candidate / abstention| Caller
```

## Interfaces

[LLM](LLM/README.md) defines messages, images, native function declarations and results, text and usage events, dispatch timing and caller-owned transport observations. Providers publish capability constraints before native work. The local [Gemma4](LLM/Gemma4/README.md) fits an inference copy to its effective window. [OpenAI Responses](LLM/OpenAI/README.md) supports the configured cloud wire protocol and required tool choice.

[JEV](JEV/README.md) owns the Decision values and the D3 implementation in ModelKitD3. Candidate selection is a typed inference result. The caller interprets it and owns routing, interruption and fallback.

[ModelKit](../README.md)
