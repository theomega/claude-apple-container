# claude-container

Run Claude Code isolated inside [Apple Containers](https://github.com/apple/container).
Each session is a throwaway container that can only see the project it is
started in — nothing else on the host. Project-specific containers are built
from a `Dockerfile.dev` inside the project folder; if a project has none,
the default image definition from this repo is used. The project code is not
copied but mounted into the container, so edits land directly in your
working tree.

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
  RAM. Container names are `claude-<project>-<pathhash>-<pid>`, so
  concurrent sessions and same-named projects don't collide, and `stop`/`ls`
  are project-aware. Running `claude-container` twice in the same project
  therefore gives you two containers with one claude each. They are isolated
  from each other at the process level but share the image, the writable
  project mount, and the project's claude state dir — both claudes edit the
  same working tree, and one `claude-container stop` stops them all.
- **Isolation**: only the project root is mounted (writable, at its host
  absolute path). `--dangerously-skip-permissions` is the default because
  the container is the sandbox. Host git identity, `TERM`, and
  `ANTHROPIC_API_KEY` (if set) are forwarded as environment variables;
  nothing else from the host is visible. A `claude-container.args` file at
  the project root can add extra `container run` flags (see
  [Customization](#customization)).
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
  `claude --resume` sees the project's earlier sessions. Delete the dir to
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

## Example: Chrome and the chrome-devtools MCP server

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
| `<project root>/claude-container.args` | — | optional; extra `container run` arguments, one per line (blank lines and `#` comments ignored) |
