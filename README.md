# Z.ai Hosting Patcher

<div align="center">

## 🚀 Z.AI GLM Coding Plan — 10% OFF your first subscription

Claim with invite code **`R0K78RJKNW`** → **[z.ai/subscribe?ic=R0K78RJKNW](https://z.ai/subscribe?ic=R0K78RJKNW)**

[![GLM Coding Plan: 10% OFF with invite code R0K78RJKNW](https://img.shields.io/badge/Z.AI_GLM_Coding_Plan-10%25_OFF_%C2%B7_code_R0K78RJKNW-EA2865?style=for-the-badge)](https://z.ai/subscribe?ic=R0K78RJKNW)

<sub>Same plan, 10% cheaper — and it supports this kit's development at no extra cost to you.</sub>

</div>

---

**A self-healing deploy kit for [z.ai fullstack hosting](https://z.ai).** Drop it into any
Next.js project and it installs the two scripts the platform's deploy pipeline expects —
plus the recovery logic for every hosting failure mode we have hit so far.

Born from a real portal ([GLM Bonus Radar](https://github.com/romangalaxys10-spec/glm-bonus-radar),
live at https://zhelp.space-z.ai) that went through **five distinct deploy-breaking incidents**
in two days. Each one was debugged from platform error strings, reverse-engineered contracts
and reproduced locally. This repo packages all of it so any session — human or AI agent —
can patch a project in one command instead of re-debugging for hours.

> Unofficial community tool. Not affiliated with z.ai. The pipeline/FC contracts below were
> reverse-engineered from observed behavior; if the platform changes, re-run `doctor.sh`
> and check `CASES.md` for how to extend the kit.

## The failure modes it fixes

| # | Symptom you see | Root cause | Patcher's fix |
|---|-----------------|-----------|---------------|
| 01 | Deploy fails instantly, no build logs | Project has no `.zscripts/build.sh` — the pipeline's build stage produces no artifact | Installs a build.sh implementing the measured pipeline contract |
| 03 | `CAExited: sh: 0: cannot open /app/start.sh` | The artifact must carry a **POSIX-sh boot entry at the tar root**; the FC runtime extracts to `/app/` and runs `sh /app/start.sh`, health-checking `FC_CUSTOM_LISTEN_PORT` (81) within **120s** | Installs a dash-compatible start.sh; `fc-sim.sh` reproduces the boot locally |
| 04 | Deploy fails after a code change, code was fine | **Pack/rebuild race** — the detached `next build` wiped `.next/standalone` while the artifact was being packed | Build script packs **first**, kicks the rebuild **after** (order is load-bearing) |
| 05 | `Sorry, there was a problem deploying the code` — **every** retry, forever | Sandbox restart wipes untracked build state (`.next/standalone`, logs); the old failure path just exited 1 with no recovery — a doom loop | **Persistent fallback artifact** ships instantly; detached rebuild self-heals; the next click always works |
| — | App boots but DB is empty / errors | `prisma` CLI is not in the standalone bundle — the schema can't be pushed at boot | Build script ships a ready-to-run DB file + `/app`-normalized `.env` |

## Quick start

```bash
git clone https://github.com/romangalaxys10-spec/zai-hosting-patcher.git
cd zai-hosting-patcher

# 1. install the kit into your project (any Next.js app on z.ai fullstack hosting)
bash patch.sh /path/to/your-project

# 2. verify the deploy-critical pieces
bash doctor.sh /path/to/your-project

# 3. before clicking Deploy, rehearse the platform's boot locally
bash fc-sim.sh /path/to/your-project
```

Then click **Deploy** in the platform UI. (Deploys must be triggered by a real user click;
calling the internal deploy endpoint from inside the sandbox does not work.)

> Sandbox note: the sim runs on port 3101 by default (`FC_SIM_PORT` to override) because
> the dev sandbox's caddy owns port 81 and non-root binds get `EACCES`. Production still
> uses 81.

## What gets installed

```
your-project/
└── .zscripts/
    ├── build.sh        # self-healing pipeline build (see "How it works")
    ├── start.sh        # POSIX-sh boot entry, packed at the artifact tar root
    ├── cache/          # persistent last-good artifact (survives restart wipes)
    │   └── last-good.tar.gz
    └── build.log       # append-only build journal
```

All scripts are dependency-free (bash/sh + curl for the sim) and idempotent — re-running
`patch.sh` backs up your existing scripts as `.bak.<timestamp>` first.

## How the build script works

The platform's build stage is brutally short (~14s before the script is killed), while a
cold `next build` takes 40s+. The contract on exit is: **an artifact must exist at
`/tmp/build_fullstack_${BUILD_ID}.tar.gz`.** So the script keeps builds warm and detaches them:

1. **Pipeline mode** (normal deploy click): if a finished standalone build exists → pack it
   synchronously (fast), write the persistent fallback, **then** kick a detached rebuild if
   source is newer. Always exits 0 with an artifact.
2. **Standalone missing** (restart wiped it): ship the persistent fallback artifact
   (code as of its pack time) and kick a detached rebuild so the next click is fresh.
   A slightly stale site beats a deploy error.
3. **No standalone, no fallback** (first ever deploy after a wipe): kick the rebuild and
   wait. The platform may kill this attempt — but the detached rebuild survives and the
   next click succeeds. Self-heal, no manual intervention.
4. **Worker mode** (detached rebuild, `ZBUILD_BG=1`): install → db push → build → refresh
   the fallback artifact so future wipes ship instantly.

Package-manager agnostic: uses bun when `bun.lock`/`bun.lockb` exists, npm otherwise.
Tunable via `ZHP_DB_FILE` and `ZHP_WATCH_PATHS` (see the script header).

## Script reference

| Script | Purpose |
|--------|---------|
| `patch.sh [dir]` | Install build.sh + start.sh + cache dir into a project, then run doctor |
| `doctor.sh [dir]` | Check every known failure mode; exit 1 if deploy-critical pieces are broken |
| `fc-sim.sh [dir\|artifact.tar.gz]` | Pack (or take an artifact), extract, boot with `sh start.sh`, health-check like FC — catches Case 03/DB/.env issues **before** you click Deploy |
| `templates/build.sh` | The self-healing pipeline build (installed as `.zscripts/build.sh`) |
| `templates/start.sh` | The POSIX boot entry (installed as `.zscripts/start.sh`) |

## Recommended session workflow

```bash
bash doctor.sh .        # before every deploy
bash fc-sim.sh .        # after any change to start.sh / build.sh / DB handling
git commit + push       # then click Deploy in the platform UI
tail -f .zscripts/build.log   # if anything fails, this journal is the truth
```

## Incidents

Full post-mortems with timelines, root causes and verification steps: [CASES.md](CASES.md).

## License

MIT — see [LICENSE](LICENSE).
