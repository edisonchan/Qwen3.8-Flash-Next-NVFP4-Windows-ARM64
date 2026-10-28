# The engine knobs, frozen

`recipe/config.ps1` is a **verbatim mirror of `config.sh`**: same exports, same order, same
values, unset means unset. The measured-best set for this box is not baked into it — paste the
block at the bottom of this file into the recipe's `.env` to run on it (`.env` outranks the
mirror). Below: every knob, what it measured, and what to run.

Scored against the MiaAI-Lab page with the same instrument it uses — sparkDash:

| bench | page | this port, .env set | as shipped (config.sh's values) |
|---|---|---|---|
| decode, 1 stream (code, t=0, thinking off, 400 tok) | 110.5 tok/s | **91.8** | 77.7 |
| decode, 4 streams aggregate | — | **176.5** (47.6 a stream) | — |
| prefill, 32k (32,807 tok, cold, one request) | 2,735 tok/s | **2,291** | 731 |

Both gaps are the same ~16%, and both bottom out in the kernels rather than in front of them:
0.409 ms a prompt row against the page's ~0.34, ~10.9 ms a decoded token. No variable below moves
either number. That is the finding, not a failure to look hard enough — see §4.

## 1. The measured set (the .env block at the bottom)

The 21 `TF_FLASHNEXT_*` variables are one-for-one with `config.sh`'s exports (the diff of the two
export lists is empty — `docs/patching-and-port.md` §6.5 has the check). The table is what each
one measured; the **value** column is the fastest set this box has, which the .env block applies.
Verdict column: **won** = beat its group's baseline past the noise floor; **flat** =
measured, moved nothing, kept at engine/recipe value as documented; **source** = the engine code
makes any other value a no-op or a lie (file and rule named); **stock** = engine default, spelled
out only because `config.sh` does.

| variable | value | engine off/default | verdict | evidence |
|---|---|---|---|---|
| `YARN` | 0 (ctx 262144); 4 above | 0 | stock | only matters past 262144 |
| `DRAFTS` | 6 | 6 | stock | config.sh agrees |
| `PRODUCT_STREAMS` | 5 | 2 | flat | prefill 2→2,281 vs 5→2,283; at x4 all of 2/4/5 in one cluster |
| `SAMPLED_HEADS` | 0 | off | source | sampling path; bench is t=0, inert at any stream count |
| `SAMPLE_CAND` | 0 | off | source | same path |
| `GATHER_EARLY` | 0 | off | flat | x1 90.9 vs 90.3; at x4 +0.32% — noise both ways |
| `HOST_DRAW_THREADS` | 0 | auto | flat | 7 threads gave 91.0 vs 90.3, inside the 0.55% repeat floor |
| `KEEP_LATE` | **1** | off | won | 91.8 with `GDN_LANES` vs 90.3 without; beat the baseline twice |
| `GATHER_READ` | **'0'** | mapped pages | won (off) | `pread`: −10.5 tok/s decode, 663 tok/s prefill (2.6×). The one that must stay off |
| `DRAFT_AHEAD` | 0 | off | source | only means something with `GATHER_READ=pread` |
| `WARM_AHEAD` | 0 | off | flat | 1,702 vs 1,706 at 32k |
| `PREFILL_TAIL` | 0 | 0 | flat | 512 gave 1,705 vs 1,706 |
| `PROMPT_HC2` | **1** | off | won | group +168 tok/s (1,874 vs 1,706); stacks with the tile row |
| `PROMPT_SHARED_DIRECT` | **1** | off | won | same group |
| `HEAD_PIECE` | **1536** | 256 | won + source | same group; and `forwardHeadPieces` clamps it to `chunk/2` = 1536 at the stock CHUNK — the recipe's value is the ceiling |
| `PROMPT_GEMM2` | **1** | off | won | same group |
| `PROMPT_EXPERT_TILE` | **2** | off | won | +326 tok/s alone (2,032 vs 1,706) — biggest single win |
| `PROMPT_EXPERT_TILE_ROWS` | 256 | 1024 | won (group) | shipped with the tile; it is a threshold, see §3 |
| `SHARED_SIDE` | 0 | off | won (off) | 89.4 at x1 (−1.0%); at x4 every pass below every pass of the anchor (−6.4% drift-corrected) |
| `GDN_LANES` | **1** | off | won | needs `KEEP_LATE=1`; the pair measured 91.8 |
| `CONFIDENCE` | 0.6 | 0.6 | flat | recipe's −0.4 gave 90.6 at x1, `0.4` at x4 inconclusive — stock stands |

The `TENSORFOLD_*` exports carry no performance claim: `MAX_IMAGES`/`IMAGE_TOKENS`/`VIDEO_TOKENS`/
`VISION_WORKSPACE_MIB` match config.sh, `NO_UPDATE_CHECK=1` is a port courtesy.
`MEMORY_RESERVE_GIB` is an admission guardrail (budget = free pool − reserve, legal 2…mem), not a
tuning knob; this machine boots with `4` in `.env` because four streams need 19.53 GiB of KV and
the recipe's 10 leaves 18.27.

## 2. The must-not list

Three things are settled against the recipe and easy to re-break:

- **`GATHER_READ=pread`** — config.sh ships it. On WDDM it is a `ReadFile`+`OVERLAPPED` per row
  (`zig/src/platform/win_c.zig`), not a mapped page fault: it alone turns 90.3 into 80.8 on decode
  and 2,291 into 663 on prefill. The recipe's whole set scores 77.7 / 731 here because of it.
- **The sampling trio** (`SAMPLED_HEADS`, `SAMPLE_CAND`, `HOST_DRAW_THREADS`) — config.sh ships
  them on. They sit on the sampling path; a t=0 bench never walks it.
- **`SHARED_SIDE=1`, `BATCH_HEADS=0`** — both measured worse, at x1 and at x4.

## 3. Knobs that are not knobs

Three variables look tunable and are not; each cost a wasted round before the source was read:

| variable | looks like | actually is |
|---|---|---|
| `PROMPT_EXPERT_TILE_ROWS` | tile height | `nvfp4_tile.Config.min_rows` — chunks **below** it keep the decode kernel. Every 32k chunk is ≥2,079 rows, so 256 and 1024 behave identically at this size |
| `PROMPT_MX128` | tile size | `mx128MinN` — a column threshold (default 1024); projections over it take the 128×128 tile either way |
| `HEAD_PIECE` | free size | clamped by `min(piece_req, max(piece_rows, chunk/2))` — at CHUNK 3072 the ceiling is exactly 1536; it only becomes a lever if CHUNK rises (4096 at 8192) |

And one that does not exist: `TF_FLASHNEXT_DEPTH` (the engine has `DEPTH_LOG` only). Wrong names
fail silently; `TF_FLASHNEXT_DRAFTS` is the real draft-length knob.

## 4. Where the 16% went

Charged out against the page's 12.16 s first token at 32k, with the engine's own profiling
(`TF_FLASHNEXT_PROFILE=1`, `GATHER_LOG=1`):

| cost | measured | could a knob touch it? |
|---|---|---|
| fixed cost per chunk pass | 94 ms × 11 = 1.03 s | CHUNK=8192 recovers 0.67 s of it (+0.77%, ~1 MDD) but needs reserve 4→2 to load; not shipped |
| gather join wait | 22–28 ms a pass, 284–303 ms total | no |
| per-row prompt cost | 0.409 ms (32,807 rows) | the gap: page ≈ 0.34 ms. Inside the GEMM kernels; the tile variants (stage3) bracket the shipped 64,1,2 as a local optimum |

The honest boundary: 0.409 vs ~0.34 ms/row and 10.9 ms/token are WDDM-stack numbers, not env
numbers. If this ever gets chased further, the tool is `nsys --stats` on one request, not another
restart-sweep.

## 5. Measuring again, without fooling yourself

The harnesses (`sweep-decode.ps1`, `sweep-prefill.ps1`, `sweep-stage2/3.ps1`, `sweep-decode4.ps1`,
kept outside the repo under `D:\llm\latest\sweep\`) encode rules learned the hard way:

- Restart the engine per configuration; run three passes, score the fastest.
- One stream: passes of one configuration agree to **0.2%**, same-config repeats spread **0.55%** —
  the promotion gate is 0.6% (≈3σ). Below that you cannot see anything, twice, in a row.
- Four streams: one run's passes spread **2.4–8.1%**, and the box drifted **~9% during one session**
  (ps4: 177.7, then 161.2 for the same .env eight minutes later). Nothing under ~5% is resolvable;
  interleave an A-B-A anchor between candidates or you will promote the drift.
- A phase-replay must carry the previous phase's winner explicitly (`$script:cur` starts empty).
- WDDM hands memory back late: `stop`→`start` in 3 s inherits the dead engine's pool; wait for the
  process to leave, settle 4 s, cool 25 s, and walk reserve 4→2 on a refused start.
- Never run the sweep from an agent-driven shell — the harness's own host pollutes the bench. Run it
  from a console, and let the harness rewrite `.env` per candidate (it restores the shipped set at
  the end).

## 6. The measured set, as a .env block

`config.ps1` mirrors `config.sh`; performance lives in the recipe's `.env` (every key there
outranks the mirror). Paste this into `<recipe>\.env` for the fastest set this box has measured;
delete it to return to the recipe's own values (77.7 / 731 — keep it in).

```ini
# WDDM measured set (2026-10-28 sweeps) — evidence per line: docs/knobs.md §1
TF_FLASHNEXT_GATHER_READ=0          # vs pread: 2.6x on a 32k prompt
TF_FLASHNEXT_DRAFT_AHEAD=0          # meaningful only with pread
TF_FLASHNEXT_SAMPLED_HEADS=0        # sampling path: inert at t=0, cost on WDDM
TF_FLASHNEXT_SAMPLE_CAND=0
TF_FLASHNEXT_HOST_DRAW_THREADS=0
TF_FLASHNEXT_GATHER_EARLY=0
TF_FLASHNEXT_WARM_AHEAD=0           # nothing at 32k either way
TF_FLASHNEXT_PREFILL_TAIL=0
TF_FLASHNEXT_SHARED_SIDE=0          # -1.0% at x1, below anchor at x4
TF_FLASHNEXT_CONFIDENCE=0.6         # the stock rule; the recipe's -0.4 is noise here
# this box (30.5 GiB host): 5 streams fail admission, reserve is a budget not a knob
TENSORFOLD_MEMORY_RESERVE_GIB=4
PARALLEL=4
TENSORFOLD_LOAD_STATS=1
```

`PROMPT_EXPERT_TILE=2` is deliberately not in the block: `config.sh` does not export it, the
engine's unset default already selects `.both` at one rank, and this port always runs one rank.
