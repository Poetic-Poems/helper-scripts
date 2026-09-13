# helper-scripts

Warwick's holding pen for the scripts he finds useful on his workstation and
across the Poetic fleet: each is self-contained, documents itself in its own
header, and lives here rather than in a product repository so that it can be
changed without ceremony. A script that proves generically useful is promoted
to the repository it serves (for example `Pullwright/agent-ops/scripts`) and
takes on that repository's controls. Read a script's header before running
it; the one-line summaries below only say what each is for.

The fleet these scripts operate is described in `Poetic-Poems/.agent`'s
runbook (private): the four nodes, their hosts and the diagnosis recipes that
name these scripts.

## The fleet

| Script | What it does |
|--------|--------------|
| `check-nodes.sh` | Prints one status block per node — the two local stacks under `~/poetic-node-{1,2}` and the two on the tailnet host — from each scheduler's own view. |
| `monitor-nodes.sh` | Runs `check-nodes.sh` continuously in a split tmux window; needs a shell already inside tmux. |
| `list-escalations.sh [FILTER]` | Lists the pipeline's open escalation issues across the fleet's repositories, optionally filtered by a `jq` expression such as `'.repo|match("^Pullwright")'`. |
| `count-autonomous-agent-prs.sh` | Counts open pull requests carrying the pipeline's label in every repository `agent-ops`'s `config.json` lists. |
| `count-autonomous-agent-prs-merged-in-last-N-hours.sh [HOURS]` | The same count for pull requests merged in the last N hours. |
| `env-key-hash.sh [options] KEY-PATTERN…` | For each matching `.env` key, shows what is staged in each node's `.env` and what each of its containers is actually using — as a length and either the value or, for a sensitive key, its md5 — and marks a container whose value differs from the file `STALE` (older than the file) or `ENV OVERRIDE` (newer: an exported shell variable won when `docker compose up -d` ran). Use it instead of reading a `.env` or `docker inspect`ing an environment, both of which expose secret values. `show-envs-specific.sh` is a symlink to it. |
| `show-envs.sh` | Lists every `.env` key on every node with the values of keys named `*KEY`, `*TOKEN` or `*SECRET` masked. `show-envs-all.sh` is a symlink to it. |
| `deploy-latest-compose.yaml.sh [--dry-run] [--repo ORG/REPO]` | Delivers `origin/main`'s `deploy/docker/compose.yaml` to all four nodes and says per node whether anything changed; an image roll never carries compose-level configuration, and nothing restarts until `docker compose up -d` runs in the node's directory. |
| `gh-get.sh ORG/REPO PATH` | Prints a file from a repository's `origin/main`. |

## The workstation

| Script | What it does |
|--------|--------------|
| `clean-machine.sh [-n]` | The deep manual disk sweep: prunes Docker, sweeps stale scratch, and switches branches, pulls, gcs and deletes branches in the working clones — right when you are watching it, wrong on a timer. |
| `wsl-disk-janitor.sh [-n] [--tier …] [--status]` | The hourly, non-disruptive subset: orphaned swap files, `docker system prune` (never volumes, never compose containers), tiered cache shedding on a free-space floor, `fstrim`. `--status` prints C: free, used inside, allocated and dead space. |
| `compact-wsl-vhdx.ps1` | Hourly Windows scheduled task ("WSL VHDX maintenance") that compacts the WSL virtual disk only when it is worth it, the hour is quiet, no editor is attached to WSL and every scheduler says no cycle is running. Runs from its deployed copy under `%LOCALAPPDATA%\wsl-maintenance\`, never from this clone; re-copy it after every edit. |
| `rebuild-wsl-vhdx.ps1` | Exports, unregisters and re-imports the distro, which is the only thing that reclaims dead space from a sparse or compressed VHDX; verifies the archive before anything irreversible. |
| `install-wsl-maintenance.sh [--uninstall] [--dry-run]` | Installs the janitor's cron entry, the compactor's scheduled task and the `.wslconfig` change that pins the swap file; idempotent. |

## Working here

`main` has no ruleset and takes direct pushes; a pull request is welcome for
anything a reviewer should see first. Commit messages follow Conventional
Commits. A script must never print a secret's value — hash it, mask it, or
show its length, as `env-key-hash.sh` and `show-envs.sh` do — and must not be
run from a copy that could be reading itself over `\\wsl.localhost` while it
shuts WSL down. `AGENTS.md` states the same for AI agents.
