# ModelKitHub tests

Purpose: verify the concrete Hub download integration. Design goals: reject unsafe paths, select regular files only, and distinguish network acceptance from offline regression checks.

✅ Offline tests cover directory exclusion, glob selection and unsafe/oversized remote metadata rejection.
✅ HARNESS_TEST_HUB_ENDPOINT enables an actual Silero download through the production adapter, asserts intermediate progress and required files, and cleans its temporary staging.
❌ Opt-in macOS downloads do not establish real iPhone progress rendering or lifecycle acceptance.


✅ Persisted complete-file plans resume without network access; unsafe/reserved/oversized plans fail. Production native transfer Silero downloads passed against official HF and HF-Mirror with intermediate progress. ❌ These Mac checks do not establish iPhone background/large-file resume acceptance.
