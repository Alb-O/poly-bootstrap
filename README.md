# Local Input Overrides

Reusable `devenv` module that generates `devenv.local.yaml` with local path overrides
for inputs in `devenv.yaml` whose remote repo name matches a local directory name
under `materializer.localInputOverrides.reposRoot`.

## Includes

- `materializer.localInputOverrides.*` options
- Materialized file: `devenv.local.yaml` (configurable)
- Output: `outputs.materialized_local_input_overrides`

## Use

```yaml
inputs:
  env-local-overrides:
    url: github:Alb-O/env-local-overrides
    flake: false
imports:
  - env-local-overrides
```
