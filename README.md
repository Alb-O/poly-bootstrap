# Poly Bootstrap

Polyrepo-specific bootstrap and runtime tooling for this workspace.

Ownership:

- `poly-bootstrap` owns bootstrap, root discovery, shell export reuse, `devenv-run`, and the `poly-bootstrap/tooling` consumer module.
- `agent-scripts` owns only generic reusable tools such as `committer`.

Responsibilities:

- read `polyrepo.nuon`
- generate `devenv.local.yaml` before `devenv` evaluation
- bootstrap manifest-declared dependency repos
- run manifest-declared bootstrap tasks such as `devenv:files`
- refresh the target repo lock/export state when needed
- package `devenv-run` for consumers via `poly-bootstrap/tooling`

## Public Interface

- CLI: `bin/polyrepo.nu`
- Wrapper entrypoint: `bootstrap`
- Consumer module: `tooling/default.nix`

Commands:

```bash
nu bin/polyrepo.nu check .
nu bin/polyrepo.nu sync .
nu bin/polyrepo.nu bootstrap .
nu bin/polyrepo.nu bootstrap . --all-repos
```

Use `--json` with `check`, `sync`, or `bootstrap` for machine-readable status.

Consumer imports are explicit:

```nix
imports = [
  inputs.agent-scripts.tooling
  inputs.poly-bootstrap.tooling
];
```

## Manifest Model

`polyrepo.nuon` is the single source of truth. The runtime understands:

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
- The root workspace is first-class. `check .`, `sync .`, and `bootstrap .` work from the polyrepo root directly.
- `.polyrepo-direnvrc` and `devenv-run` both source `sh/polyrepo.sh`.
- `sh/devenv-run.sh` is the canonical command source packaged by `tooling/default.nix`.

## Testing

Inside this repo:

```bash
devenv-run -C . --shell 'run-nix-tests'
```
