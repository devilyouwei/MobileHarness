# App responsibility cleanup validation

2026-10-31: `./scripts/check.sh` passed with exit 0, including architecture checks, format lint, Python tests, Swift package suites, the final 225-test runtime phase and plist checks. Log: `/tmp/app-cleanup-check.log`.

The final source passed `./scripts/build-ios.sh` (all simulator schemes and bundle-resource validation), log `/tmp/app-cleanup-verified-build.log`. After final failure-classification and test edits, targeted Swift tests passed for model cleanup publication, lifecycle admission suppression, inherited resource leases, transient settlement and model preparation. Log: `/tmp/app-cleanup-focused.log`. Final edited-file strict format lint and `git diff --check` passed.

Resource tests verify missing-owner rejection and inherited lease authorization, plus active transient holdings versus settled holdings. Model preparation tests verify deduplication, registered readiness and rejection after shutdown. Failure tests preserve original cleanup errors rather than suppressing them as lifecycle admission errors. iOS compilation covers complete speech-session presentation and mandatory application bootstrap; their native UI/device interaction was not exercised here.

Unused App health-summary/diagnostic-projection tests were removed with APIs having no production consumers; exact-path, bounded-tree, cancellation, disclosure and failure-journal coverage remains. No model inference, physical-device actions or new phone installation was performed. Existing prior installation records do not cover this revision.

## Physical-device installation — 2026-10-31

At the user's subsequent request, the current workspace passed a signed MobileHarness Debug iPhoneOS build and final 25-asset Agent/Skill resource verification. Installed in place on the paired iPhone 17 Pro as `dev.mobileharness.app`; devicectl returned exit 0, installation database sequence 5156. No uninstall or explicit data deletion was performed. Build log: `/tmp/app-cleanup-device-build.log`. This installation supersedes the earlier not-installed statement for this revision; app launch and physical-device feature acceptance were not performed.
