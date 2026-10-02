# Technical concepts

## Signal → Cognition → Action

The biological analogy describes functional organization: sensing provides signals, cognitive processes interpret them, and behavior changes what can be sensed next. It is an architectural metaphor rather than a claim to reproduce biological intelligence.

| Concept | Meaning | Biological analogy |
| --- | --- | --- |
| Signal | Typed input/observation carrying source and processing context. | Sensory and inter-region signals. |
| Agent | Stateful processor with a distinct role, input ownership and permitted outputs. | Specialized functional brain region. |
| Gateway | Validation, communication routing and execution coordination boundary. | Neural pathways coordinating signals and commands. |
| Capability | Typed model/device/data operation supplied to a consumer. | Processing machinery or sensory/effector capacity. |
| Action | Permission-checked skill executed under scheduling and completion rules. | Coordinated motor skill. |
| Tool | Direct registered function with result or completion semantics. | Immediately available focused function. |
| App / UI | Whole-system lifetime/composition and user-facing interaction. | Organism and expressive surface. |
| Storage / Types | Retained data and shared value vocabulary. | Retained information and signal representation. |

## Communication and execution

Publication selects declared subscribers; directed delivery selects an explicit recipient. Admission means acceptance for processing rather than completed inference or behavior. Agent messages and Tool/Action results return through the input boundary.

Function Token is a mixed natural-text/XML behavior protocol, not a tokenizer token. Agents interpret it and resolve aliases before execution. A Channel is a task-local Action ordering scope. A wait group joins relevant Action work without making unrelated tasks share a global barrier. Tools bypass Channel queues but still obey permission/resource checks.

A capability call is foundational processing, such as inference or data retention. A business effect, such as playback, UI presentation or robot movement, is a registered Action/Tool. This distinction keeps model computation separate from effect authorization.

## Identity, ownership and completion

Session/turn/input identity separates current work from stale output. The owner of an operation retains its resources through cleanup. Model generation completion, Action handler completion, speaker drain and rendered-frame completion are distinct milestones.

Model residency is separate from model operation ownership. A retained capability does not imply active inference, and cancelling an operation does not itself require unloading weights. Shared value types carry data rather than service lifetimes.

## Directions beyond the current implementation

Edge/cloud collaboration means explicitly selecting remote processing where provided; it does not imply automatic compute escalation. Fast/slow cognition describes complementary responsive and deliberative processes; general orchestration remains a planned direction. Embodied intelligence means behavior has observable device/environment effects; it does not establish autonomous robot safety.

[Architecture](Architecture.md) describes current collaboration. The [technical design](../MobileHarness/README.md#part-iii--key-techniques) defines cross-module flows and module READMEs define the algorithms.
