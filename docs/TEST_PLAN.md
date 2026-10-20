# TEST_PLAN.md — owned by QA Agent

## How to run
```
powershell -File tools/run_tests.ps1
```
Runs `godot --headless --import`, then GUT over `tests/unit` and `tests/integration`.
Exit code 0 = all passed; non-zero = failure (verified with a deliberate failing canary test in M0).
JUnit report: `build/test_results.xml`.

Benchmark: `godot --headless --path . -s res://tools/bench_world.gd`
Web end-to-end: `node tools/serve_web.js` then `node tools/web_smoke.mjs <steps.json> <out_dir> [profile_dir]`
(headless Edge via DevTools Protocol; reusing `profile_dir` tests that saves survive a browser restart).

## Test layers
| Layer | Location | Purpose | From |
|---|---|---|---|
| Unit | `tests/unit/` | Pure logic: contracts, clock, IDs, later world gen, reservations | M0 |
| Integration | `tests/integration/` | Scenes instantiate, UI → command → state | M0 |
| Save round-trip | `tests/integration/` | snapshot → JSON → load → identical state, no duplicated items/jobs | M1 |
| Determinism | `tests/unit/` | same seed ⇒ same world hash; golden hash also checked on Web build | M1 |
| Stress | `tests/stress/` (excluded from default run) | 100 NPC, horde sizes; record tick ms, FPS, memory | M2+ |
| Build smoke | `tools/export.ps1` | Web + Windows export succeed; Windows build runs headless 300 frames; Web boots in browser | M0 |

## Rules
- Tests are written from acceptance criteria, not from the implementation.
- A failing test blocks milestone closure. Flaky tests are bugs.
- Anything not executed is reported as **NOT RUN** with the reason.
- Each milestone adds regression tests for every bug fixed.

## M1 regression checklist
- [x] 76 GUT tests (incl. golden world hash, save corruption/fallback, 3-world limit, D-015 orders-don't-edit-terrain)
- [x] Benchmark recorded (handoff §4)
- [x] Web: create → orders → F9 dig → save → browser restart → load; Web hash = PC hash
- [ ] Touch/pinch on real device — NOT RUN (OQ-19)

## M0 regression checklist
- [x] 25 GUT tests (unit 20, integration 5)
- [x] Harness returns non-zero on failure (canary)
- [x] Web export builds; boots in browser; Pause/3x buttons respond
- [x] Windows export builds and runs headless 300 frames, exit 0
- [ ] Web tick-rate timing — NOT RUN (hidden browser pane, see OQ-11)
- [ ] Mobile export — NOT RUN (no Android SDK/iOS toolchain; out of M0 scope)
