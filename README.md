# Poly Bootstrap

Reusable `devenv` module that generates `devenv.local.yaml` with local path overrides
for inputs in `devenv.yaml` whose remote repo name matches a local repo declared
in the enclosing `polyrepo.nuon` manifest.

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
- `repoDirsPath`: optional override for the consumer repo directory path. When omitted, read it from `polyrepo.nuon`.
- `sourcePath`: source YAML to scan for inputs
- `outputPath`: generated override file path
- `urlScheme`: generated override URL scheme
- `includeRepos` / `excludeRepos`: repo directory filters
- `includeInputs` / `excludeInputs`: input name filters

## Notes

- Recursive scanning reuses the same `sourcePath` inside each local repo.
- That works best with the default `devenv.yaml`, or another repo-relative path
  shared across the repos in your polyrepo.
- Nested imports such as `repo-name/subdir` resolve to a real module path inside
  the input repo. They do not refer to an `outputs.<name>` attr.
- `${polyrepoRoot}/polyrepo.nuon` owns the repo catalog through `repos`, and
  also provides `sharedInputs` / `sharedImports` for generated
  `devenv.local.yaml` files.
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

- A repo belongs to the polyrepo only when its path appears in `polyrepo.nuon`.
  The runtime and Nix paths both use that manifest-owned repo catalog instead of
  scanning the filesystem heuristically.

- Existing stale `devenv.local.yaml` files still need one refresh before newly
  discovered transitive overrides can affect the next evaluation.
- `bootstrap` also refreshes `devenv.lock` when the generated local
  inputs and the current lockfile root inputs drift, even if `devenv.local.yaml`
  itself did not change. It now decides that from `sync --json` status instead
  of reparsing CLI text output.
- `bootstrap` now also ensures a `.devenv/shell-*.sh` export exists for the
  root repo, so first-run workflows can materialize a usable shell export before
  `devenv-run` tries to reuse it.
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
  excludeRepos = [ "big-experimental-repo" ];
  includeInputs = [ "agent-scripts" "poly-docs-env" ];
};
```

When the current repo appears in the enclosing `polyrepo.nuon` repo catalog,
`polyrepoRoot` can usually be omitted and inferred. Top-level polyrepo configs
should still set it explicitly.

## Which Command To Use

- `bootstrap`: first-run or repair path. Use this when local overrides, lock
  inputs, generated files, or shell exports may be stale or missing.
- `devenv-run`: reuse path. Use this for normal command execution after the repo
  has a generated shell export. It can self-heal on first use, but steady-state
  runs stay lighter because they reuse the export instead of entering the shell.
- `devenv shell --no-tui -- bash -lc '<cmd>'`: full shell path. Use this when
  you intentionally want shell tasks and hooks to run.

## CLI

Normal repo update:

```bash
nu bin/local-overrides.nu sync .
```

Bootstrap a repo before `devenv` starts:

```bash
nu bin/bootstrap-repo.nu .
```

Bootstrap every repo declared in the manifest catalog:

```bash
nu bin/bootstrap-repo.nu --all-repos --polyrepo-root /path/to/polyrepo
```

Structured status for automation:

```bash
nu bin/local-overrides.nu sync --json .
```

Structured bootstrap status for one repo or all repos:

```bash
nu bin/bootstrap-repo.nu --json .
nu bin/bootstrap-repo.nu --all-repos --json --polyrepo-root /path/to/polyrepo
```

Machine render from one manifest file:

```bash
nu bin/local-overrides.nu render-manifest render-spec.json
```

Manifest shape:

```json
{
  "source_yaml_text": "inputs: {}",
  "polyrepo_manifest_text": "{ sharedInputs: {} }",
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

## Polyrepo Manifest

Create `${polyrepoRoot}/polyrepo.nuon` to define shared defaults once for the
whole polyrepo:

```nuon
{
  repoDirsPath: "repos"

  repos: [
    "repos/agent-scripts"
    "repos/nusurf"
  ]

  sharedInputs: {
    agent-scripts: {
      url: "github:Alb-O/agent-scripts"
      flake: false
      imports: [ "agent-scripts" ]
    }
    nusurf: {
      url: "github:Alb-O/nusurf"
      flake: false
      imports: [ "nusurf/nushell-plugin" ]
    }
  }
}
```

`repos` is the authoritative repo catalog for bootstrap, root inference, and
local path override resolution. Each entry is a repo-relative or absolute repo
root path.

Each `sharedInputs.<name>` entry accepts the normal input spec fields plus an
optional `imports` list. `sharedImports` can be used for imports that are not
attached to one specific shared input.

Rules:

- consumer-declared inputs in `devenv.yaml` win on name collisions
- shared polyrepo defaults still participate in local-path resolution
- transitive scanning also applies to matching shared polyrepo defaults
- shared imports are only emitted when the input exists after merging
- nested imports such as `repo-name/subdir` are supported, matched against the base input name, and resolved as real module paths inside the input repo

## Shared Module Rule

Shared devenv modules should resolve required cross-repo build inputs through
`inputs`, not sibling checkout path assumptions. `nusurf/nushell-plugin` is the
reference example: it imports `poly-rust-env` through `inputs.poly-rust-env`
instead of assuming a neighboring checkout path exists at evaluation time.
