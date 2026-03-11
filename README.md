# Local Input Overrides

Reusable `devenv` module that generates `devenv.local.yaml` with local path overrides
for inputs in `devenv.yaml` whose remote repo name matches a local directory name
under `composer.localInputOverrides.reposRoot`.

It also walks local repos transitively. If repo `A` imports local repo `B`, and
`B` imports local repo `C`, then `A`'s generated `devenv.local.yaml` will include
overrides for both `B` and `C`.

## Includes

- `composer.localInputOverrides.*` options
- Materialized file: `devenv.local.yaml` (configurable)
- Output: `outputs.local_input_overrides`

## Notes

- Recursive scanning reuses the same `sourcePath` inside each local repo.
- That works best with the default `devenv.yaml`, or another repo-relative path
  shared across the repos in your polyrepo.
- `devenv.local.yaml` must exist before `devenv` starts. `devenv` loads local
  YAML during config/bootstrap, while this module runs later during Nix module
  evaluation. So the module can keep the file in sync, but it cannot bootstrap
  the current invocation from nothing by itself.
- Use the pre-bootstrap helper before `use devenv`:

```bash
if [ -x ../dvnv-local-inputs/bootstrap-local-inputs ]; then
  ../dvnv-local-inputs/bootstrap-local-inputs .
fi
eval "$(devenv direnvrc)"
use devenv
```

- Existing stale `devenv.local.yaml` files still need one refresh before newly
  discovered transitive overrides can affect the next evaluation.
- `bootstrap-local-inputs` prefers an existing `python3` with `PyYAML`
  available. If that import is missing, it falls back to a repo-owned pinned
  bootstrap environment under `bootstrap/`, so users do not need to edit global
  Nix configuration or install Python modules manually.

## Use

```yaml
inputs:
  dvnv-local-inputs:
    url: github:Alb-O/dvnv-local-inputs
    flake: false
imports:
  - dvnv-local-inputs
```
