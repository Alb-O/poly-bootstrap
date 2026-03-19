# AgentRoots

AgentRoots bootstrap and runtime tooling for this workspace.

Ownership:

- `agentroots` owns bootstrap, shell export reuse, `devenv-run`, `committer`, and the `agentroots/tooling` consumer module.

Responsibilities:

- read `agentroots.nuon`
- generate `devenv.local.yaml` before `devenv` evaluation
- bootstrap manifest-declared dependency repos
- run manifest-declared bootstrap tasks such as `devenv:files`
- refresh the target repo lock/export state when needed
- package `devenv-run` and `committer` for consumers via `agentroots/tooling`

## Public Interface

- CLI: `bin/agentroots.nu`
- CLI: `bin/devenv-run.nu`
- Wrapper entrypoint: `bootstrap`
- Consumer module: `tooling/default.nix`

Commands:

```bash
nu bin/agentroots.nu check .
nu bin/agentroots.nu sync .
nu bin/agentroots.nu bootstrap .
nu bin/agentroots.nu bootstrap . --all-repos
```

Use `--json` with `check`, `sync`, or `bootstrap` for machine-readable status.

Nu module layout:

- `nu/agentroots/mod.nu`
- `nu/agentroots/manifest.nu`
- `nu/agentroots/resolve.nu`
- `nu/agentroots/sync_runtime.nu`
- `nu/agentroots/bootstrap_runtime.nu`
- `nu/agentroots/check_runtime.nu`
- `nu/agentroots/common.nu`
- `nu/agentroots/devenv_run.nu`

Consumer imports are explicit:

```nix
imports = [
  inputs.agentroots.tooling
];
```

## Manifest Model

`agentroots.nuon` is the single source of truth. The runtime understands:

- `root.layers`
- `inputs`
- `layers`
- `repoGroups`
- `repos`

Key rules:

- `layers` replaces the old bundle/profile split.
- `repoGroups` expands to a canonical repo catalog.
- `bootstrapDeps` is the only recursion graph for bootstrap order.
- `bootstrapTasks` is the only declarative post-sync hook surface. `devenv:files` is currently the supported task.
- `inputs.<name>.localRepo` is required for locally rewritable inputs. URL-basename repo inference is gone.

## Notes

- `devenv.local.yaml` must exist before `devenv` starts; bootstrap is the only supported writer.
- `bootstrap --all-repos` targets only repos that expose `devenv.yaml` or `devenv.nix`.
- The root workspace is first-class. `check .`, `sync .`, and `bootstrap .` work from the AgentRoots root directly.
- `.agentroots_direnvrc` is only a shell bridge for direnv and calls `repos/agentroots/bootstrap`.
- `bin/devenv-run.nu` is the canonical command source packaged by `tooling/default.nix`.
- manifest parsing and catalog normalization live in `nu/agentroots/manifest.nu`.
- target resolution and validation live in `nu/agentroots/resolve.nu`.
- sync/bootstrap/check commands are split across `nu/agentroots/sync_runtime.nu`, `nu/agentroots/bootstrap_runtime.nu`, and `nu/agentroots/check_runtime.nu`.
- shared shell-export helper logic lives in `nu/agentroots/common.nu`.

## Testing

Inside this repo:

```bash
devenv-run -C . --shell 'run-nix-tests'
```
