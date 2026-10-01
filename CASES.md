# CASES — incident catalog

Every deploy-breaking failure mode observed on z.ai fullstack hosting (2026-09/10),
with symptom, root cause, fix and how the kit verifies it. Numbering matches the table
in the README. New cases: append at the bottom, keep the same structure.

---

## Case 01 — Missing build.sh: pipeline produces no artifact

- **Symptom:** deploy fails immediately with no app logs; pipeline reports the build
  artifact path missing (`构建产物不存在: /tmp/build_fullstack_<id>.tar.gz`).
- **Root cause:** the platform's build stage executes `<project>/.zscripts/build.sh`
  with `BUILD_ID=<id>` in the environment. If the file doesn't exist, no artifact is
  produced and the deploy aborts before upload.
- **Contract measured:** on exit (or kill, ~14s), the pipeline requires
  `/tmp/build_fullstack_${BUILD_ID}.tar.gz`; the artifact is extracted to `/app/`.
- **Fix:** `templates/build.sh` implements the contract: fast synchronous pack of the
  warm standalone build, detached rebuilds for freshness.
- **Verify:** `doctor.sh` checks build.sh exists and parses; `fc-sim.sh` exercises the
  pack path end-to-end.

## Case 03 — Missing /app/start.sh: FC CAExited

- **Symptom:** deploy dies with `CAExited: sh: 0: cannot open /app/start.sh` (or the
  boot never turns healthy).
- **Root cause:** the FC runtime extracts the artifact into `/app/` and boots it with
  **dash**: `sh /app/start.sh`. Two hard requirements: (a) a POSIX-sh boot entry at the
  **tar root** of the artifact; (b) it must serve HTTP 200 on `FC_CUSTOM_LISTEN_PORT`
  (81) within **120s**, or the deploy is killed.
- **Fix:** `templates/start.sh` — dash-compatible, never exits (`exec node server.js`,
  bun fallback), exports `PORT=${FC_CUSTOM_LISTEN_PORT:-81}`, `HOSTNAME=0.0.0.0`,
  `NODE_ENV=production`, writes the `.z-ai-config` stub if absent, makes the shipped DB
  writable when running as root.
- **Verify:** `dash -n start.sh` in `doctor.sh`; full boot rehearsal via `fc-sim.sh`.
- **Sandbox gotcha:** when rehearsing locally, bind an unprivileged port
  (`FC_SIM_PORT=3101`) — the dev sandbox's caddy owns 81 and non-root binds get EACCES.
  Production is unaffected.

## Case 04 — Pack/rebuild race: deploy fails after a code change

- **Symptom:** deploy fails (no artifact) right after a code change, even though the
  code compiles and the app runs fine in dev.
- **Root cause:** `next build` **wipes** `.next/` (including `standalone/`) when it
  starts. If the build script triggered its freshness rebuild *before* packing the
  artifact, tar races the wipe and produces nothing.
- **Fix:** order is load-bearing: **pack FIRST, kick the detached rebuild AFTER.**
  Packing first guarantees every call that finds a complete standalone ships it; the
  rebuild only affects the *next* call. Freshness = any watched path newer than
  `standalone/server.js` (`ZHP_WATCH_PATHS`).
- **Verify:** `fc-sim.sh` after touching a source file — the pack must still succeed
  and the log must show the rebuild kicked after `artifact ready`.

## Case 05 — Restart wipe: "Sorry, there was a problem deploying the code", forever

- **Symptom:** the platform UI shows "Sorry, there was a problem deploying the code.
  You can return to the generation page to try again." — and **every** retry fails.
  (Real timeline: sandbox bootstrap restarted ~07:06; three deploy clicks at 07:14,
  07:15, 07:17 all failed.)
- **Root cause:** sandbox restarts/bootstrap wipe untracked build state (`.next/`,
  logs; `node_modules` and `db/` survive). The warm standalone build disappears, and a
  naive build.sh failure path just exits 1 — with nothing rebuilding the standalone,
  the failure repeats forever. A doom loop.
- **Fix (three layers):**
  1. **Persistent fallback artifact** — every successful pack also stores the tarball
     at `.zscripts/cache/last-good.tar.gz`. A standalone-less call ships it (possibly
     slightly stale code — a stale site beats an error) and kicks a detached rebuild.
  2. **Self-heal wait** — with no standalone AND no fallback, the script kicks the
     rebuild and waits; the pipeline may kill that attempt, but the detached rebuild
     survives and the next click succeeds.
  3. **Fallback refresh** — after every background `BUILD OK`, the worker re-packs the
     fallback so it tracks the latest good build.
- **Verify:** hide `.next/standalone`, run `bash .zscripts/build.sh` with a manual
  `BUILD_ID`: it must exit 0, produce the artifact from the fallback, and start a
  rebuild. Restore/remove the hide, wait for `BUILD OK` in `.zscripts/build.log`, and
  confirm the `fallback artifact refreshed` line.

## Case 06 — DB missing at boot / sandbox paths baked into the artifact

- **Symptom:** app boots but DB reads fail; or SQLite writes go nowhere.
- **Root cause:** the prisma CLI is not part of the Next standalone bundle, so the
  schema cannot be pushed at boot — the DB file must arrive ready in the artifact.
  Additionally, the dev `.env` copied into the standalone carries the *sandbox* path
  (`/home/z/my-project/...`), which doesn't exist in `/app/`.
- **Fix:** build.sh copies the DB into the artifact (detected via `db/custom.db`, or
  `DATABASE_URL` from `.env` resolved the way prisma does — `file:./x` is relative to
  `prisma/`) and writes a normalized `.env` (`DATABASE_URL=file:/app/<rel>`).
  start.sh re-exports `DATABASE_URL` from `.env` and chmods the DB dir when running
  as root.
- **Verify:** `fc-sim.sh` boots the extracted artifact; hit an endpoint that reads
  the DB.

---

## Operational notes

- **Deploys need a real user click.** Triggering the platform's deploy endpoint from
  inside the sandbox does not produce a real deployment (constant 500s were observed).
  Agents should: verify with `doctor.sh` + `fc-sim.sh`, commit, push, then ask the
  user to click Deploy.
- **The build journal is the truth.** `.zscripts/build.log` is append-only and records
  every build request, artifact, rebuild and fallback decision. `doctor.sh` only fails
  on FATAL entries in the *most recent* build request — historical FATALs are normal
  after a fixed incident.
- **In-sandbox deploys vs production port.** caddy binds 81 in the sandbox; FC binds
  81 in production. Never change `FC_CUSTOM_LISTEN_PORT` default; only override it for
  local sims (`FC_SIM_PORT` / passing `FC_CUSTOM_LISTEN_PORT` directly).
