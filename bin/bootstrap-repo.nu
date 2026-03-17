#!/usr/bin/env nu

use ../nu/cli.nu [build-sync-spec render-json-status sync-help-requested]
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
  if (sync-help-requested $repo_root $rest) {
    return (help main)
  }

  let spec = build-sync-spec $repo_root $source_path $output_path $polyrepo_root $repo_dirs_path $url_scheme $rest
  render-json-status (bootstrap $spec) $json
}
