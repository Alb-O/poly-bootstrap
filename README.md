# Local Input Overrides

Reusable `devenv` module that generates `devenv.local.yaml` with local path overrides
for inputs in `devenv.yaml` whose remote repo name matches a local directory name
under the consumer repo directory configured by `composer.localInputOverrides.repoDirsPath`.

It also walks local repos transitively. If repo `A` imports local repo `B`, and
`B` imports local repo `C`, then `A`'s generated `devenv.local.yaml` will include
overrides for both `B` and `C`.

## Includes

- `composer.localInputOverrides.*` options
- Materialized file: `devenv.local.yaml` (configurable)
- Output: `outputs.local_input_overrides`

## Public Interfaces

- Human CLI: `poly-local-inputs.nu sync`
- Machine CLI: `poly-local-inputs.nu render-manifest <manifest.json>`
- Supported Nushell module: `use nu/mod.nu [render-local-overrides sync-local-overrides lock-status]`

## Testing

Inside this repo's own shell:

```bash
devenv shell --no-tui -- bash -lc 'run-nix-tests'
```

## Options

- `polyrepoRoot`: actual polyrepo root
- `repoDirsPath`: directory path containing consumer repos
- `sourcePath`: source YAML to scan for inputs
- `outputPath`: generated override file path
- `urlScheme`: generated override URL scheme
- `includeRepos` / `excludeRepos`: repo directory filters
- `includeInputs` / `excludeInputs`: input name filters

## Notes

- Recursive scanning reuses the same `sourcePath` inside each local repo.
- That works best with the default `devenv.yaml`, or another repo-relative path
  shared across the repos in your polyrepo.
- If `${polyrepoRoot}/.devenv-global-inputs.yaml` exists, its `inputs` are
  treated as low-precedence defaults for every generated `devenv.local.yaml`.
- `devenv.local.yaml` must exist before `devenv` starts. `devenv` loads local
  YAML during config/bootstrap, while this module runs later during Nix module
  evaluation. So the module can keep the file in sync, but it cannot bootstrap
  the current invocation from nothing by itself.
- Use the pre-bootstrap helper before `use devenv`:

```bash
if [ -x ../poly-local-inputs/bootstrap-local-inputs ]; then
  ../poly-local-inputs/bootstrap-local-inputs .
fi
eval "$(devenv direnvrc)"
use devenv
```

- Existing stale `devenv.local.yaml` files still need one refresh before newly
  discovered transitive overrides can affect the next evaluation.
- `bootstrap-local-inputs` also refreshes `devenv.lock` when the generated local
  inputs and the current lockfile root inputs drift, even if `devenv.local.yaml`
  itself did not change. It now decides that from `sync --json` status instead
  of reparsing CLI text output.
- `bootstrap-local-inputs` now recursively bootstraps discovered local dependency
  repos before updating the current repo, so cross-repo `A -> B -> C` chains do
  not require users to pre-enter `B` or `C` with `direnv` first.
- `bootstrap-local-inputs` prefers an existing `nu`. If Nushell is not already
  available, it falls back to a repo-owned pinned bootstrap environment under
  `nix/flake-bootstrap/`, so users do not need to edit global Nix
  configuration first.

## Use

```yaml
inputs:
  poly-local-inputs:
    url: github:Alb-O/poly-local-inputs
    flake: false
imports:
  - poly-local-inputs

composer.localInputOverrides = {
  polyrepoRoot = "/path/to/polyrepo";
  repoDirsPath = "repos";
  excludeRepos = [ "big-experimental-repo" ];
  includeInputs = [ "agent-scripts" "poly-docs-env" ];
};
```

When the current repo already lives under `${polyrepoRoot}/${repoDirsPath}/...`,
`polyrepoRoot` can usually be omitted and inferred. Top-level polyrepo configs
should set it explicitly.

## CLI

Normal repo update:

```bash
nu poly-local-inputs.nu sync .
```

Structured status for automation:

```bash
nu poly-local-inputs.nu sync --json .
```

Machine render from one manifest file:

```bash
nu poly-local-inputs.nu render-manifest render-spec.json
```

Manifest shape:

```json
{
  "source_yaml_text": "inputs: {}",
  "global_inputs_yaml_text": "",
  "local_repo_names": ["agent-scripts"],
  "repo_sources": {
    "agent-scripts": "inputs: {}"
  },
  "include_inputs": [],
  "exclude_inputs": [],
  "repo_dirs_root": "/path/to/polyrepo/repos",
  "url_scheme": "path"
}
```

Supported Nushell module:

```nu
use nu/mod.nu [render-local-overrides sync-local-overrides lock-status]
```

## Global Defaults

Create `${polyrepoRoot}/.devenv-global-inputs.yaml` to define shared defaults
once for the whole polyrepo:

```yaml
inputs:
  agent-scripts:
    url: github:Alb-O/agent-scripts
    flake: false
  poly-docs-env:
    url: github:Alb-O/poly-docs-env
    flake: false
imports:
  - agent-scripts
```

Rules:

- consumer-declared inputs in `devenv.yaml` win on name collisions
- global defaults still participate in local-path resolution
- transitive scanning also applies to matching global defaults
- shared imports are only emitted when the input exists after merging
- nested imports such as `repo-name/subdir` are supported and are matched against the base input name
