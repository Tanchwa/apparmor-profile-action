# apparmor-profile-action

A reusable GitHub workflow that generates an AppArmor profile for an
application, opens a pull request with it, and lets GitHub merge that PR once
it has been approved.

The generated profile is committed **into the application's own repository**,
so the confinement policy is versioned, reviewed, and released alongside the
code it confines.

```
app repo                      this repo
┌──────────────────────┐      ┌──────────────────────────────────────┐
│ .github/workflows/   │      │ .github/workflows/                   │
│   apparmor.yml  ─────┼─uses─▶   apparmor-profile.yml               │
│                      │      │     └─ switch on `target`            │
│                      │      │          ├─ _docker/                 │
│                      │      │          └─ _host/                   │
│ apparmor.d/myapp  ◀──┼──PR──┤ scripts/aa_learn_start.sh            │
│ apparmor.spec.yaml   │      │ scripts/aa_learn_harvest.sh          │
│ Dockerfile           │      │ scripts/aa_from_logs.py              │
└──────────────────────┘      │ scripts/aa_from_spec.py              │
                              └──────────────────────────────────────┘
```

## Quick start

In the application repo, add `.github/workflows/apparmor.yml`:

```yaml
name: AppArmor profile

on:
  workflow_dispatch:
  schedule:
    - cron: '17 4 * * 1'

permissions:
  contents: write
  pull-requests: write

jobs:
  apparmor:
    uses: linkervision/apparmor-profile-action/.github/workflows/apparmor-profile.yml@v1
    with:
      name: myapp
      target: docker
      docker_image: myapp:ci
      docker_build: true
      docker_ports: |
        8080:8080
      detach: true
      ready_url: http://localhost:8080/healthz
      probe_urls: |
        http://localhost:8080/api/v1/items
    secrets:
      token: ${{ secrets.APPARMOR_BOT_TOKEN }}
```

The profile lands at `apparmor.d/myapp` in the application repo. Four worked
examples live in [`examples/`](examples/): docker, host binary, spec-only, and
a PR drift check.

## No input is ever executed as a shell command

This is the central design constraint, so it is worth stating plainly.

There is no `run:` or `setup_command:` input. Each sub-action bakes in its own
`docker build`, `docker run`, `apt-get`, `dpkg`, `curl` and process-control
commands. Callers supply **structured values** — an image tag, a list of
`KEY=VALUE` pairs, a list of URLs — and the action assembles them into argv
arrays. Nothing is passed through `bash -c`, `eval`, or string interpolation
into a script.

```yaml
# structured, becomes argv
docker_env: |
  LOG_LEVEL=debug
docker_args: |
  --selftest
probe_urls: |
  http://localhost:8080/healthz
```

Consequences worth knowing:

- `docker_args` and `host_args` are **one argument per line**, not a command
  line. `--config /etc/app.yaml` is two lines. Shell metacharacters are not
  interpreted, because no shell sees them.
- `entrypoint` is a single executable, not a shell line. If you need shell
  semantics inside the container, put them in the image's own entrypoint
  script where they belong — that is application code, reviewed as such.
- `probe_urls` and `ready_url` must be `http://` or `https://`; anything else
  is refused.
- Anything the schema genuinely cannot express belongs in `extra_rules` (which
  is profile text, not shell) or in the declarative spec.

`tests/run.sh` enforces this: it fails if `bash -c "$VAR"`, `sh -c "$VAR"` or
`eval` reappears in a sub-action, and if the workflow ever declares an input
named `run`, `command`, `script`, or `setup_command`.

## How a profile gets generated

Two generators. `generator: auto` (the default) picks runtime learning when
the runner has AppArmor and the target's inputs are present, and falls back to
the spec otherwise.

### Runtime learning (`generator: runtime`)

The accurate option, and the one to prefer. The sub-action:

1. Loads a stub profile that permits nothing beyond `abstractions/base` and
   carries the `complain` flag, so every other access is allowed but logged.
2. Runs your workload under it — a container started with
   `--security-opt apparmor=<learning profile>`, or the host binary the
   profile is attached to. Confinement is applied by the action, so it cannot
   be forgotten.
3. Exercises it: either runs to completion, or (`detach: true`) waits on
   `ready_url` and requests each of `probe_urls`.
4. Harvests the kernel audit records, then synthesizes an enforce-mode profile
   covering the files, capabilities, network families, signals, ptrace, mounts
   and exec transitions actually used.

The catch is inherent to the method, not to this implementation: **a learned
profile only covers the code paths CI exercised.** An endpoint absent from
`probe_urls` will be denied the first time production calls it. Probe broadly,
start in `mode: complain`, and read the diff.

### Declarative spec (`generator: spec`)

When the workload cannot be exercised meaningfully in CI, commit an
`apparmor.spec.yaml` next to the application and have the action render it.
Deterministic, no runner privileges needed, and the spec is the thing humans
review. See [`examples/apparmor.spec.yaml`](examples/apparmor.spec.yaml) for
the full schema:

```yaml
name: myapp
attach: /usr/bin/myapp
abstractions: [base, nameservice]
capabilities: [net_bind_service]
network: [inet stream]
files:
  read:  [/etc/myapp/**]
  write: [/var/lib/myapp/**]
  exec:
    - { path: /usr/bin/convert, mode: Px }
deny:
  read: [/etc/shadow, /home/**]
```

Note that `deny` perms are literal — `deny: {write: [...]}` emits `w`, never
`rw` — because a deny that quietly took reads with it would revoke access the
author never asked to revoke.

## Security model

Beyond the no-shell rule above:

| Property | How |
|---|---|
| The job that builds and runs the application has no write access | `generate` pins itself to `contents: read` |
| No git credential is left on disk for the workload to find | both checkouts in `generate` use `persist-credentials: false` |
| The write-scoped PAT never meets application code | `secrets.token` is referenced only in `propose`, which builds and runs nothing |
| A failed workload cannot silently produce a permissive profile | a non-zero exit fails the run unless `allow_workload_failure` is set |
| An unparseable profile cannot reach a PR | `apparmor_parser -Q` gates every generated profile |

See [On Job and Runner Boundaries](#on-job-and-runner-boundaries) for why the
application and the write token never share a runner.

Two things remain the caller's responsibility:

- **`sudo` on the runner.** Loading a profile and reading kernel messages
  require root, and GitHub-hosted runners grant passwordless `sudo`. On a
  *self-hosted* runner, anything you build and run in `generate` inherits that
  on a persistent machine. Use ephemeral runners.
- **Never wire attacker-controlled data into these inputs.** They are not
  shell, but `docker_volumes` can still mount a host path and `host_deb_package`
  still installs a package. Do not feed them `github.event.*` values, and keep
  the drift check on `pull_request`, never `pull_request_target` — see the
  comment at the top of
  [`examples/caller-drift-check.yml`](examples/caller-drift-check.yml).

## On Job and Runner Boundaries

Runtime learning works by **actually executing the application** — building its
image, starting it, driving its endpoints. That is not incidental to the
method, it *is* the method: a profile can only describe the file access and
syscalls that really happened.

That makes the runner doing the learning qualitatively different from the one
opening the pull request, so the two are deliberately kept apart:

- **`generate` builds and runs the application, and is treated as tainted.**
  It pins itself to `contents: read`, both of its checkouts use
  `persist-credentials: false`, and `secrets.token` is never referenced in it.
  Whatever the application does on that runner — including whatever a
  compromised dependency or base image does — happens with no write credential
  present to steal.
- **`propose` never builds or runs anything.** It starts on a fresh runner,
  checks out the base branch, copies in the profile, commits, and opens the
  PR. It is the only job that holds the write-scoped token.
- **Exactly one thing crosses the boundary:** the generated profile, passed as
  an upload/download artifact. It is a text file, and it is the artifact under
  review in the PR.

A single job would be simpler and marginally faster. It would also put the
application and the write token on the same machine, which is the one thing
this design is unwilling to do.

### Why docker and host are not also separate runners

The same reasoning does not extend to splitting the two targets apart. They
never run together — `target` selects one and the other job is skipped — so a
runner boundary between them separates nothing. And they differ by only about
four steps in the middle of an otherwise identical nine-step job:

```
resolve defaults → checkout app → checkout generator → [ GENERATE ] → diff → fail-on-drift → upload artifact
                                                        ^^^^^^^^^^
                                                     only this varies
```

As composite actions (`_docker/`, `_host/`), that scaffolding lives once in
`generate` and only the middle varies. As nested reusable workflows each
sub-workflow would become its own job on its own runner, so each would have to
repeat the whole scaffolding — or the parent keeps it and pays for a third
runner plus an artifact round trip just to diff a file it could otherwise have
written straight into the working tree.

Nested reusable workflows would otherwise work fine here:
`uses: ./.github/workflows/_docker.yml` inside a called workflow resolves from
*this* repository at the same commit, not the caller's, and GitHub allows ten
levels of nesting. The limitation that genuinely does apply is narrower, and is
why there is no action at the repository root: a relative `uses: ./_docker`
*inside a composite action* resolves against `$GITHUB_WORKSPACE` rather than
the action's own directory
([actions/runner#2101](https://github.com/actions/runner/issues/2101)). The
switch therefore lives in the reusable workflow, which checks this repo out to
a real workspace path.

## Permissions the caller must grant

The workflow runs as two jobs. `generate` pins itself to `contents: read`.
`propose` declares no permissions of its own and inherits whatever the caller
granted, so a repo running this read-only as a drift check is never forced to
hand out write access it does not need.

```yaml
# opening pull requests
permissions:
  contents: write
  pull-requests: write

# dry_run / fail_on_drift only
permissions:
  contents: read
```

If the caller grants too little, `propose` fails on the push with a 403.

## From PR to merge

Each run:

- force-pushes a single regenerated commit to `apparmor/<name>` (stable branch,
  so re-runs update one PR rather than piling up new ones),
- opens the PR, or edits the existing one, with a diff-focused body and a
  reviewer checklist,
- enables GitHub auto-merge (`gh pr merge --auto --squash`).

GitHub then merges it on its own once the branch's required approvals and
required checks are satisfied. Nothing merges without a human approving.

If the generated profile matches what is already committed, the run exits
having done nothing.

### Repository settings this depends on

Auto-merge is GitHub's feature; the workflow only arms it. For it to ever
fire, the application repo needs:

| Setting | Where | Why |
|---|---|---|
| **Allow auto-merge** | Settings → General → Pull Requests | `gh pr merge --auto` fails without it |
| **A ruleset or branch protection on the base branch requiring a review** | Settings → Rules / Branches | With nothing required, auto-merge has nothing to wait on and the PR merges instantly — unreviewed |
| **Allow GitHub Actions to create and approve pull requests** | Settings → Actions → General | Only needed when falling back to `GITHUB_TOKEN` |

By default the workflow warns and continues if auto-merge cannot be enabled,
leaving the PR open for a manual merge. Set `require_auto_merge: true` to make
that a hard failure instead.

### Why you want a PAT or App token

**Pull requests opened with the default `GITHUB_TOKEN` do not trigger
workflows.** This is a deliberate GitHub loop-guard, and it means the PR's
required status checks never start, so auto-merge waits forever on checks that
will never run.

Pass a personal access token or GitHub App installation token as the `token`
secret to avoid this. The token needs `contents: write` and
`pull-requests: write` on the application repo. A GitHub App is the better
choice: its tokens are short-lived and are not tied to a person.

## Inputs

### Target selection

| Input | Default | Description |
|---|---|---|
| `name` | *required* | Profile name. `[A-Za-z0-9_.-]` only. |
| `target` | `docker` | `docker` or `host`. Selects which sub-action runs. |
| `profile_path` | `apparmor.d/<name>` | Where the profile lives in the application repo. |

### `target: docker`

| Input | Default | Description |
|---|---|---|
| `docker_image` | `''` | Image to confine. Required unless `generator: spec`. |
| `docker_build` | `false` | Build the image from this repo first. |
| `docker_build_context` | `.` | Build context directory. |
| `docker_dockerfile` | `Dockerfile` | Dockerfile path. |
| `docker_build_args` | `''` | Newline-separated `KEY=VALUE`. |
| `docker_build_target` | `''` | Dockerfile stage to build. |
| `docker_entrypoint` | `''` | Single executable, not a shell line. |
| `docker_args` | `''` | Container arguments, **one per line**. |
| `docker_env` | `''` | Newline-separated `KEY=VALUE`. |
| `docker_ports` | `''` | Newline-separated `HOST:CONTAINER`. |
| `docker_volumes` | `''` | Newline-separated `SOURCE:TARGET[:ro]`. |
| `docker_user` / `docker_workdir` / `docker_network` | `''` | Passed to `docker run`. |
| `docker_stop_timeout` | `10` | Seconds to allow a detached container to stop. |

### `target: host`

| Input | Default | Description |
|---|---|---|
| `host_binary` | `''` | Absolute path to the executable; also the attachment path. Required. |
| `host_args` | `''` | Arguments, **one per line**. |
| `host_env` | `''` | Newline-separated `KEY=VALUE`. |
| `host_workdir` | `''` | Directory to run from. |
| `host_run_as` | `''` | Run as this user via `sudo -u`. |
| `host_apt_packages` | `''` | Newline-separated packages installed before learning. |
| `host_deb_package` | `''` | A `.deb` installed with `dpkg` before learning. |
| `host_stop_signal` | `TERM` | Signal used to stop a detached binary. |
| `host_stop_timeout` | `10` | Seconds before escalating to `KILL`. |

### Exercising the workload (both targets)

| Input | Default | Description |
|---|---|---|
| `detach` | `false` | Run in the background and exercise over HTTP. |
| `ready_url` | `''` | Poll this `http(s)` URL until it answers. |
| `ready_timeout` | `60` | Seconds to wait for readiness. |
| `probe_urls` | `''` | Newline-separated `http(s)` URLs to request. |
| `probe_timeout` | `10` | Per-request timeout. |
| `run_timeout` | `300` | Seconds allowed for a non-detached workload. |
| `allow_workload_failure` | `false` | Generate even if the workload or probes fail. |

### Profile shaping

| Input | Default | Description |
|---|---|---|
| `generator` | `auto` | `auto`, `runtime`, or `spec`. |
| `spec_file` | `apparmor.spec.yaml` | Spec consumed by the `spec` generator. |
| `mode` | `enforce` | `enforce` or `complain`. |
| `abi` | `''` | Pin the policy language version, e.g. `3.0`. |
| `flags` | `attach_disconnected,mediate_deleted` | Profile flags. |
| `abstractions` | `base` | Comma-separated abstractions to include. |
| `exec_mode` | `ix` | Transition for learned executables: `ix`, `Px`, `Ux`, `Cx`. |
| `generalize` | `true` | Replace per-run path components (pids, tids) with globs. |
| `glob_threshold` | `0` | Collapse N+ siblings sharing a permission set into `<dir>/*`. `0` disables. |
| `exclude` | `''` | Newline-separated regexes of learned paths to drop. |
| `rewrite` | `''` | Newline-separated `REGEX=REPLACEMENT` path rewrites. |
| `extra_rules` | `''` | Newline-separated profile rules appended verbatim. |
| `settle_seconds` | `3` | Wait before harvesting audit records. |
| `load_check` | `false` | Load the profile into the kernel as an extra validation step. |

### Pull request and merge

| Input | Default | Description |
|---|---|---|
| `ref` | base branch, or the triggering ref under `dry_run` | Ref to generate from. |
| `branch` | `apparmor/<name>` | Head branch. |
| `base` | repo default branch | Base branch. |
| `commit_message` | `chore(apparmor): update <name> profile` | Commit subject. |
| `pr_title` | commit subject | PR title. |
| `pr_body` | `''` | Markdown appended to the generated body. |
| `labels` | `apparmor,security` | Labels to apply. |
| `reviewers` / `team_reviewers` | `''` | Review requests. |
| `draft` | `false` | Open as draft. Auto-merge cannot be armed on a draft. |
| `auto_merge` | `true` | Arm GitHub auto-merge. |
| `merge_method` | `squash` | `squash`, `merge`, or `rebase`. |
| `require_auto_merge` | `false` | Fail if auto-merge cannot be enabled. |

### Modes and plumbing

| Input | Default | Description |
|---|---|---|
| `dry_run` | `false` | Generate and validate only; never push or open a PR. |
| `fail_on_drift` | `false` | Fail when the committed profile differs. Pair with `dry_run`. |
| `runs_on` | `ubuntu-latest` | Runner label. Runtime learning needs AppArmor. |
| `action_repo` | `linkervision/apparmor-profile-action` | Where the sub-actions are fetched from. |
| `action_ref` | `main` | Ref the sub-actions and scripts are fetched from. **Pin to the same tag you call the workflow with** — calling `@v1` while this says `main` runs v1's workflow against main's generator. Overridden automatically by `GITHUB_JOB_WORKFLOW_SHA` where the runner provides it. |
| `timeout_minutes` | `30` | Job timeout. |

### Outputs

| Output | Description |
|---|---|
| `changed` | `true` when the generated profile differs from what is committed. |
| `profile_path` | Path of the profile in the application repo. |
| `generator_used` | `runtime` or `spec`. |
| `pr_number` / `pr_url` | The opened or updated PR. Empty when nothing changed. |

## Using a sub-action directly

The sub-actions generate and validate without any of the PR machinery. Use one
when you want the profile inside a job you already control:

```yaml
- uses: linkervision/apparmor-profile-action/_docker@v1
  with:
    name: myapp
    output: apparmor.d/myapp
    image: myapp:ci
    build: true
    detach: true
    ready_url: http://localhost:8080/healthz

- uses: linkervision/apparmor-profile-action/_host@v1
  with:
    name: usr.bin.myapp
    output: packaging/apparmor.d/usr.bin.myapp
    binary: /usr/bin/myapp
```

There is deliberately no action at the repository root, and the docker/host
split is composite actions rather than separate jobs. Both choices are
explained in [On Job and Runner Boundaries](#on-job-and-runner-boundaries).

Or run the scripts directly on a developer machine:

```bash
sudo ./scripts/aa_learn_start.sh --name myapp --state /tmp/aa --template container
docker run --rm --security-opt apparmor=aa-learn-myapp myapp:ci --selftest
./scripts/aa_learn_harvest.sh --state /tmp/aa --out audit.log
./scripts/aa_from_logs.py audit.log --profile aa-learn-myapp --name myapp \
  --template container -o apparmor.d/myapp
./scripts/validate.sh apparmor.d/myapp
```

## Applying the profile

Nothing here loads profiles onto production hosts — that belongs to your
deployment pipeline. Once the PR merges, the committed file is used like any
other policy:

```bash
# container
sudo apparmor_parser -r -W apparmor.d/myapp
docker run --security-opt apparmor=myapp myapp:1.2.3

# host binary (package it into /etc/apparmor.d/)
sudo install -m 0644 packaging/apparmor.d/usr.bin.myapp /etc/apparmor.d/
sudo apparmor_parser -r /etc/apparmor.d/usr.bin.myapp
```

## Reviewing a generated profile

The PR body carries this checklist, and it is worth taking seriously — a
learned profile is a transcript of one CI run, not a security decision:

- No rule grants more than the workload needs, especially under `/etc`,
  `/proc` and `/sys`.
- No capability appears that the application should not hold. `sys_admin`,
  `dac_override` and `sys_ptrace` deserve particular suspicion.
- Network rules match the families and socket types the service really uses.
- Executable transitions are the ones you want: `ix` keeps the child in this
  profile, `Px` demands the child have its own, `Ux` drops confinement
  entirely and is almost never right.
- Paths that encode a build id, hostname, or timestamp are globbed, not
  pinned — otherwise the profile breaks on the next deploy. Use `rewrite` to
  generalize them.

## Limitations

- **Coverage follows the CI run.** Unexercised code paths are missing from a
  learned profile. This is the central caveat; see above.
- **Runtime learning needs an AppArmor-enabled Linux runner.** GitHub-hosted
  `ubuntu-*` runners qualify. macOS, Windows, and most container-based
  self-hosted runners do not; those must use `generator: spec`.
- **`--security-opt apparmor=` is silently ignored where AppArmor is absent.**
  Docker Desktop accepts the flag and applies nothing, so "the container ran"
  is not evidence the profile was in effect. The learning step therefore gates
  on `/sys/kernel/security/apparmor` existing, and the harvest step fails if
  zero audit records matched the profile — do not weaken either check.
- **`sudo` is required** on the runner to load the learning profile and read
  kernel messages.
- **Probing is HTTP only.** A workload exercised over gRPC, AMQP or a CLI
  needs `detach: false` with `docker_args`/`host_args` driving it, or a
  self-test subcommand in the image.
- **Audit records can be lost** if the kernel ring buffer wraps during a very
  chatty run. Keep the exercised workload tight, or install `auditd` on a
  self-hosted runner.
- Profile stacking (`profile//child`) is harvested but emitted flat; hand-write
  child profiles via `extra_rules` or the spec's `children` key.

## Development

```bash
tests/run.sh                 # golden files, wiring cross-check, no-shell check
UPDATE_GOLDEN=1 tests/run.sh # refresh expectations after an intentional change
shellcheck scripts/*.sh tests/*.sh
actionlint .github/workflows/*.yml
```

`tests/check_wiring.py` cross-checks every input the reusable workflow forwards
against what each sub-action declares, and every example caller against the
workflow. actionlint cannot do this, because the sub-action paths only exist
at runtime.

CI additionally runs end-to-end learning for both targets against real
workloads and loads every golden profile into the kernel, so a profile the
real `apparmor_parser` rejects cannot be released.

## Releasing

Callers pin `@v1`. After merging to `main`:

```bash
git tag -f v1 && git push -f origin v1
```

Keep the `action_ref` input default in sync with the tag you publish, since
the reusable workflow fetches its own sub-actions by that ref.
