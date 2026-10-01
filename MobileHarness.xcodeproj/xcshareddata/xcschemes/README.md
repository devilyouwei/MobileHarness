# Shared schemes

Purpose: reproducible App and simulator launch settings. Design goals: explicit diagnostic selection without changing production bindings.

✅ MobileHarness and MobileHarnessSimulator retain their normal launch modes. MossValidation starts the physical App in MOSS synthesis diagnostics using -moss-benchmark; it replaces KokoroValidation.
❌ A successful build does not establish device speech quality or stability.
