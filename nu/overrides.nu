use paths.nu [get-import-input-name repo-name-from-url]
use sources.nu [polyrepo-model-from-polyrepo-manifest]
use support.nu [fail sort-record]

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

def collect-selected-imports [imports_list: list<string> include_inputs: list<string> exclude_inputs: list<string> effective_input_names: list<string>]: nothing -> list<string> {
  $imports_list
  | where {|import_name|
      let import_input_name = (get-import-input-name $import_name | default $import_name)

      (input-is-selected $import_input_name $include_inputs $exclude_inputs) and ($import_input_name in $effective_input_names)
    }
  | uniq
}

def merge-managed-spec [first: record second: record]: nothing -> record {
  {
    inputs: (($first.inputs | append $second.inputs) | uniq)
    imports: (($first.imports | append $second.imports) | uniq)
  }
}

def resolve-overlay [overlay_kind: string overlay_name: string catalog: record stack: list<string>]: nothing -> oneof<record, error> {
  if $overlay_name in $stack {
    fail $"cyclic ($overlay_kind) overlay chain: (($stack | append $overlay_name) | str join ' -> ')"
  }

  let overlay = ($catalog | get -o $overlay_name)
  if (($overlay | describe) !~ '^record') {
    fail $"unknown ($overlay_kind) overlay '($overlay_name)'"
  }

  mut resolved = {
    inputs: []
    imports: []
  }

  for parent_name in ($overlay | get extends) {
    $resolved = merge-managed-spec $resolved (resolve-overlay $overlay_kind $parent_name $catalog ($stack | append $overlay_name))
  }

  merge-managed-spec $resolved {
    inputs: ($overlay | get inputs)
    imports: ($overlay | get imports)
  }
}

def find-repo-entry [repo_name: string repo_entries: record]: nothing -> oneof<record, error> {
  let repo_entry = ($repo_entries | get -o $repo_name)

  if (($repo_entry | describe) !~ '^record') {
    fail $"unknown repo '($repo_name)' in polyrepo manifest"
  }

  $repo_entry
}

def resolve-repo-managed-spec [repo_name: string model: record]: nothing -> oneof<record, error> {
  mut resolved = {
    inputs: []
    imports: []
  }

  # Child repos inherit repo defaults; the polyrepo root uses `rootProfiles`
  # instead so the top-level shell can stay intentionally smaller/different.
  for profile_name in $model.repoDefaultProfiles {
    $resolved = merge-managed-spec $resolved (resolve-overlay "profile" $profile_name $model.profiles [])
  }

  let repo_entry = find-repo-entry $repo_name $model.repos
  let bundle_name = ($repo_entry | get bundle)
  if (($bundle_name | describe) == 'string') {
    $resolved = merge-managed-spec $resolved (resolve-overlay "bundle" $bundle_name $model.bundles [])
  }

  for profile_name in ($repo_entry | get profiles) {
    $resolved = merge-managed-spec $resolved (resolve-overlay "profile" $profile_name $model.profiles [])
  }

  merge-managed-spec $resolved {
    inputs: ($repo_entry | get inputs)
    imports: ($repo_entry | get imports)
  }
}

def resolve-root-managed-spec [model: record]: nothing -> oneof<record, error> {
  mut resolved = {
    inputs: []
    imports: []
  }

  for profile_name in $model.rootProfiles {
    $resolved = merge-managed-spec $resolved (resolve-overlay "profile" $profile_name $model.profiles [])
  }

  $resolved
}

def infer-local-repo-name [input_name: string input_entry: record]: nothing -> oneof<string, nothing> {
  let explicit_local_repo = ($input_entry | get localRepo)

  if (($explicit_local_repo | describe) == 'string') {
    return $explicit_local_repo
  }

  let url = (($input_entry | get spec) | get -o url)
  if (($url | describe) == 'string') {
    return (repo-name-from-url $url)
  }

  $input_name
}

export def build-overrides [
  polyrepo_manifest_text: string
  current_repo_name: any
  local_repo_paths: record
  include_inputs: list<string>
  exclude_inputs: list<string>
  url_scheme: string
]: nothing -> record {
  let model = polyrepo-model-from-polyrepo-manifest "polyrepo manifest" $polyrepo_manifest_text
  let url_prefix = override-url-prefix $url_scheme
  let root_spec = if (($current_repo_name | describe) == 'string') {
    resolve-repo-managed-spec $current_repo_name $model
  } else {
    resolve-root-managed-spec $model
  }
  let input_catalog = $model.inputs

  mut overrides = {}
  mut local_repo_names_used = []
  mut pending_input_names = ($root_spec.inputs | uniq)
  mut visited_input_names = []
  mut collected_input_imports = []

  loop {
    if ($pending_input_names | is-empty) {
      break
    }

    let input_name = ($pending_input_names | first)
    $pending_input_names = ($pending_input_names | skip 1)

    if $input_name in $visited_input_names {
      continue
    }

    $visited_input_names = ($visited_input_names | append $input_name)

    if not (input-is-selected $input_name $include_inputs $exclude_inputs) {
      continue
    }

    let input_entry = ($input_catalog | get -o $input_name)
    if (($input_entry | describe) !~ '^record') {
      fail $"unknown managed input '($input_name)' in polyrepo manifest"
    }

    let local_repo_name = infer-local-repo-name $input_name $input_entry
    if (($local_repo_name | describe) == 'string') and (not ($local_repo_name in ($local_repo_paths | columns))) {
      continue
    }

    let copied_spec = if (($local_repo_name | describe) == 'string') {
      let local_repo_name = ($local_repo_name | into string)
      let local_repo_path = ($local_repo_paths | get $local_repo_name)
      $local_repo_names_used = ($local_repo_names_used | append $local_repo_name)
      (($input_entry | get spec) | merge { url: $"($url_prefix)($local_repo_path)" })
    } else {
      $input_entry | get spec
    }

    $overrides = add-override $overrides $input_name $copied_spec $"managed input '($input_name)'"
    $collected_input_imports = ($collected_input_imports | append ($input_entry | get imports))
    # Follow only explicit input-level closure. We intentionally do not re-enter
    # the referenced repo's bundle/profile assignment here, because that made
    # override generation depend on hidden repo-to-repo policy edges.
    $pending_input_names = ($pending_input_names | append ($input_entry | get requiresInputs))
  }

  let effective_input_names = ($overrides | columns | uniq)
  let rendered_imports = (($root_spec.imports | append $collected_input_imports) | flatten | uniq)

  {
    overrides: $overrides
    imports: (collect-selected-imports $rendered_imports $include_inputs $exclude_inputs $effective_input_names)
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
