#!/usr/bin/env nu

use ../nu/cli.nu [build-sync-spec render-json-status sync-help-requested]
use ../nu/commands.nu [check-polyrepo-manifest lock-status render-manifest-file sync-local-overrides]

# Generate manifest-owned local input overrides for sibling repos.
#
# Use `main sync` for normal repo updates, `main render-manifest` for machine
# renderers, and `main lock-status` for lockfile diagnostics.
def main [] {
  help main
}

# Render local input overrides from a single machine manifest.
#
# The manifest is a JSON mapping with the current repo name, inline
# `polyrepo.nuon` text, filtered local repo paths, include/exclude filters, and
# the URL scheme.
def "main render-manifest" [
  manifest_path: path # JSON manifest describing one render invocation.
] {
  print --raw (render-manifest-file $manifest_path)
}

# Validate the enclosing polyrepo manifest and local repo catalog.
#
# This checks normalized manifest references and, when run against a checkout,
# verifies that declared repo paths resolve under repoDirsPath and point at repo
# roots.
def "main check" [
  start_path?: path               # Repo or polyrepo path to inspect. Defaults to `.`.
  --polyrepo-root (-p): path      # Explicit polyrepo root when inference is not possible.
  --json (-j)                     # Emit structured JSON status.
] {
  let status = check-polyrepo-manifest $start_path $polyrepo_root

  if $json {
    render-json-status $status true
  } else if $status.ok {
    $"ok: ($status.repo_count) repos validated from ($status.manifest_path)"
  } else {
    $status.errors
    | each {|entry| $"($entry.path): ($entry.message)" }
    | str join "\n"
  }
}

# Sync local input overrides into a repo checkout.
#
# Repeat `--include-repo`/`-i`, `--exclude-repo`/`-x`,
# `--include-input`/`-I`, and `--exclude-input`/`-X` as needed.
# Use `sync --help` to view the documented signature even though those
# repeatable filters are parsed from the wrapped rest arguments.
def --wrapped "main sync" [
  repo_root?: path                # Consumer repo root. Defaults to `.`.
  --output-path (-o): path        # Generated override YAML path inside the consumer repo.
  --polyrepo-root (-p): path      # Explicit polyrepo root when inference is not possible.
  --repo-dirs-path (-r): path     # Path to the sibling repo directory. Defaults to repoDirsPath from polyrepo.nuon.
  --url-scheme (-u): string       # Override URL scheme: path or git+file.
  --json (-j)                     # Emit structured JSON status instead of silence.
  ...rest: string                 # Repeatable include/exclude filters.
] {
  if (sync-help-requested $repo_root $rest) {
    return (help main sync)
  }

  let spec = build-sync-spec $repo_root $output_path $polyrepo_root $repo_dirs_path $url_scheme $rest
  render-json-status (sync-local-overrides $spec) $json
}

# Report whether `devenv.local.yaml` and `devenv.lock` are aligned.
#
# Use `--json` for structured output.
def "main lock-status" [
  output_path: path   # Generated devenv.local.yaml path.
  lock_path: path     # devenv.lock path to compare against.
  --json (-j)         # Emit structured JSON status.
] {
  let status = lock-status $output_path $lock_path

  if $json {
    render-json-status $status true
  } else if ($status.input_name | describe) == 'string' {
    $"($status.status):($status.input_name)"
  } else {
    $status.status
  }
}
