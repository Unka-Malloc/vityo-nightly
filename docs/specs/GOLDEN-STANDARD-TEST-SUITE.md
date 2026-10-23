# Golden Standard Test Suite

**Purpose:** Define the Vityo client test level that makes a desktop client version submittable.

**Last updated:** 2026-06-29

`test / smoke` runs the fast Flutter application and language-service smoke tests.

`test / golden-standard` runs `python3 scripts/vityo.py deliver` after all declared platform-adaptation gates pass. The shared pipeline restores and exercises the declared test roots, evaluates coverage, builds and packages the host candidate, installs it in the configured lane, and stops after startup evidence.

## Local Gate Profile

`vityo-checkpoint-desktop-profile` is the repository-owned adaptation for the Vityo desktop client. It is maintained through the canonical Python delivery pipeline, Flutter test coverage, the permanent Prototype dependencies, and desktop package/startup evidence. The organization-level audit only verifies that this local profile is present and covered by `test / golden-standard`.

Required local markers: repo-owned adaptation, `python3 scripts/vityo.py deliver`, Flutter, Prototype dependencies, desktop client.

## Industry Gate Group

`client / desktop-quality` is the role-specific gate group for the Vityo desktop client. It keeps Flutter tests, desktop platform behavior, dependency restoration, the delivery pipeline, and docs checks grouped under `test / golden-standard`.

Required evidence markers: Flutter test, desktop platform, dependency restore, delivery pipeline, docs gate.

## Submit Readiness

A Vityo client version is submittable only when every declared `platform-adaptation / ...-ci-gate`, `test / smoke`, and `test / golden-standard` all pass.
