use support.nu [fail]

def empty-sync-filters []: nothing -> record {
  {
    include_repos: []
    exclude_repos: []
    include_inputs: []
    exclude_inputs: []
  }
}

def append-sync-filter [filters: record flag: string value: string]: nothing -> oneof<record, error> {
  match $flag {
    "--include-repo" | "-i" => {
      $filters | upsert include_repos ($filters.include_repos | append $value)
    }
    "--exclude-repo" | "-x" => {
      $filters | upsert exclude_repos ($filters.exclude_repos | append $value)
    }
    "--include-input" | "-I" => {
      $filters | upsert include_inputs ($filters.include_inputs | append $value)
    }
    "--exclude-input" | "-X" => {
      $filters | upsert exclude_inputs ($filters.exclude_inputs | append $value)
    }
    _ => {
      fail $"unknown sync flag: ($flag)"
    }
  }
}

export def parse-repeatable-sync-flags [args: list<string>]: nothing -> oneof<record, error> {
  let state = (
    $args
    | reduce -f ({ pending_flag: null } | merge (empty-sync-filters)) {|arg, state|
        let pending_flag = ($state | get pending_flag)

        if ($pending_flag | describe) == 'string' {
          append-sync-filter ($state | update pending_flag { null }) $pending_flag $arg
        } else {
          match $arg {
            "--include-repo" | "-i" | "--exclude-repo" | "-x" | "--include-input" | "-I" | "--exclude-input" | "-X" => {
              $state | update pending_flag { $arg }
            }
            _ => {
              fail $"unknown sync flag: ($arg)"
            }
          }
        }
      }
  )

  let pending_flag = ($state | get pending_flag)
  if ($pending_flag | describe) == 'string' {
    fail $"($pending_flag) requires a value"
  }

  {
    include_repos: (($state | get include_repos) | uniq)
    exclude_repos: (($state | get exclude_repos) | uniq)
    include_inputs: (($state | get include_inputs) | uniq)
    exclude_inputs: (($state | get exclude_inputs) | uniq)
  }
}

export def sync-help-requested [repo_root: any rest: list<string>]: nothing -> bool {
  ("--help" in $rest) or ("-h" in $rest) or (
    (($repo_root | describe) == 'string') and ($repo_root in [ "--help" "-h" ])
  )
}

export def build-sync-spec [
  repo_root: any
  source_path: any
  output_path: any
  polyrepo_root: any
  repo_dirs_path: any
  url_scheme: any
  rest: list<string>
]: nothing -> record {
  let filters = parse-repeatable-sync-flags $rest

  {
    repo_root: ($repo_root | default ".")
    source_path: ($source_path | default "devenv.yaml")
    output_path: ($output_path | default "devenv.local.yaml")
    polyrepo_root: $polyrepo_root
    repo_dirs_path: ($repo_dirs_path | default "repos")
    url_scheme: ($url_scheme | default "path")
  }
  | merge $filters
}

export def render-json-status [status: any emit_json: bool]: nothing -> oneof<string, nothing> {
  if $emit_json {
    $status | to json --raw
  }
}
