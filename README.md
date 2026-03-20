# AgentRoots

AgentRoots bootstrap, runtime, CLI, and consumer-module tooling for this workspace.

Ownership:

- `agentroots` owns bootstrap, shell export reuse, `agentroots`, `run`, `committer`, and the `agentroots/module` consumer module.

Responsibilities:

- read `agentroots.nuon`
- generate `devenv.local.yaml` before `devenv` evaluation
- bootstrap manifest-declared dependency repos
- run manifest-declared bootstrap tasks such as `devenv:files`
- refresh the target repo lock/export state when needed
- package `agentroots`, `run`, and `committer` for consumers via `agentroots/module`

## Public Interface

- CLI: `cli/agentroots.nu`
- CLI: `cli/run.nu`
- Wrapper entrypoint: `bootstrap`
- Consumer module: `module/default.nix`

Commands:

```bash
nu cli/agentroots.nu check .
nu cli/agentroots.nu sync .
nu cli/agentroots.nu bootstrap .
nu cli/agentroots.nu bootstrap . --all-repos
```

Use `--json` with `check`, `sync`, or `bootstrap` for machine-readable status.

Nu module layout:

- `lib/nu/mod.nu`
- `lib/nu/manifest.nu`
- `lib/nu/resolve.nu`
- `lib/nu/sync.nu`
- `lib/nu/bootstrap.nu`
- `lib/nu/check.nu`
- `lib/nu/shell_export.nu`
- `lib/nu/run.nu`

Consumer imports are explicit:

```nix
imports = [
  inputs.agentroots.module
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
- `cli/run.nu` is the canonical command source packaged by `module/default.nix`.
- manifest parsing and catalog normalization live in `lib/nu/manifest.nu`.
- target resolution and validation live in `lib/nu/resolve.nu`.
- sync/bootstrap/check commands are split across `lib/nu/sync.nu`, `lib/nu/bootstrap.nu`, and `lib/nu/check.nu`.
- shared shell-export helper logic lives in `lib/nu/shell_export.nu`.

## Maintenance Rules

- command modules keep clean filenames and export `main`; import them with `use ... *`
- the public consumer-module contract lives in `module/`
- `nix/runtime-files.txt` is the single packaged-runtime manifest; update it with any runtime file move
- fixture checkouts that stub AgentRoots as an input must include the runtime manifest and every listed runtime file they depend on

## Testing

Inside this repo:

```bash
run -C . --shell 'run-nix-tests'
```
