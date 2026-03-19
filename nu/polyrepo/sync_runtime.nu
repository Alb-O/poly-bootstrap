use ../support.nu [fail is-record is-string sort-record]
use manifest.nu [get-import-input-name parse-yaml-mapping]
use resolve.nu [resolve-target resolve-target-layer-spec]

def selected-imports [imports_list: list<string> effective_input_names: list<string>]: nothing -> list<string> {
  $imports_list
  | where {|import_name|
      let import_input_name = (get-import-input-name $import_name | default $import_name)
      $import_input_name in $effective_input_names
    }
  | uniq
}

def render-target-overrides [
  target: record<polyrepo_root: path, model: record, target_root: path, target_kind: string, target_name: oneof<string, nothing>>
]: nothing -> record<overrides: record, imports: list<string>, local_repo_names: list<string>> {
  let target_spec = resolve-target-layer-spec $target
  let repo_paths = (
    $target.model.repos
    | items {|repo_name, repo_entry| [$repo_name ($repo_entry.path | into string)] }
    | into record
  )

  mut overrides = {}
  mut local_repo_names = []
  mut pending_inputs = ($target_spec.inputs | uniq)
  mut visited_inputs = []
  mut collected_input_imports = []

  loop {
    if ($pending_inputs | is-empty) {
      break
    }

    let input_name = ($pending_inputs | first)
    $pending_inputs = ($pending_inputs | skip 1)

    if $input_name in $visited_inputs {
      continue
    }

    $visited_inputs = ($visited_inputs | append $input_name)
    let input_entry = ($target.model.inputs | get -o $input_name)
    if not (is-record $input_entry) {
      fail $"unknown input '($input_name)'"
    }

    let local_repo = $input_entry.localRepo
    if not (is-string $local_repo) {
      continue
    }

    let repo_path = ($repo_paths | get -o $local_repo)
    if not (is-string $repo_path) {
      fail $"input '($input_name)' maps to unknown local repo '($local_repo)'"
    }

    $local_repo_names = ($local_repo_names | append $local_repo)
    $overrides = ($overrides | merge {
      $input_name: ($input_entry.spec | merge { url: $"path:($repo_path)" })
    })
    $collected_input_imports = ($collected_input_imports | append $input_entry.imports)
    $pending_inputs = ($pending_inputs | append $input_entry.requiresInputs)
  }

  let effective_input_names = ($overrides | columns | uniq)
  let rendered_imports = (($target_spec.imports | append $collected_input_imports) | flatten | uniq)

  {
    overrides: $overrides
    imports: (selected-imports $rendered_imports $effective_input_names)
    local_repo_names: ($local_repo_names | uniq | sort)
  }
}

def render-overrides-text [
  rendered: record<overrides: record, imports: list<string>, local_repo_names: list<string>>
]: nothing -> string {
  if (($rendered.overrides | columns | is-empty) and ($rendered.imports | is-empty)) {
    return ""
  }

  mut output = {}
  if not (($rendered.overrides | columns) | is-empty) {
    $output = ($output | merge { inputs: (sort-record $rendered.overrides) })
  }

  if not ($rendered.imports | is-empty) {
    $output = ($output | merge { imports: $rendered.imports })
  }

  $output | to yaml
}

def make-lock-status [
  status: string
  input_name?: string
]: nothing -> record<status: string, clean: bool, input_name: oneof<string, nothing>> {
  {
    status: $status
    clean: ($status == "clean")
    input_name: $input_name
  }
}

def lock-status [
  output_path: path
  lock_path: path
]: nothing -> record<status: string, clean: bool, input_name: oneof<string, nothing>> {
  if not ($output_path | path exists) {
    return (make-lock-status "clean")
  }

  let local_doc = parse-yaml-mapping $output_path (open --raw $output_path)
  let desired_inputs = ($local_doc.inputs? | default {})

  if not (is-record $desired_inputs) {
    fail $"expected `inputs` to be a mapping in ($output_path)"
  }

  if (($desired_inputs | columns) | is-empty) {
    return (make-lock-status "clean")
  }

  if not ($lock_path | path exists) {
    return (make-lock-status "missing-lock")
  }

  let lock_doc = try {
    open --raw $lock_path | from json
  } catch {
    fail $"expected valid JSON in ($lock_path)"
  }
  let root_name = $lock_doc.root?
  let nodes = ($lock_doc.nodes? | default {})
  let root_node = if (is-string $root_name) and ($root_name in ($nodes | columns)) {
    $nodes | get $root_name
  }
  let root_inputs = ($root_node.inputs? | default {})

  for input_name in ($desired_inputs | columns | sort) {
    if not ($input_name in ($root_inputs | columns)) {
      return (make-lock-status "missing-root-input" $input_name)
    }

    let input_spec = ($desired_inputs | get $input_name)
    let url = $input_spec.url?
    let locked_name = ($root_inputs | get $input_name)
    let locked_node = if (is-string $locked_name) and ($locked_name in ($nodes | columns)) {
      $nodes | get $locked_name
    }
    let locked_original = $locked_node.original?

    if (is-string $url) and (is-string $locked_original) and ($locked_original != $url) {
      return (make-lock-status "stale-root-input" $input_name)
    }
  }

  make-lock-status "clean"
}

def sync-target [
  target: record<polyrepo_root: path, model: record, target_root: path, target_kind: string, target_name: oneof<string, nothing>>
]: nothing -> record<target_root: path, target_kind: string, target_name: oneof<string, nothing>, output_path: path, mode: string, changed: bool, removed: bool, local_repo_names: list<string>, local_repo_roots: list<string>, local_repo_count: int, lock_status: record<status: string, clean: bool, input_name: oneof<string, nothing>>, lock_refresh_needed: bool> {
  let output_path = ($target.target_root | path join "devenv.local.yaml")
  let lock_path = ($target.target_root | path join "devenv.lock")
  let rendered = render-target-overrides $target
  let overrides_text = render-overrides-text $rendered

  let existing_text = if ($output_path | path exists) {
    open --raw $output_path
  }
  mut mode = "unchanged"

  if $overrides_text == "" {
    if (is-string $existing_text) {
      rm --force $output_path
      $mode = "removed"
    }
  } else if $existing_text != $overrides_text {
    if ($output_path | path exists) {
      rm --force $output_path
    }
    $overrides_text | save --force $output_path
    $mode = "written"
  }

  let repo_paths = (
    $target.model.repos
    | items {|repo_name, repo_entry| [$repo_name ($repo_entry.path | into string)] }
    | into record
  )
  let local_repo_roots = (
    $rendered.local_repo_names
    | each {|repo_name| $repo_paths | get $repo_name }
  )
  let lock_status_value = lock-status $output_path $lock_path

  {
    target_root: $target.target_root
    target_kind: $target.target_kind
    target_name: $target.target_name
    output_path: $output_path
    mode: $mode
    changed: ($mode != "unchanged")
    removed: ($mode == "removed")
    local_repo_names: $rendered.local_repo_names
    local_repo_roots: $local_repo_roots
    local_repo_count: ($rendered.local_repo_names | length)
    lock_status: $lock_status_value
    lock_refresh_needed: (not $lock_status_value.clean)
  }
}

export def sync [target_path?: path]: nothing -> record<target_root: path, target_kind: string, target_name: oneof<string, nothing>, output_path: path, mode: string, changed: bool, removed: bool, local_repo_names: list<string>, local_repo_roots: list<string>, local_repo_count: int, lock_status: record<status: string, clean: bool, input_name: oneof<string, nothing>>, lock_refresh_needed: bool> {
  sync-target (resolve-target ($target_path | default "."))
}
