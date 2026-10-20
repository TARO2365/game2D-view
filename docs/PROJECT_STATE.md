# PROJECT_STATE.md

**Updated:** 2026-10-20 | **M0, M1:** Closed | **M2:** In progress (implementation merged, QA + handoff pending)

## M2 status
- Merged on `main` (231/231 tests): World (ladders), Systems (inventory, stockpiles, construction), Lead (contracts,
  priorities, ladder orders, random seed D-018, Thai font, save v2 + v1 migration, WorldSession wiring),
  Colony (NPCs, nav, jobs, hauling; bench 3.4 ms/tick @ 100 NPCs), UI (NPC/item views, tools, inspector).
- **QA Agent was stopped before reporting** (usage limit). Its partial work may be in
  `.claude/worktrees/agent-a09003e8b0a84accf` (branch `worktree-agent-a09003e8b0a84accf`, possibly uncommitted).
  Next session: inspect that worktree; re-run or finish QA per `docs/plans/M2_PLAN.md` §3.
- Known bug to fix: ground items do not fall when the tile below them is dug (no item gravity).
- Then write `docs/MILESTONE_HANDOFF.md` for M2 (archive M1 handoff to `docs/handoffs/`), update ROADMAP to In review.

## Repository
https://github.com/TARO2365/game2D-view (branch `main`). Git auth via Git Credential Manager; `gh` CLI not logged in.

## Environment (owner machine)
- Godot 4.7.2: `%LOCALAPPDATA%\Programs\Godot\` (+ export templates). GitHub CLI: `%LOCALAPPDATA%\Programs\gh\bin\`.
- Node.js 24 + Microsoft Edge for `tools/web_smoke.mjs`.
