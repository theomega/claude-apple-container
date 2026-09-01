# claude-container

Run Claude Code isolated inside [Apple Containers](https://github.com/apple/container).
Each session is a throwaway container that can only see the project it is
started in — nothing else on the host. Project-specific containers are built
from a `Dockerfile.dev` inside the project folder; if a project has none,
the default image definition from this repo is used. The project code is not
copied but mounted into the container, so edits land directly in your
working tree.

## Comparison to similar tools

- **[Dev Containers](https://containers.dev)**: same idea — a per-project
  Dockerfile, the source tree bind-mounted — but devcontainers are
  long-lived, editor-integrated, and Docker-based. claude-container
  sessions are throwaway, VM-isolated (via Apple's `container`), and need
  nothing but this script.
- **[Docker Sandboxes](https://docs.docker.com/ai/sandboxes/security/)**
  (`docker sandbox run claude`): closest in purpose — Claude Code in a
  microVM with the project mounted. It goes further on security: API
  credentials never enter the VM (a host-side proxy injects auth headers
  into outbound requests) and network egress is deny-by-default. The
  trade-off is Docker Desktop plus Docker's sandbox images, where here the
  project owns its environment via `Dockerfile.dev`.
- **[Lima](https://lima-vm.io/docs/examples/ai/)**: also VM-based, with
  documented agent setups and project-only mounts. Instances are long-lived
  and provisioned by template rather than per-project throwaway containers,
  but its `--sync` mode adds something this tool doesn't have: agent changes
  land in a copy and merge back only on your accept.
- **[Claude Code's built-in
  sandbox](https://code.claude.com/docs/en/sandbox-environments#sandbox-runtime)**:
  OS-level (Seatbelt) sandboxing with zero setup, but weaker isolation than
  a per-session VM and no custom toolchain image.

Compared to all of these, claude-container optimizes for being a single
bash script over Apple's stock tooling. It does not filter network egress,
and secrets reach the container as plain environment variables — if a
prompt-injected agent exfiltrating a key is in your threat model, Docker
Sandboxes has the stronger story today.

## Prerequisites

- An Apple silicon Mac running macOS 15 or newer (macOS 26 recommended by
  Apple for the container tool).
- Apple's [`container`](https://github.com/apple/container) CLI:
  `brew install container`, then `container system start` once (the script
  auto-starts it afterwards).
- Anthropic auth: an API key, or a claude.ai subscription — run `/login` in a
  project's first session (the login persists in the project's state dir, see
  below).
- `git` (used to forward your commit identity) — from the Xcode Command Line
  Tools, Homebrew, or anywhere else; everything else the script needs is
  stock macOS (`bash`, `shasum`, `awk`).
- Network access on first start of a project — the image build pulls base
  images and installs Claude Code.

## Setup

Clone this repository, then symlink the script into any directory on your
`PATH`. Use a symlink rather than a copy — the script looks for
`Dockerfile.default` next to its real (resolved) location:

```sh
ln -s "$PWD/claude-container" ~/.local/bin/claude-container   # from the checkout; any PATH dir works
export ANTHROPIC_API_KEY=sk-ant-...   # optional — or put it in ~/.config/claude-container/env
```

To use a claude.ai subscription instead of an API key, leave
`ANTHROPIC_API_KEY` unset and run `/login` in a project's first session:
claude prints a URL to open in your host browser and asks for the code back.
The login is stored in the project's persistent state dir, so it survives the
ephemeral containers. If the key is set, it takes precedence over a login.

## Usage

Run from anywhere inside a project (see project discovery below for what
claude gets access to):

```sh
claude-container                  # start claude (skip-permissions) in the container
claude-container --safe           # ...with normal permission prompts instead
claude-container -p "fix tests"   # any other args are passed to claude
claude-container shell            # bash in the same image/mount, no claude
claude-container stop             # stop this project's running sessions
claude-container stop --all       # stop sessions of every project
claude-container ls               # list running sessions
claude-container rebuild          # force image rebuild (--no-cache), then start
```

## How it works

- **Project discovery**: the *project root* is what gets mounted and what
  the image name, session names, `stop` scope, and claude state dir derive
  from. It is determined in this order:
  1. `Dockerfile.dev` in the current folder → the current folder is the
     project (use this in a subfolder to fence claude into just that part
     of a repo, with its own image).
  2. Otherwise, if the current folder is inside a git repo and there is a
     `Dockerfile.dev` at the repo root → the whole repo is the project
     (claude sees the full repo; your shell's cwd stays the working
     directory inside the container).
  3. Otherwise → the current folder is the project, built from
     `Dockerfile.default` next to the script.
  `CC_DOCKERFILE=<path>` overrides the Dockerfile choice (project = current
  folder). The image tag is the Dockerfile's content hash, so starting a
  session is a single image-inspect call and any edit to the Dockerfile
  triggers a rebuild on the next start (stale image versions are deleted
  automatically).
- **Session-scoped containers**: every invocation starts a fresh container,
  even for the same project — there is no attaching to or reuse of a running
  one. `claude` is the container's main process, run with `--rm`: when
  claude exits, the container stops and is removed — no idle VMs holding
  RAM. A minimal init (`--init`) sits above claude at PID 1, reaping
  orphaned processes (which would otherwise linger as zombies when claude
  launches background processes) and forwarding signals. Container names
  are `claude-<project>-<pathhash>-<pid>`, so concurrent sessions and
  same-named projects don't collide, and `stop`/`ls` are project-aware.
  Running `claude-container` twice in the same project therefore gives you
  two containers with one claude each. They are isolated
  from each other at the process level but share the image, the writable
  project mount, and the project's claude state dir — both claudes edit the
  same working tree, and one `claude-container stop` stops them all.
- **Isolation**: only the project root is mounted (writable, at its host
  absolute path). `--dangerously-skip-permissions` is the default because
  the container is the sandbox. Host git identity, `TERM`, and
  `ANTHROPIC_API_KEY` (if set) are forwarded as environment variables;
  nothing else from the host is visible. A `claude-container.args` file at
  the project root can add extra `container run` flags (see
  [Advanced usage](#advanced-usage)).
- **User customizations**: two optional paths under
  `~/.config/claude-container/` are mounted read-only into every container:
  `managed-settings.json` at `/etc/claude-code/managed-settings.json`
  (claude's managed-settings path, highest precedence — global defaults for
  every container session) and the entries of the `share/` directory under
  `/opt/claude-container`, for any files every container should see. Both
  are skipped silently if the paths don't exist. See
  [Customization](#customization).
- **Persistent claude state**: a per-project state dir on the host
  (`~/.cache/claude-container/<project>-<hash>/`) is mounted as claude's
  `CLAUDE_CONFIG_DIR`, so state survives the ephemeral containers. First-run
  prompts (theme, folder trust, API-key approval, bypass-permissions warning)
  only need to be answered once per project (folder trust: once per launch
  directory), OAuth credentials from `/login` are kept here too, and
  `claude --resume` sees the project's earlier sessions. The state dir is
  keyed on the project root's path only, so editing the Dockerfile rebuilds
  the image but keeps the claude state. Delete the dir to
  reset a project's claude state (including its login).

## Customization

Everything user-specific lives in `~/.config/claude-container/` — nothing in
the checkout needs editing. Every entry is optional:

| Path | Effect |
| --- | --- |
| `env` | env file (`KEY=value` lines) passed to every container via `--env-file` |
| `managed-settings.json` | mounted read-only at `/etc/claude-code/managed-settings.json`, claude's managed-settings path — settings here apply to every session with highest precedence |
| `share/` | its top-level entries are mounted read-only under `/opt/claude-container` — put any files here (scripts, dotfiles, extra config) that every container should see. Entries are resolved on the host first, so they may be symlinks into e.g. a dotfiles repo |

The repo ships examples: a statusline script and a managed-settings file
that wires it up (it references `/opt/claude-container/statusline.sh`, which
is `share/statusline.sh` on the host). To use them:

```sh
mkdir -p ~/.config/claude-container/share
cp examples/statusline.sh ~/.config/claude-container/share/
cp examples/managed-settings.json ~/.config/claude-container/
```

The example statusline needs `jq` in the image; the default and example
Dockerfiles install it.

## The Dockerfile.dev contract

The Dockerfile owns the container environment. It must:

1. Install Claude Code and put it on `PATH` — the native installer drops it in
   `~/.local/bin`, which is *not* on `PATH` by default:

   ```dockerfile
   RUN curl -fsSL https://claude.ai/install.sh | bash
   ENV PATH="/root/.local/bin:${PATH}"
   ```

2. Install whatever project toolchain claude should use (compilers, linters,
   language runtimes). No `COPY` of sources needed — the project root is
   bind-mounted at runtime.

3. Install `jq` if you use the example statusline — the script needs it
   (plus `bash`, `git`, and `awk`, which most base images already have).

Since the build context is the project directory, add a `.dockerignore` (e.g.
`.git`, build output) if the project is large — it keeps rebuilds fast.

## Advanced usage

Recipes for needs beyond the plain start-a-session flow. Most of them build
on the `claude-container.args` file described first.

### Per-project `container run` arguments

Some projects need `container run` flags the script doesn't set itself —
e.g. a bigger `/dev/shm` for Chrome. Put them in a `claude-container.args`
file at the project root (next to `Dockerfile.dev`): one argument per line,
so no shell quoting is involved; blank lines and `#` comments are ignored.

```
# Chrome wants more shared memory
--shm-size=2g
```

A flag with a separate value goes on two lines (`--shm-size` / `2g`), or use
the `=` form on one. The arguments are appended after the script's own, so
they can also override defaults like `--memory`. Like `Dockerfile.dev`, the
file is part of the project and can widen the sandbox (e.g. mount extra host
paths), so review it in repositories you don't trust.

Two placeholders are expanded in each line, so the file stays portable
across users and machines (the file has no other shell processing — `~` and
`$VARS` are not expanded):

- `{{root}}` — the project root's absolute host path.
- `{{cache}}` — a per-project scratch dir on the host
  (`~/.cache/claude-container/<project>-<hash>-cache/`). Mount sources under
  it are created automatically, and it survives sessions — use it for
  container-side state that should not live in the project tree (see the
  `node_modules` recipe below). Delete the dir to reset that state.

### Mounting a second host directory

By default only the project root is visible inside the container. If claude
needs another host directory too — reference docs, a sibling library, a
dataset — add a `--volume` flag to `claude-container.args`:

```
# API docs claude may read, but not modify
--volume
/Users/me/reference-docs:/mnt/docs:ro
```

The format is `host-path:container-path[:ro]`; append `:ro` to make the
mount read-only (recommended for anything claude only needs to consult),
omit it for a writable mount. The lines are passed to `container run`
verbatim — no shell involved — so use absolute paths (`~` is not expanded)
and note that host paths in the file apply to everyone who runs a session
in the project. Tell claude the mount exists (e.g. mention `/mnt/docs` in
the project's `CLAUDE.md`), since it only sees the container path.

Every extra mount widens the sandbox, deliberately: prefer `:ro`, and mount
the most specific directory that suffices rather than e.g. your home folder.

### Platform-specific dependency dirs (`node_modules`)

Since the containers are Linux VMs and the project tree is shared with the
host, an `npm install` run by claude fills `node_modules` with Linux
binaries — and nothing runs on the macOS side afterwards (or vice versa),
until the directory is deleted. The same applies to any dependency dir with
native artifacts, e.g. a Python `.venv`.

The fix is to shadow the directory inside the container: mount a dir from
the project's `{{cache}}` scratch area over it, so the container gets its
own Linux `node_modules` and the host's macOS one stays untouched
underneath. In `claude-container.args`:

```
# keep Linux node_modules out of the host working tree
--volume
{{cache}}/node_modules:{{root}}/node_modules
```

How it behaves:

- The host's `node_modules` is hidden (not modified) while a session runs;
  from the host it stays intact the whole time. If the project has none,
  an empty `node_modules` dir appears in the host tree as the mount point —
  harmless.
- The container starts with the cache dir's contents, so claude runs
  `npm install` once and the Linux install persists across sessions in
  `~/.cache/claude-container/<project>-<hash>-cache/node_modules`. Delete
  that dir to reset it.
- `package.json` and the lockfile live in the shared project tree, so host
  and container installs stay in sync from the same lockfile.
- Monorepos: every nested `node_modules` (e.g. `packages/*/node_modules`)
  needs its own line pair.
- Ephemeral alternative: `--tmpfs` / `{{root}}/node_modules` gives a fresh,
  RAM-backed (counts against `CC_MEMORY`) dir each session with zero host
  residue — at the cost of an `npm install` per session.

### Chrome and the chrome-devtools MCP server

Claude can drive a real browser inside the sandbox. `Dockerfile.example.chrome`
shows the recipe: on top of the usual Claude Code install it adds Google's apt
repo and installs `google-chrome-stable` plus `nodejs`/`npm` (needed so claude
can launch `npx`-based MCP servers). Copy it into a project as
`Dockerfile.dev`, then register the MCP server (any arguments after `--` are
passed to claude verbatim, so this runs `claude mcp add ...` inside the
container):

```sh
claude-container -- mcp add chrome-devtools -- npx chrome-devtools-mcp@latest \
  --headless=true --isolated=true --logFile=/tmp/log.txt \
  "--chrome-arg='--no-sandbox'"
```

This only needs to be run once per project — the persistent claude state keeps
the server across sessions. It is equivalent to this MCP config:

```json
"chrome-devtools": {
  "type": "stdio",
  "command": "npx",
  "args": [
    "chrome-devtools-mcp@latest",
    "--headless=true",
    "--isolated=true",
    "--logFile=/tmp/log.txt",
    "--chrome-arg='--no-sandbox'"
  ],
  "env": {}
}
```

Flag notes: `--headless` because there is no display in the container,
`--isolated` gives each session a throwaway Chrome profile, and
`--chrome-arg='--no-sandbox'` is required because claude (and therefore
Chrome) runs as root in the container — Chrome refuses to start its own
sandbox as root, and the container is already the sandbox.
`claude-container -- mcp list` verifies the server connects.

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `ANTHROPIC_API_KEY` | — | forwarded into the container if set; takes precedence over an OAuth login |
| `CC_MEMORY` | `8g` | container memory |
| `CC_CPUS` | `4` | container CPUs |
| `CC_DOCKERFILE` | — | explicit Dockerfile path, skips discovery |
| `~/.config/claude-container/env` | — | optional `KEY=value` env file passed via `--env-file` (may hold the API key) |
| `~/.config/claude-container/managed-settings.json` | — | optional; mounted read-only at `/etc/claude-code/managed-settings.json` in every container |
| `~/.config/claude-container/share/` | — | optional; directory mounted read-only at `/opt/claude-container` in every container |
| `<project root>/claude-container.args` | — | optional; extra `container run` arguments, one per line (blank lines and `#` comments ignored; `{{root}}` and `{{cache}}` are expanded) |
