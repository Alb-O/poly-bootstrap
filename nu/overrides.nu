use paths.nu [get-import-input-name repo-name-from-url]
use sources.nu [get-imports-list get-input-names get-inputs-block read-input-spec]
use support.nu [fail global-inputs-basename sort-record]

def override-url-prefix [url_scheme: string]: nothing -> oneof<string, error> {
  match $url_scheme {
    "git+file" => { "git+file:" }
    "path" => { "path:" }
    _ => { fail $"unsupported url scheme: ($url_scheme)" }
  }
}

def input-is-selected [input_name: string include_inputs: list<string> exclude_inputs: list<string>]: nothing -> bool {
  if (not ($include_inputs | is-empty)) and (not ($input_name in $include_inputs)) {
    return false
  }

  if $input_name in $exclude_inputs {
    return false
  }

  true
}

def add-override [overrides: record input_name: string copied_spec: record source_label: string]: nothing -> oneof<record, error> {
  let existing_spec = ($overrides | get -o $input_name)

  match ($existing_spec | describe) {
    "nothing" => { $overrides | merge { $input_name: $copied_spec } }
    _ => {
      if $existing_spec != $copied_spec {
        fail $"conflicting local override for input '($input_name)' while scanning ($source_label)"
      }

      $overrides
    }
  }
}

def collect-global-imports [global_imports: list<string> include_inputs: list<string> exclude_inputs: list<string> effective_input_names: list<string>]: nothing -> list<string> {
  $global_imports
  | where {|import_name|
      let import_input_name = (get-import-input-name $import_name | default $import_name)

      (input-is-selected $import_input_name $include_inputs $exclude_inputs) and ($import_input_name in $effective_input_names)
    }
  | uniq
}

export def build-overrides [
  source_yaml_text: string
  global_inputs_yaml_text: string
  local_repo_names: list<string>
  repo_sources: record
  include_inputs: list<string>
  exclude_inputs: list<string>
  repo_dirs_root: path
  url_scheme: string
]: nothing -> record {
  let url_prefix = override-url-prefix $url_scheme
  let root_input_names = get-input-names "root source" $source_yaml_text
  let has_global_inputs = ($global_inputs_yaml_text | str trim) != ""
  let global_inputs_label = $"global inputs '((global-inputs-basename))'"
  let global_imports = if not $has_global_inputs {
    []
  } else {
    get-imports-list $global_inputs_label $global_inputs_yaml_text
  }

  mut overrides = {}
  mut local_repo_names_used = []
  mut pending_sources = [
    {
      source_label: "root source"
      yaml_text: $source_yaml_text
      blocked_input_names: []
    }
  ]
  mut visited_repo_names = []

  if $has_global_inputs {
    $pending_sources = (
      $pending_sources
      | append {
          source_label: $global_inputs_label
          yaml_text: $global_inputs_yaml_text
          blocked_input_names: $root_input_names
        }
    )
  }

  # Walk root, global defaults, and any discovered local repos in FIFO order so
  # conflict checks remain deterministic.
  loop {
    if ($pending_sources | is-empty) {
      break
    }

    let current = ($pending_sources | first)
    $pending_sources = ($pending_sources | skip 1)

    let inputs_block = get-inputs-block $current.source_label $current.yaml_text

    for input_name in ($inputs_block | columns) {
      if $input_name in $current.blocked_input_names {
        continue
      }

      if not (input-is-selected $input_name $include_inputs $exclude_inputs) {
        continue
      }

      let input_spec = match (read-input-spec ($inputs_block | get $input_name)) {
        null => { continue }
        $input_spec => { $input_spec }
      }

      let repo_name = match (repo-name-from-url $input_spec.url) {
        null => { continue }
        $repo_name => {
          if not ($repo_name in $local_repo_names) {
            continue
          }

          $repo_name
        }
      }

      let local_repo_path = ($repo_dirs_root | path join $repo_name)
      let copied_spec = ($input_spec.spec | merge { url: $"($url_prefix)($local_repo_path)" })
      $overrides = add-override $overrides $input_name $copied_spec $current.source_label
      $local_repo_names_used = ($local_repo_names_used | append $repo_name)

      if $repo_name in $visited_repo_names {
        continue
      }

      let nested_source = ($repo_sources | get -o $repo_name)

      if ($nested_source | describe) == 'string' {
        $visited_repo_names = ($visited_repo_names | append $repo_name)
        $pending_sources = (
          $pending_sources
          | append {
              source_label: $"local repo '($repo_name)'"
              yaml_text: $nested_source
              blocked_input_names: []
            }
        )
      }
    }
  }

  let effective_input_names = (($root_input_names | append ($overrides | columns)) | uniq)

  {
    overrides: $overrides
    imports: (collect-global-imports $global_imports $include_inputs $exclude_inputs $effective_input_names)
    local_repo_names: ($local_repo_names_used | uniq | sort)
  }
}

export def render-overrides-text [overrides: record imports_list: list<string>]: nothing -> string {
  if (($overrides | columns | is-empty) and ($imports_list | is-empty)) {
    return ""
  }

  mut rendered = {}

  if not ($overrides | columns | is-empty) {
    $rendered = ($rendered | merge { inputs: (sort-record $overrides) })
  }

  if not ($imports_list | is-empty) {
    $rendered = ($rendered | merge { imports: $imports_list })
  }

  $rendered | to yaml
}
