# Poly Bootstrap

Reusable `devenv` module that generates `devenv.local.yaml` with local path overrides
for inputs in `devenv.yaml` whose remote repo name matches a local repo discovered
under the consumer repo directory configured by `composer.localInputOverrides.repoDirsPath`.

It also walks local repos transitively. If repo `A` imports local repo `B`, and
`B` imports local repo `C`, then `A`'s generated `devenv.local.yaml` will include
overrides for both `B` and `C`.

## Includes

- `composer.localInputOverrides.*` options
- Materialized file: `devenv.local.yaml` (configurable)
- Output: `outputs.local_input_overrides`

## Public Interfaces

- Human CLI: `bin/local-overrides.nu sync`
- Bootstrap CLI: `bin/bootstrap-repo.nu`
- Machine CLI: `bin/local-overrides.nu render-manifest <manifest.json>`
- Supported Nushell module: `use nu/mod.nu [bootstrap render-local-overrides sync-local-overrides lock-status]`

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
source_up_if_exists .envrc
eval "$(devenv direnvrc)"
use devenv
```

- Repo discovery scans direct children of `repoDirsPath`, and if a child is not
  itself a repo root, it scans that child one level deeper. This supports grouped
  layouts such as `repos/nusim/nusim_app` without doing a deep recursive walk.

- Existing stale `devenv.local.yaml` files still need one refresh before newly
  discovered transitive overrides can affect the next evaluation.
- `bootstrap` also refreshes `devenv.lock` when the generated local
  inputs and the current lockfile root inputs drift, even if `devenv.local.yaml`
  itself did not change. It now decides that from `sync --json` status instead
  of reparsing CLI text output.
- `bootstrap` now recursively bootstraps discovered local dependency
  repos before updating the current repo, so cross-repo `A -> B -> C` chains do
  not require users to pre-enter `B` or `C` with `direnv` first.
- `bootstrap` also scans `Cargo.toml`, falling back to `Cargo.poly.toml`,
  for local dependency tables with `path = ...` and bootstraps those sibling
  repos before refreshing generated files with `devenv:files`. This covers
  managed-Cargo workspaces such as `nusim_app -> nusim_backend -> nusim_core`
  without manually entering each repo first.
- `bin/bootstrap-repo.nu` contains the actual bootstrap logic. The
  sibling top-level `bootstrap` Bash file is only a thin launcher
  that `exec`s into `nu` when available, or falls back to the repo-owned pinned
  bootstrap environment under `nix/flake-bootstrap/`.

## Use

```yaml
inputs:
  poly-bootstrap:
    url: github:Alb-O/poly-bootstrap
    flake: false
imports:
  - poly-bootstrap

composer.localInputOverrides = {
  polyrepoRoot = "/path/to/polyrepo";
  repoDirsPath = "repos";
  excludeRepos = [ "big-experimental-repo" ];
  includeInputs = [ "agent-scripts" "poly-docs-env" ];
};
```

When the current repo already lives under `${polyrepoRoot}/${repoDirsPath}/...`,
or one grouping directory below it, `polyrepoRoot` can usually be omitted and inferred. Top-level polyrepo configs
should set it explicitly.

## CLI

Normal repo update:

```bash
nu bin/local-overrides.nu sync .
```

Bootstrap a repo before `devenv` starts:

```bash
nu bin/bootstrap-repo.nu .
```

Structured status for automation:

```bash
nu bin/local-overrides.nu sync --json .
```

Machine render from one manifest file:

```bash
nu bin/local-overrides.nu render-manifest render-spec.json
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
use nu/mod.nu [bootstrap render-local-overrides sync-local-overrides lock-status]
```

## Global Defaults

Create `${polyrepoRoot}/.devenv-global-inputs.yaml` to define shared defaults
once for the whole polyrepo:

```yaml
inputs:
  agent-scripts:
    url: github:Alb-O/agent-scripts
    flake: false
  nusurf:
    url: github:Alb-O/nusurf
    flake: false
  poly-docs-env:
    url: github:Alb-O/poly-docs-env
    flake: false
imports:
  - agent-scripts
  - nusurf/nushell-plugin
```

Rules:

- consumer-declared inputs in `devenv.yaml` win on name collisions
- global defaults still participate in local-path resolution
- transitive scanning also applies to matching global defaults
- shared imports are only emitted when the input exists after merging
- nested imports such as `repo-name/subdir` are supported and are matched against the base input name
