# AgentCore/Input

Owns generic immutable audio/image input contracts accepted by InputGateway and AgentInput. Foundation is the only import. Callers adapt capability SDK values into these contracts; perception Agents adapt them to model inputs.

✅ AudioInput validates PCM transport without fixing a model sample rate. ImageInput validates geometry, capture metadata and opaque Sendable attachments. Errors describe malformed transport only.

❌ Model preprocessing, receiver session/order policy and UI presentation do not belong here.

```mermaid
flowchart LR
    Caller --> InputGateway --> AgentInput --> Perception
    Perception --> ModelKit
```
