#!/usr/bin/env nu

use ../nu/cli.nu [parse-repeatable-sync-flags]
use ../nu/commands.nu [lock-status render-manifest-file sync-local-overrides]

# Generate local input overrides for sibling repos.
#
# Use `main sync` for normal repo updates, `main render-manifest` for machine
# renderers, and `main lock-status` for lockfile diagnostics.
def main [] {
  help main
}

# Render local input overrides from a single machine manifest.
#
# The manifest is a JSON mapping with inline YAML text, repo lists, repo source
# text, include/exclude filters, the repo directory root, and the URL scheme.
def "main render-manifest" [
  manifest_path: string # JSON manifest describing one render invocation.
] {
  render-manifest-file $manifest_path
}

# Sync local input overrides into a repo checkout.
#
# Repeat `--include-repo`/`-i`, `--exclude-repo`/`-x`,
# `--include-input`/`-I`, and `--exclude-input`/`-X` as needed.
# Use `sync --help` to view the documented signature even though those
# repeatable filters are parsed from the wrapped rest arguments.
def --wrapped "main sync" [
  repo_root?: string              # Consumer repo root. Defaults to `.`.
  --source-path (-s): string      # Source YAML path inside the consumer repo.
  --output-path (-o): string      # Generated override YAML path inside the consumer repo.
  --polyrepo-root (-p): string    # Explicit polyrepo root when inference is not possible.
  --repo-dirs-path (-r): string   # Path to the sibling repo directory.
  --url-scheme (-u): string       # Override URL scheme: path or git+file.
  --json (-j)                     # Emit structured JSON status instead of silence.
  ...rest: string                 # Repeatable include/exclude filters.
] {
  if ('--help' in $rest) or ('-h' in $rest) or ($repo_root == '--help') or ($repo_root == '-h') {
    return (help main sync)
  }

  let parsed = parse-repeatable-sync-flags $rest
  let repo_root = ($repo_root | default ".")
  let source_path = ($source_path | default "devenv.yaml")
  let output_path = ($output_path | default "devenv.local.yaml")
  let repo_dirs_path = ($repo_dirs_path | default "repos")
  let url_scheme = ($url_scheme | default "path")

  let status = sync-local-overrides {
    repo_root: $repo_root
    source_path: $source_path
    output_path: $output_path
    polyrepo_root: $polyrepo_root
    repo_dirs_path: $repo_dirs_path
    url_scheme: $url_scheme
    include_repos: $parsed.include_repos
    exclude_repos: $parsed.exclude_repos
    include_inputs: $parsed.include_inputs
    exclude_inputs: $parsed.exclude_inputs
  }

  if $json {
    $status | to json --raw
  } else {
    null
  }
}

# Report whether `devenv.local.yaml` and `devenv.lock` are aligned.
#
# Use `--json` for structured output.
def "main lock-status" [
  output_path: string # Generated devenv.local.yaml path.
  lock_path: string   # devenv.lock path to compare against.
  --json (-j)         # Emit structured JSON status.
] {
  let status = lock-status $output_path $lock_path

  if $json {
    $status | to json --raw
  } else if ($status.input_name | describe) == 'string' {
    $"($status.status):($status.input_name)"
  } else {
    $status.status
  }
}
