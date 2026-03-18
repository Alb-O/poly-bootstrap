#!/usr/bin/env nu

use ../nu/cli.nu [build-sync-spec render-json-status sync-help-requested]
use ../nu/commands.nu [bootstrap bootstrap-all]

def main [
  repo_root?: path              # Consumer repo root. Defaults to `.`.
  --source-path (-s): path      # Source YAML path inside the consumer repo.
  --output-path (-o): path      # Generated override YAML path inside the consumer repo.
  --polyrepo-root (-p): path    # Explicit polyrepo root when inference is not possible.
  --repo-dirs-path (-r): path   # Path to the sibling repo directory. Defaults to repoDirsPath from polyrepo.nuon.
  --url-scheme (-u): string     # Override URL scheme: path or git+file.
  --all-repos (-a)              # Bootstrap every discovered repo root under `repo-dirs-path`.
  --json (-j)                   # Emit structured JSON status instead of silence.
  ...rest: string               # Repeatable include/exclude filters.
] {
  if (sync-help-requested $repo_root $rest) {
    return (help main)
  }

  let spec = build-sync-spec $repo_root $source_path $output_path $polyrepo_root $repo_dirs_path $url_scheme $rest
  let status = if $all_repos {
    try {
      bootstrap-all $spec
    } catch {|err|
      # Preserve machine-readable partial results even when the aggregate run
      # fails, then rethrow so the process still exits nonzero.
      let failure_status = ($err.summary? | default ($err.results? | default { error: $err.msg }))
      render-json-status $failure_status true
      error make $err
    }
  } else {
    bootstrap $spec
  }

  render-json-status $status $json
}
