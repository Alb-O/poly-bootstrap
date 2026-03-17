#!/usr/bin/env nu

use ../nu/cli.nu [parse-repeatable-sync-flags]
use ../nu/commands.nu [bootstrap]

def main [
  repo_root?: string            # Consumer repo root. Defaults to `.`.
  --source-path (-s): string    # Source YAML path inside the consumer repo.
  --output-path (-o): string    # Generated override YAML path inside the consumer repo.
  --polyrepo-root (-p): string  # Explicit polyrepo root when inference is not possible.
  --repo-dirs-path (-r): string # Path to the sibling repo directory.
  --url-scheme (-u): string     # Override URL scheme: path or git+file.
  --json (-j)                   # Emit structured JSON status instead of silence.
  ...rest: string               # Repeatable include/exclude filters.
] {
  if ('--help' in $rest) or ('-h' in $rest) or ($repo_root == '--help') or ($repo_root == '-h') {
    return (help main)
  }

  let parsed = parse-repeatable-sync-flags $rest
  let repo_root = ($repo_root | default ".")
  let source_path = ($source_path | default "devenv.yaml")
  let output_path = ($output_path | default "devenv.local.yaml")
  let repo_dirs_path = ($repo_dirs_path | default "repos")
  let url_scheme = ($url_scheme | default "path")

  let status = bootstrap {
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
