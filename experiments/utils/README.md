# Research utilities

Shared mechanisms used only by Python experiments:

- `runtime.py`: model transports, bounded case execution, provenance and result writing. ROOT resolves to the repository root; failures remain explicit and outputs are not overwritten.
- `coreai_decoder.py`: sequential Core AI token decoding with per-request state and explicitly configured static inputs. Native dependencies load only when the backend is selected.

Task-specific prompts, scoring, workspace tools and model adapters stay with their owning task. Tests and scripts must not import this package as an engineering helper library.
