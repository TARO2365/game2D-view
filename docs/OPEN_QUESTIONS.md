# OPEN_QUESTIONS.md — ข้อมูลที่น่าสงสัย / ยังไม่ชัด (flagged items)

> OWNER NOTE (TH): รายการนี้เก็บทุกจุดที่สเปกขัดกัน กำกวม หรือยังไม่ได้ตรวจยืนยัน
> ห้าม agent ตัดสินเองเงียบๆ — ถ้าต้องตัดสินเพื่อทำงานต่อ ให้บันทึกใน DECISIONS.md แล้วอ้างอิงกลับมาที่นี่

| ID | Area | Issue | Needed by | Status |
|---|---|---|---|---|
| OQ-01 | Art | Spec §1 says "*not* the earlier bright/cutesy-only art direction", but approved concept (D-002) is labelled "Cute & Colorful" chibi. Spec text should be updated in spec v0.2 to match D-002 (owner edit). | Before Visual Design sign-off | OPEN |
| OQ-02 | Roadmap | Spec §13 requires early save/load but the table puts persistence in M12. D-007 moves basic save/load to M1; spec table still unedited. | Before M1 | OPEN (needs owner spec edit) |
| OQ-03 | Infra | Oxygen is per room (§2/§4). Undefined: oxygen in open caves, corridors, unenclosed space, and partially breached rooms. | Before M4 | OPEN |
| OQ-04 | Combat | Horde every 5 days + boss every 10–15 days can coincide (e.g. day 10, 15). Stack, offset, or merge? | Before M5 | OPEN |
| OQ-05 | Inventory | Ownership of items while carried by an NPC or inside a vehicle cargo hold. Proposal: Inventory owns all quantities in "containers" (stockpile, NPC hands, vehicle hold); others request transfers. | Before M2 | PROPOSAL |
| OQ-06 | World | Cross-platform determinism of seeded generation (float noise on PC vs Web WASM). Plan: golden-hash test run on both. | M1 | OPEN — validate |
| OQ-07 | Save | Web persistence (`user://` → IndexedDB) size quota and browser eviction; export/import not approved. | M1 feasibility | OPEN |
| OQ-08 | Art | Texture filter nearest vs linear, zoom range, mipmaps — concept art is high-detail painterly/pixel hybrid. | Before M1 art import | OPEN |
| OQ-09 | Combat | Exact sizes of boss/large creatures vs clearance class "large = 4+". | M5/M7 | OPEN |
| OQ-10 | Difficulty | Relaxed/Standard/Hardcore presets and Colony Prestige are proposals only, not locked. | Later | NOT LOCKED |
| OQ-11 | QA | Web build timing (ticks/sec at 1x/2x/3x) not measured: test browser pane was hidden so `requestAnimationFrame` did not run. | M1 | NOT RUN |
| OQ-12 | Legal | Originality review vs Oxygen Not Included UI/mechanics. | Before M11 | OPEN |
| OQ-13 | UX | Touch target sizes (SpeedBar uses 56×44 px placeholder). | UX prototype | OPEN |
| OQ-14 | Save | "One world": does creating a new world overwrite the old one, or is New World disabled while a save exists? | M1 | OPEN |
| OQ-15 | Sim | Tick rate 10 Hz and cadence 1/5/20 ticks are placeholders; real values need profiling (spec §17). | M2 profiling | PLACEHOLDER |
