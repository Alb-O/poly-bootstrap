# Local Input Overrides

Reusable `devenv` module that generates `devenv.local.yaml` with local path overrides
for inputs in `devenv.yaml` whose remote repo name matches a local directory name
under `composer.localInputOverrides.reposRoot`.

## Includes

- `composer.localInputOverrides.*` options
- Materialized file: `devenv.local.yaml` (configurable)
- Output: `outputs.local_input_overrides`

## Use

```yaml
inputs:
  dvnv-local-inputs:
    url: github:Alb-O/dvnv-local-inputs
    flake: false
imports:
  - dvnv-local-inputs
```
