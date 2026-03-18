# Poly Bootstrap

External bootstrap/runtime tooling for this polyrepo.

`poly-bootstrap` no longer exposes a shared `devenv` module for consumer repos.
Its job is to:

- read `polyrepo.nuon`
- generate `devenv.local.yaml` before `devenv` evaluation
- bootstrap manifest-declared dependency repos
- run manifest-declared bootstrap tasks such as `devenv:files`
- refresh the target repo lock/export state when needed

## Public Interface

- CLI: `bin/polyrepo.nu`
- Wrapper entrypoint: `bootstrap`
- Nushell module: `use nu/mod.nu [bootstrap bootstrap-all check sync]`

Commands:

```bash
nu bin/polyrepo.nu check .
nu bin/polyrepo.nu sync .
nu bin/polyrepo.nu bootstrap .
nu bin/polyrepo.nu bootstrap . --all-repos
```

Use `--json` with `check`, `sync`, or `bootstrap` for machine-readable status.

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
- The root workspace is first-class. `check .`, `sync .`, and `bootstrap .` work from the polyrepo root without `--polyrepo-root`.
- `devenv-run` and the direnv helper both call the same shared bootstrap function.

## Testing

Inside this repo:

```bash
bash ../agent-scripts/modules/devenv-run/devenv-run.sh -C . --shell 'run-nix-tests'
```
