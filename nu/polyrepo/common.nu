use ../support.nu [fail]

export def latest-shell-export [repo_root: path]: nothing -> oneof<path, nothing> {
  let shell_glob = (($repo_root | path join ".devenv") | path join "shell-*.sh")
  let shell_exports = (
    glob $shell_glob
    | each {|path|
        let entry = (ls $path | first)
        {
          path: $path
          modified: $entry.modified
        }
      }
    | sort-by modified
  )

  if ($shell_exports | is-empty) {
    return null
  }

  $shell_exports | last | get path
}

export def shell-export-meta-path [repo_root: path]: nothing -> path {
  ($repo_root | path join ".devenv" | path join "polyrepo-shell-export.meta")
}

export def shell-export-file-stat-line [label: string path_value: path]: nothing -> string {
  if not ($path_value | path exists) {
    return $"($label)\t0\t-\t-"
  }

  let entry = (ls $path_value | first)
  let modified = ($entry.modified | format date "%s")
  $"($label)\t1\t($entry.size)\t($modified)"
}

export def shell-export-local-input-repos [repo_root: path]: nothing -> list<record> {
  let local_yaml_path = ($repo_root | path join "devenv.local.yaml")
  if not ($local_yaml_path | path exists) {
    return []
  }

  let local_doc = try {
    open --raw $local_yaml_path | from yaml | default {}
  } catch {
    fail $"expected `inputs` to be a mapping in ($local_yaml_path)"
  }
  let local_inputs = ($local_doc | get -o inputs | default {})

  if (($local_inputs | describe) !~ '^record') {
    fail $"expected `inputs` to be a mapping in ($local_yaml_path)"
  }

  $local_inputs
  | items {|input_name, input_spec|
      let url = ($input_spec | get -o url)
      if (($url | describe) == 'string') and ($url | str starts-with "path:") {
        {
          name: $input_name
          repo_root: ($url | str substring 5..)
        }
      }
    }
  | where {|entry| (($entry | describe) =~ '^record') }
  | sort-by name
}

export def shell-export-fingerprint [repo_root: path]: nothing -> string {
  mut lines = [
    "version\t1"
    $"repo_root\t($repo_root)"
  ]

  for rel_path in [ "devenv.nix" "devenv.yaml" "devenv.local.yaml" "devenv.lock" ] {
    $lines = ($lines | append (shell-export-file-stat-line $"target:($rel_path)" ($repo_root | path join $rel_path)))
  }

  for input_entry in (shell-export-local-input-repos $repo_root) {
    $lines = ($lines | append $"input\t($input_entry.name)\t($input_entry.repo_root)")

    for rel_path in [ "devenv.nix" "devenv.yaml" "devenv.lock" ] {
      $lines = ($lines | append (shell-export-file-stat-line $"input:($input_entry.name):($rel_path)" ($input_entry.repo_root | path join $rel_path)))
    }

    if $input_entry.name == "poly-bootstrap" {
      for rel_path in [
        "bin/devenv-run.nu"
        "bin/polyrepo.nu"
        "nu/support.nu"
        "nu/polyrepo/bootstrap_runtime.nu"
        "nu/polyrepo/check_runtime.nu"
        "nu/polyrepo/common.nu"
        "nu/polyrepo/devenv_run.nu"
        "nu/polyrepo/manifest.nu"
        "nu/polyrepo/mod.nu"
        "nu/polyrepo/resolve.nu"
        "nu/polyrepo/sync_runtime.nu"
        "tooling/default.nix"
        "tooling/devenv.nix"
      ] {
        $lines = ($lines | append (shell-export-file-stat-line $"input:($input_entry.name):($rel_path)" ($input_entry.repo_root | path join $rel_path)))
      }
    }
  }

  $lines | str join "\n" | hash sha256
}

export def read-shell-export-meta [repo_root: path]: nothing -> record {
  let meta_path = shell-export-meta-path $repo_root
  if not ($meta_path | path exists) {
    return {
      ok: false
      reason: "missing_meta"
    }
  }

  let meta = try {
    (
      open --raw $meta_path
      | lines
      | where {|line| not ($line | str trim | is-empty) }
      | each {|line|
          let parsed = ($line | parse -r '^(?<key>[A-Z0-9_]+)=(?<value>.*)$')
          if ($parsed | is-empty) {
            fail $"expected KEY=VALUE metadata in ($meta_path)"
          }
          let entry = ($parsed | first)
          [$entry.key $entry.value]
        }
      | into record
    )
  } catch {
    return {
      ok: false
      reason: "meta_parse_error"
    }
  }

  if (($meta | get -o POLYREPO_SHELL_EXPORT_VERSION) != "1") {
    return {
      ok: false
      reason: "meta_parse_error"
    }
  }

  let export_path = ($meta | get -o POLYREPO_SHELL_EXPORT_PATH)
  let fingerprint = ($meta | get -o POLYREPO_SHELL_EXPORT_FINGERPRINT)
  if (($export_path | describe) != 'string') or (($fingerprint | describe) != 'string') or ($export_path | is-empty) or ($fingerprint | is-empty) {
    return {
      ok: false
      reason: "meta_parse_error"
    }
  }

  {
    ok: true
    export_path: $export_path
    fingerprint: $fingerprint
    created_at: ($meta | get -o POLYREPO_SHELL_EXPORT_CREATED_AT | default null)
  }
}

export def write-shell-export-meta [repo_root: path shell_export_path: path fingerprint: string]: nothing -> nothing {
  let meta_path = shell-export-meta-path $repo_root
  let meta_text = [
    "POLYREPO_SHELL_EXPORT_VERSION=1"
    $"POLYREPO_SHELL_EXPORT_PATH=($shell_export_path)"
    $"POLYREPO_SHELL_EXPORT_FINGERPRINT=($fingerprint)"
    $"POLYREPO_SHELL_EXPORT_CREATED_AT=((date now) | format date '%Y-%m-%dT%H:%M:%S%:z')"
  ] | str join "\n"

  $meta_text | save --force $meta_path
}

export def materialize-shell-export [repo_root: path]: nothing -> nothing {
  do {
    cd $repo_root
    ^devenv shell --no-tui --no-eval-cache --refresh-eval-cache -- bash -lc "true" | ignore
  }
}

export def ensure-shell-export [repo_root: path refresh_requested: bool]: nothing -> record {
  let existing_export = (latest-shell-export $repo_root)
  let refresh_reason = if $refresh_requested {
    "forced_refresh"
  } else if (($existing_export | describe) != 'string') {
    "missing_export"
  } else {
    let meta_status = read-shell-export-meta $repo_root
    if not $meta_status.ok {
      $meta_status.reason
    } else {
      let current_fingerprint = shell-export-fingerprint $repo_root
      if ($meta_status.export_path != $existing_export) or ($meta_status.fingerprint != $current_fingerprint) {
        "stale_fingerprint"
      } else {
        "reused"
      }
    }
  }

  if $refresh_reason == "reused" {
    return {
      shell_export_path: $existing_export
      shell_export_refreshed: false
      shell_export_reason: $refresh_reason
    }
  }

  materialize-shell-export $repo_root
  let refreshed_export = (latest-shell-export $repo_root)

  if (($refreshed_export | describe) != 'string') {
    fail $"expected devenv shell export under (($repo_root | path join '.devenv'))"
  }

  let current_fingerprint = shell-export-fingerprint $repo_root
  write-shell-export-meta $repo_root $refreshed_export $current_fingerprint

  {
    shell_export_path: $refreshed_export
    shell_export_refreshed: true
    shell_export_reason: $refresh_reason
  }
}

export def shell-export-prefix-text [shell_script: path]: nothing -> string {
  (
    open --raw $shell_script
    | lines
    | take while {|line| not ($line =~ '^eval($| )') and not ($line =~ '\$\{shellHook:-\}') }
    | str join "\n"
  )
}

export def run-in-shell-export [
  shell_script: path
  --shell-command(-s): string
  ...command: string
]: nothing -> nothing {
  let prefix_text = shell-export-prefix-text $shell_script
  let script_text = if (($shell_command | describe) == 'string') {
    [
      "#!/usr/bin/env bash"
      "set -euo pipefail"
      'export PS1=""'
      $prefix_text
      'exec bash -lc "$POLYREPO_SHELL_COMMAND"'
    ] | str join "\n"
  } else {
    [
      "#!/usr/bin/env bash"
      "set -euo pipefail"
      'export PS1=""'
      $prefix_text
      'exec "$@"'
    ] | str join "\n"
  }

  if (($shell_command | describe) == 'string') {
    with-env { POLYREPO_SHELL_COMMAND: $shell_command } {
      $script_text | ^bash -s
    }
  } else {
    $script_text | ^bash -s -- ...$command
  }
}
