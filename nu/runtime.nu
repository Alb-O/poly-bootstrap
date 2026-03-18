use support.nu [fail sort-record polyrepo-manifest-basename]

def normalize-structured-value [value: any]: nothing -> any {
  match ($value | describe) {
    $t if $t =~ '^record' => {
      $value
      | items {|key, item| [$key (normalize-structured-value $item)] }
      | into record
    }
    $t if $t =~ '^list' => {
      $value | each {|item| normalize-structured-value $item }
    }
    _ => {
      $value
    }
  }
}

def parse-nuon-mapping [source_label: string nuon_text: string]: nothing -> record {
  let parsed = if ($nuon_text | str trim) == "" {
    {}
  } else {
    try {
      $nuon_text | from nuon | default {}
    } catch {
      fail $"expected a top-level mapping in ($source_label)"
    }
  }

  if (($parsed | describe) !~ '^record') {
    fail $"expected a top-level mapping in ($source_label)"
  }

  normalize-structured-value $parsed
}

def parse-yaml-mapping [source_label: string yaml_text: string]: nothing -> record {
  let parsed = if ($yaml_text | str trim) == "" {
    {}
  } else {
    try {
      $yaml_text | from yaml | default {}
    } catch {
      fail $"expected a top-level mapping in ($source_label)"
    }
  }

  if (($parsed | describe) !~ '^record') {
    fail $"expected a top-level mapping in ($source_label)"
  }

  normalize-structured-value $parsed
}

def require-string [value: any field_label: string]: nothing -> string {
  if (($value | describe) != 'string') or ($value | is-empty) {
    fail $"expected ($field_label) to be a non-empty string"
  }

  $value
}

def optional-string [value: any field_label: string]: nothing -> oneof<string, nothing> {
  if (($value | describe) == 'nothing') {
    return null
  }

  require-string $value $field_label
}

def expect-string-list [value: any field_label: string]: nothing -> list<string> {
  if (($value | describe) == 'nothing') {
    return []
  }

  if (($value | describe) !~ '^list') {
    fail $"expected ($field_label) to be a list"
  }

  $value
  | each {|item| require-string $item $"entries in ($field_label)" }
  | uniq
}

def expect-string-record [value: any field_label: string]: nothing -> record {
  if (($value | describe) !~ '^record') {
    fail $"expected ($field_label) to be a mapping"
  }

  $value
  | items {|key, item|
      [
        (require-string $key $"keys in ($field_label)")
        (require-string $item $"values in ($field_label)")
      ]
    }
  | into record
}

def resolve-repo-path [base_path: path candidate_path: path]: nothing -> path {
  if ($candidate_path | str starts-with "/") {
    $candidate_path | path expand --no-symlink
  } else {
    ($base_path | path join $candidate_path) | path expand --no-symlink
  }
}

def maybe-relativize [target_path: path root_path: path]: nothing -> oneof<path, nothing> {
  let root_path = ($root_path | path expand --no-symlink)
  let target_path = ($target_path | path expand --no-symlink)
  let root_prefix = $"($root_path)/"

  if $target_path == $root_path {
    "."
  } else if ($target_path | str starts-with $root_prefix) {
    $target_path | str substring ($root_prefix | str length)..
  }
}

def is-repo-root [path_value: path]: nothing -> bool {
  (
    (($path_value | path join ".git") | path exists)
    or (($path_value | path join "devenv.yaml") | path exists)
    or (($path_value | path join "devenv.nix") | path exists)
  )
}

def is-bootstrap-target [path_value: path]: nothing -> bool {
  (
    (($path_value | path join "devenv.yaml") | path exists)
    or (($path_value | path join "devenv.nix") | path exists)
  )
}

def find-repo-root [start_path: path]: nothing -> oneof<path, nothing> {
  mut current = ($start_path | path expand --no-symlink)

  while true {
    if (is-repo-root $current) {
      return $current
    }

    let parent = ($current | path dirname)
    if $parent == $current {
      return null
    }

    $current = $parent
  }
}

def manifest-path [polyrepo_root: path]: nothing -> path {
  ($polyrepo_root | path join (polyrepo-manifest-basename))
}

def get-import-input-name [import_name: string]: nothing -> oneof<string, nothing> {
  if ([ "path:" "/" "./" "../" ] | any {|prefix| $import_name | str starts-with $prefix }) {
    return null
  }

  $import_name | split row "/" | first | into string
}

def path-from-url [url: string]: nothing -> oneof<path, nothing> {
  if ($url | str starts-with "path:") {
    $url | str substring 5..
  }
}

def normalize-input-entry [input_name: string input_value: any manifest_label: string]: nothing -> record {
  let source_label = $"inputs.($input_name) in ($manifest_label)"

  if (($input_value | describe) !~ '^record') {
    fail $"expected ($source_label) to be a mapping"
  }

  let spec = ($input_value | reject --optional imports requiresInputs localRepo)
  let url = ($spec | get -o url)
  if (($url | describe) != 'string') or ($url | is-empty) {
    fail $"expected ($source_label) to define a non-empty url"
  }

  {
    spec: $spec
    imports: (expect-string-list ($input_value | get -o imports) $"imports in ($source_label)")
    requiresInputs: (expect-string-list ($input_value | get -o requiresInputs) $"requiresInputs in ($source_label)")
    localRepo: (optional-string ($input_value | get -o localRepo) $"localRepo in ($source_label)")
  }
}

def normalize-layer-entry [layer_name: string layer_value: any manifest_label: string]: nothing -> record {
  let source_label = $"layers.($layer_name) in ($manifest_label)"

  if (($layer_value | describe) !~ '^record') {
    fail $"expected ($source_label) to be a mapping"
  }

  {
    extends: (expect-string-list ($layer_value | get -o extends) $"extends in ($source_label)")
    inputs: (expect-string-list ($layer_value | get -o inputs) $"inputs in ($source_label)")
    imports: (expect-string-list ($layer_value | get -o imports) $"imports in ($source_label)")
  }
}

def normalize-repo-config [entry_label: string entry_value: any]: nothing -> record {
  if (($entry_value | describe) !~ '^record') {
    fail $"expected ($entry_label) to be a mapping"
  }

  let bootstrap_tasks = (expect-string-list ($entry_value | get -o bootstrapTasks) $"bootstrapTasks in ($entry_label)")
  let invalid_bootstrap_tasks = ($bootstrap_tasks | where {|task| $task != "devenv:files" })
  if not ($invalid_bootstrap_tasks | is-empty) {
    fail $"unsupported bootstrapTasks in ($entry_label): ($invalid_bootstrap_tasks | str join ', ')"
  }

  {
    layers: (expect-string-list ($entry_value | get -o layers) $"layers in ($entry_label)")
    bootstrapDeps: (expect-string-list ($entry_value | get -o bootstrapDeps) $"bootstrapDeps in ($entry_label)")
    bootstrapTasks: $bootstrap_tasks
  }
}

def normalize-repo-entry [repo_name: string repo_value: any manifest_label: string]: nothing -> record {
  let source_label = $"repos.($repo_name) in ($manifest_label)"
  let normalized = normalize-repo-config $source_label $repo_value
  let repo_path = require-string ($repo_value | get -o path) $"path in ($source_label)"

  $normalized | merge { path: $repo_path }
}

def normalize-repo-group-entry [group_name: string group_value: any manifest_label: string]: nothing -> record {
  let source_label = $"repoGroups.($group_name) in ($manifest_label)"
  let normalized = normalize-repo-config $source_label $group_value
  let members = expect-string-record ($group_value | get -o members) $"members in ($source_label)"

  $normalized | merge { members: $members }
}

def merge-layer-spec [first: record second: record]: nothing -> record {
  {
    inputs: (($first.inputs | append $second.inputs) | uniq)
    imports: (($first.imports | append $second.imports) | uniq)
  }
}

def append-error [errors: list<record> path: string message: string]: nothing -> list<record> {
  $errors | append { path: $path, message: $message }
}

def describe-repo-list [repo_names: list<string>]: nothing -> string {
  if ($repo_names | is-empty) {
    "none"
  } else {
    $repo_names | sort | str join ", "
  }
}

def flatten-repos [polyrepo_root: path repo_dirs_root: path repo_groups: record repos_catalog: record errors: list<record>]: nothing -> record {
  mut errors = $errors
  mut flattened = {}

  for group_name in ($repo_groups | columns | sort) {
    let group_entry = ($repo_groups | get $group_name)

    for member_name in (($group_entry.members | columns) | sort) {
      if $member_name in ($flattened | columns) {
        $errors = append-error $errors $"repoGroups.($group_name).members" $"duplicate repo name '($member_name)'"
        continue
      }

      let group_path = ($group_entry.members | get $member_name)
      $flattened = ($flattened | merge {
        $member_name: {
          path: $group_path
          layers: $group_entry.layers
          bootstrapDeps: $group_entry.bootstrapDeps
          bootstrapTasks: $group_entry.bootstrapTasks
          sourcePath: $"repoGroups.($group_name).members.($member_name)"
        }
      })
    }
  }

  for repo_name in ($repos_catalog | columns | sort) {
    if $repo_name in ($flattened | columns) {
      $errors = append-error $errors $"repos.($repo_name)" $"duplicate repo name '($repo_name)' also defined via repoGroups"
      continue
    }

    let repo_entry = ($repos_catalog | get $repo_name)
    $flattened = ($flattened | merge {
      $repo_name: ($repo_entry | merge { sourcePath: $"repos.($repo_name).path" })
    })
  }

  mut resolved_records = []
  for repo_name in ($flattened | columns | sort) {
    let repo_entry = ($flattened | get $repo_name)
    let resolved_path = resolve-repo-path $polyrepo_root ($repo_entry | get path)
    let relative_path = maybe-relativize $resolved_path $repo_dirs_root

    if (($relative_path | describe) == 'nothing') {
      $errors = append-error $errors ($repo_entry | get sourcePath) $"resolves to ($resolved_path), which is outside repoDirsPath rooted at ($repo_dirs_root)"
    } else if not (is-repo-root $resolved_path) {
      $errors = append-error $errors ($repo_entry | get sourcePath) $"resolves to ($resolved_path), which is not a repo root"
    }

    $resolved_records = ($resolved_records | append {
      name: $repo_name
      path: $resolved_path
      layers: ($repo_entry | get layers)
      bootstrapDeps: ($repo_entry | get bootstrapDeps)
      bootstrapTasks: ($repo_entry | get bootstrapTasks)
      sourcePath: ($repo_entry | get sourcePath)
    })
  }

  let duplicate_paths = (
    $resolved_records
    | group-by path
    | transpose path entries
    | where {|group| (($group.entries | length) > 1) }
  )
  for duplicate_group in $duplicate_paths {
    let duplicate_names = (
      $duplicate_group.entries
      | each {|entry| $entry.name }
      | sort
      | str join ", "
    )
    $errors = append-error $errors "repos" $"multiple repos resolve to the same path ($duplicate_group.path): ($duplicate_names)"
  }

  {
    errors: $errors
    repos: (
      $resolved_records
      | each {|entry|
          [
            $entry.name
            {
              path: $entry.path
              layers: $entry.layers
              bootstrapDeps: $entry.bootstrapDeps
              bootstrapTasks: $entry.bootstrapTasks
              sourcePath: $entry.sourcePath
            }
          ]
        }
      | into record
    )
  }
}

export def load-manifest [polyrepo_root: path]: nothing -> record {
  let polyrepo_root = ($polyrepo_root | path expand --no-symlink)
  let manifest_path = manifest-path $polyrepo_root

  if not ($manifest_path | path exists) {
    fail $"expected (polyrepo-manifest-basename) at ($polyrepo_root)"
  }

  let manifest_text = open --raw $manifest_path
  let manifest_label = $"polyrepo manifest '($manifest_path)'"
  let manifest = parse-nuon-mapping $manifest_label $manifest_text
  let repo_dirs_path = require-string ($manifest | get -o repoDirsPath) $"repoDirsPath in ($manifest_label)"
  let repo_dirs_root = resolve-repo-path $polyrepo_root $repo_dirs_path
  let root_entry = ($manifest | get -o root | default {})

  if (($root_entry | describe) !~ '^record') {
    fail $"expected root in ($manifest_label) to be a mapping"
  }

  let inputs_catalog = ($manifest | get -o inputs | default {})
  let layers_catalog = ($manifest | get -o layers | default {})
  let repo_groups_catalog = ($manifest | get -o repoGroups | default {})
  let repos_catalog = ($manifest | get -o repos | default {})

  if (($inputs_catalog | describe) !~ '^record') {
    fail $"expected inputs in ($manifest_label) to be a mapping"
  }

  if (($layers_catalog | describe) !~ '^record') {
    fail $"expected layers in ($manifest_label) to be a mapping"
  }

  if (($repo_groups_catalog | describe) !~ '^record') {
    fail $"expected repoGroups in ($manifest_label) to be a mapping"
  }

  if (($repos_catalog | describe) !~ '^record') {
    fail $"expected repos in ($manifest_label) to be a mapping"
  }

  let inputs = (
    $inputs_catalog
    | items {|input_name, input_value|
        [ (require-string $input_name "input names") (normalize-input-entry $input_name $input_value $manifest_label) ]
      }
    | into record
  )
  let layers = (
    $layers_catalog
    | items {|layer_name, layer_value|
        [ (require-string $layer_name "layer names") (normalize-layer-entry $layer_name $layer_value $manifest_label) ]
      }
    | into record
  )
  let repo_groups = (
    $repo_groups_catalog
    | items {|group_name, group_value|
        [ (require-string $group_name "repo group names") (normalize-repo-group-entry $group_name $group_value $manifest_label) ]
      }
    | into record
  )
  let repos_catalog = (
    $repos_catalog
    | items {|repo_name, repo_value|
        [ (require-string $repo_name "repo names") (normalize-repo-entry $repo_name $repo_value $manifest_label) ]
      }
    | into record
  )

  let flattened = flatten-repos $polyrepo_root $repo_dirs_root $repo_groups $repos_catalog []

  {
    manifest_path: $manifest_path
    manifest_text: $manifest_text
    polyrepo_root: $polyrepo_root
    repoDirsPath: $repo_dirs_path
    repoDirsRoot: $repo_dirs_root
    root: {
      layers: (expect-string-list ($root_entry | get -o layers) $"layers in root of ($manifest_label)")
    }
    inputs: $inputs
    layers: $layers
    repoGroups: $repo_groups
    repos: $flattened.repos
    errors: $flattened.errors
  }
}

def resolve-layer-spec [model: record layer_name: string stack: list<string>]: nothing -> record {
  if $layer_name in $stack {
    fail $"cyclic layer chain: (($stack | append $layer_name) | str join ' -> ')"
  }

  let layer_entry = ($model.layers | get -o $layer_name)
  if (($layer_entry | describe) !~ '^record') {
    fail $"unknown layer '($layer_name)'"
  }

  mut resolved = {
    inputs: []
    imports: []
  }

  for parent_name in ($layer_entry | get extends) {
    $resolved = merge-layer-spec $resolved (resolve-layer-spec $model $parent_name ($stack | append $layer_name))
  }

  merge-layer-spec $resolved {
    inputs: ($layer_entry | get inputs)
    imports: ($layer_entry | get imports)
  }
}

def resolve-target-layer-spec [model: record target_kind: string target_name: any]: nothing -> record {
  let layer_names = if $target_kind == "root" {
    $model.root.layers
  } else {
    let repo_entry = ($model.repos | get -o $target_name)
    if (($repo_entry | describe) !~ '^record') {
      fail $"unknown repo '($target_name)'"
    }
    $repo_entry.layers
  }

  mut resolved = {
    inputs: []
    imports: []
  }

  for layer_name in $layer_names {
    $resolved = merge-layer-spec $resolved (resolve-layer-spec $model $layer_name [])
  }

  $resolved
}

def validate-model [model: record]: nothing -> record {
  mut errors = ($model.errors | default [])
  let input_names = ($model.inputs | columns)
  let layer_names = ($model.layers | columns)
  let repo_names = ($model.repos | columns)

  for layer_name in $model.root.layers {
    if not ($layer_name in $layer_names) {
      $errors = append-error $errors "root.layers" $"references unknown layer '($layer_name)'"
    }
  }

  for input_name in $input_names {
    let input_entry = ($model.inputs | get $input_name)
    let local_repo = ($input_entry | get localRepo)
    if (($local_repo | describe) == 'string') and (not ($local_repo in $repo_names)) {
      $errors = append-error $errors $"inputs.($input_name).localRepo" $"references unknown repo '($local_repo)'"
    }

    for dependency_name in ($input_entry | get requiresInputs) {
      if not ($dependency_name in $input_names) {
        $errors = append-error $errors $"inputs.($input_name).requiresInputs" $"references unknown input '($dependency_name)'"
      }
    }

    for import_name in ($input_entry | get imports) {
      let import_input_name = (get-import-input-name $import_name)
      if (($import_input_name | describe) == 'string') and (not ($import_input_name in $input_names)) {
        $errors = append-error $errors $"inputs.($input_name).imports" $"references import '($import_name)' whose base input '($import_input_name)' is not declared in inputs"
      }
    }
  }

  for layer_name in $layer_names {
    let layer_entry = ($model.layers | get $layer_name)

    for parent_name in ($layer_entry | get extends) {
      if not ($parent_name in $layer_names) {
        $errors = append-error $errors $"layers.($layer_name).extends" $"references unknown layer '($parent_name)'"
      }
    }

    for input_name in ($layer_entry | get inputs) {
      if not ($input_name in $input_names) {
        $errors = append-error $errors $"layers.($layer_name).inputs" $"references unknown input '($input_name)'"
      }
    }

    for import_name in ($layer_entry | get imports) {
      let import_input_name = (get-import-input-name $import_name)
      if (($import_input_name | describe) == 'string') and (not ($import_input_name in $input_names)) {
        $errors = append-error $errors $"layers.($layer_name).imports" $"references import '($import_name)' whose base input '($import_input_name)' is not declared in inputs"
      }
    }

    let layer_error = try {
      resolve-layer-spec $model $layer_name [] | ignore
      null
    } catch {|err|
      $err.msg
    }
    if (($layer_error | describe) == 'string') {
      $errors = append-error $errors $"layers.($layer_name)" $layer_error
    }
  }

  for repo_name in $repo_names {
    let repo_entry = ($model.repos | get $repo_name)

    for layer_name in ($repo_entry | get layers) {
      if not ($layer_name in $layer_names) {
        $errors = append-error $errors $"repos.($repo_name).layers" $"references unknown layer '($layer_name)'"
      }
    }

    for dependency_name in ($repo_entry | get bootstrapDeps) {
      if not ($dependency_name in $repo_names) {
        $errors = append-error $errors $"repos.($repo_name).bootstrapDeps" $"references unknown repo '($dependency_name)'"
      }
    }
  }

  {
    ok: ($errors | is-empty)
    manifest_path: $model.manifest_path
    polyrepo_root: $model.polyrepo_root
    repo_count: ($repo_names | length)
    group_count: (($model.repoGroups | columns | length))
    layer_count: ($layer_names | length)
    error_count: ($errors | length)
    errors: $errors
  }
}

def repo-record-by-path [model: record repo_root: path]: nothing -> oneof<record, nothing> {
  let repo_root = ($repo_root | path expand --no-symlink | into string)
  let matches = (
    $model.repos
    | transpose repo_name repo_entry
    | where {|entry| (($entry.repo_entry | get path) | into string) == $repo_root }
  )

  let match = ($matches | get -o 0)
  if (($match | describe) !~ '^record') {
    return null
  }

  {
    name: $match.repo_name
    entry: $match.repo_entry
  }
}

def find-polyrepo-root [start_path: path]: nothing -> oneof<path, nothing> {
  let start_path = ($start_path | path expand --no-symlink)
  let repo_root = (find-repo-root $start_path | default $start_path)
  mut current = $repo_root

  while true {
    let candidate_manifest = manifest-path $current

    if ($candidate_manifest | path exists) {
      return $current
    }

    let parent = ($current | path dirname)
    if $parent == $current {
      return null
    }

    $current = $parent
  }
}

def require-valid-model [model: record]: nothing -> record {
  let status = validate-model $model

  if not $status.ok {
    let rendered_errors = (
      $status.errors
      | each {|entry| $"($entry.path): ($entry.message)" }
      | str join "\n"
    )
    fail $rendered_errors
  }

  $model
}

def resolve-target [target_path: path]: nothing -> record {
  let start_path = (resolve-repo-path (pwd) $target_path)
  let repo_root = (find-repo-root $start_path | default $start_path)
  let polyrepo_root = (find-polyrepo-root $start_path)

  if (($polyrepo_root | describe) != 'string') {
    fail $"polyrepo root could not be inferred from ($start_path)"
  }

  let model = require-valid-model (load-manifest $polyrepo_root)
  let normalized_polyrepo_root = ($polyrepo_root | path expand --no-symlink)
  let normalized_repo_root = ($repo_root | path expand --no-symlink)

  if $normalized_repo_root == $normalized_polyrepo_root {
    return {
      polyrepo_root: $normalized_polyrepo_root
      model: $model
      target_root: $normalized_polyrepo_root
      target_kind: "root"
      target_name: null
    }
  }

  let repo_record = repo-record-by-path $model $normalized_repo_root
  if (($repo_record | describe) !~ '^record') {
    let repo_names = ($model.repos | columns)
    fail $"expected repo root ($normalized_repo_root) to be present in the manifest-owned repo catalog at (($normalized_polyrepo_root | path join (polyrepo-manifest-basename))); available repo names: (describe-repo-list $repo_names)"
  }

  {
    polyrepo_root: $normalized_polyrepo_root
    model: $model
    target_root: $normalized_repo_root
    target_kind: "repo"
    target_name: $repo_record.name
  }
}

def selected-imports [imports_list: list<string> effective_input_names: list<string>]: nothing -> list<string> {
  $imports_list
  | where {|import_name|
      let import_input_name = (get-import-input-name $import_name | default $import_name)
      $import_input_name in $effective_input_names
    }
  | uniq
}

def render-target-overrides [model: record target_kind: string target_name: any]: nothing -> record {
  let target_spec = resolve-target-layer-spec $model $target_kind $target_name
  let repo_paths = (
    $model.repos
    | items {|repo_name, repo_entry| [$repo_name (($repo_entry | get path) | into string)] }
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
    let input_entry = ($model.inputs | get -o $input_name)
    if (($input_entry | describe) !~ '^record') {
      fail $"unknown input '($input_name)'"
    }

    let local_repo = ($input_entry | get localRepo)
    if (($local_repo | describe) != 'string') {
      continue
    }

    let repo_path = ($repo_paths | get -o $local_repo)
    if (($repo_path | describe) != 'string') {
      fail $"input '($input_name)' maps to unknown local repo '($local_repo)'"
    }

    $local_repo_names = ($local_repo_names | append $local_repo)
    $overrides = ($overrides | merge {
      $input_name: ((($input_entry | get spec) | merge { url: $"path:($repo_path)" }))
    })
    $collected_input_imports = ($collected_input_imports | append ($input_entry | get imports))
    $pending_inputs = ($pending_inputs | append ($input_entry | get requiresInputs))
  }

  let effective_input_names = ($overrides | columns | uniq)
  let rendered_imports = (($target_spec.imports | append $collected_input_imports) | flatten | uniq)

  {
    overrides: $overrides
    imports: (selected-imports $rendered_imports $effective_input_names)
    local_repo_names: ($local_repo_names | uniq | sort)
  }
}

def render-overrides-text [rendered: record]: nothing -> string {
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

def make-lock-status [status: string input_name?: any]: nothing -> record {
  {
    status: $status
    clean: ($status == "clean")
    input_name: ($input_name | default null)
  }
}

def lock-status [output_path: path lock_path: path]: nothing -> record {
  if not ($output_path | path exists) {
    return (make-lock-status "clean")
  }

  let local_doc = parse-yaml-mapping $output_path (open --raw $output_path)
  let desired_inputs = ($local_doc | get -o inputs | default {})

  if (($desired_inputs | describe) !~ '^record') {
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
  let root_name = ($lock_doc | get -o root)
  let nodes = ($lock_doc | get -o nodes | default {})
  let root_node = if (($root_name | describe) == 'string') and ($root_name in ($nodes | columns)) {
    $nodes | get $root_name
  } else {
    {}
  }
  let root_inputs = ($root_node | get -o inputs | default {})

  for input_name in ($desired_inputs | columns | sort) {
    if not ($input_name in ($root_inputs | columns)) {
      return (make-lock-status "missing-root-input" $input_name)
    }

    let input_spec = ($desired_inputs | get $input_name)
    let url = ($input_spec | get -o url)
    let locked_name = ($root_inputs | get $input_name)
    let locked_node = if (($locked_name | describe) == 'string') and ($locked_name in ($nodes | columns)) {
      $nodes | get $locked_name
    } else {
      {}
    }
    let locked_original = ($locked_node | get -o original)

    if (($url | describe) == 'string') and (($locked_original | describe) == 'string') and ($locked_original != $url) {
      return (make-lock-status "stale-root-input" $input_name)
    }
  }

  make-lock-status "clean"
}

export def sync [target_path?: path]: nothing -> record {
  let target = resolve-target ($target_path | default ".")
  let output_path = ($target.target_root | path join "devenv.local.yaml")
  let lock_path = ($target.target_root | path join "devenv.lock")
  let rendered = render-target-overrides $target.model $target.target_kind $target.target_name
  let overrides_text = render-overrides-text $rendered

  let existing_text = if ($output_path | path exists) {
    open --raw $output_path
  }
  mut mode = "unchanged"

  if $overrides_text == "" {
    if (($existing_text | describe) == 'string') {
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
    | items {|repo_name, repo_entry| [$repo_name (($repo_entry | get path) | into string)] }
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
    target_name: ($target.target_name | default null)
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

def latest-shell-export [repo_root: path]: nothing -> oneof<path, nothing> {
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

def materialize-shell-export [repo_root: path]: nothing -> nothing {
  do {
    cd $repo_root
    ^devenv shell --no-tui -- bash -lc "true" | ignore
  }
}

def ensure-shell-export [repo_root: path refresh_requested: bool]: nothing -> record {
  let existing_export = (latest-shell-export $repo_root)

  if (($existing_export | describe) == 'string') and (not $refresh_requested) {
    return {
      shell_export_path: $existing_export
      shell_export_refreshed: false
    }
  }

  materialize-shell-export $repo_root
  let refreshed_export = (latest-shell-export $repo_root)

  if (($refreshed_export | describe) != 'string') {
    fail $"expected devenv shell export under (($repo_root | path join '.devenv'))"
  }

  {
    shell_export_path: $refreshed_export
    shell_export_refreshed: true
  }
}

def run-bootstrap-task [repo_root: path task_name: string]: nothing -> record {
  match $task_name {
    "devenv:files" => {
      do {
        cd $repo_root
        ^devenv tasks --no-tui --no-eval-cache --refresh-eval-cache run devenv:files | ignore
      }
      {
        task: $task_name
        ran: true
      }
    }
    _ => {
      fail $"unsupported bootstrap task '($task_name)'"
    }
  }
}

def bootstrap-order [model: record repo_name: string stack: list<string> visited: list<string>]: nothing -> record {
  if $repo_name in $stack {
    fail $"cyclic bootstrap dependency chain: (($stack | append $repo_name) | str join ' -> ')"
  }

  if $repo_name in $visited {
    return {
      order: []
      visited: $visited
    }
  }

  let repo_entry = ($model.repos | get -o $repo_name)
  if (($repo_entry | describe) !~ '^record') {
    fail $"unknown repo '($repo_name)'"
  }

  mut visited = ($visited | append $repo_name)
  mut order = []

  for dependency_name in ($repo_entry | get bootstrapDeps) {
    let dependency_state = bootstrap-order $model $dependency_name ($stack | append $repo_name) $visited
    $visited = $dependency_state.visited
    $order = ($order | append $dependency_state.order)
  }

  {
    order: (($order | append $repo_name) | uniq)
    visited: $visited
  }
}

def bootstrapable-repo-records [model: record]: nothing -> list<record> {
  $model.repos
  | transpose repo_name repo_entry
  | each {|entry|
      {
        name: $entry.repo_name
        path: ($entry.repo_entry | get path)
        bootstrapTasks: ($entry.repo_entry | get bootstrapTasks)
        bootstrapDeps: ($entry.repo_entry | get bootstrapDeps)
      }
    }
  | where {|entry| is-bootstrap-target $entry.path }
  | sort-by name
}

def bootstrap-one [target_root: path]: nothing -> record {
  let target = resolve-target $target_root
  let target_model = $target.model
  let dependency_names = if $target.target_kind == "root" {
    []
  } else {
    (
      (bootstrap-order $target_model $target.target_name [] []).order
      | where {|repo_name| $repo_name != $target.target_name }
    )
  }

  mut repo_results = []
  for repo_name in $dependency_names {
    let repo_entry = ($target_model.repos | get $repo_name)
    let repo_root = ($repo_entry | get path)
    let sync_status = sync $repo_root
    let task_results = (
      $repo_entry.bootstrapTasks
      | each {|task_name| run-bootstrap-task $repo_root $task_name }
    )

    $repo_results = ($repo_results | append {
      repo_name: $repo_name
      repo_root: $repo_root
      sync: $sync_status
      bootstrap_tasks: $task_results
    })
  }

  let target_sync = sync $target.target_root
  let target_repo_entry = if $target.target_kind == "repo" {
    $target_model.repos | get $target.target_name
  } else {
    { bootstrapTasks: [] }
  }
  let target_task_results = (
    $target_repo_entry.bootstrapTasks
    | each {|task_name| run-bootstrap-task $target.target_root $task_name }
  )
  let tasks_ran = (($target_task_results | where ran == true | length) > 0)

  let lock_refreshed = if $target_sync.changed or $target_sync.lock_refresh_needed {
    do {
      cd $target.target_root
      ^devenv update | ignore
    }
    true
  } else {
    false
  }
  let shell_export_status = ensure-shell-export $target.target_root ($lock_refreshed or $tasks_ran)

  {
    target_root: $target.target_root
    target_kind: $target.target_kind
    target_name: ($target.target_name | default null)
    dependency_repos: ($repo_results | each {|entry| $entry.repo_name })
    dependency_results: $repo_results
    sync: $target_sync
    bootstrap_tasks: $target_task_results
    lock_refreshed: $lock_refreshed
    shell_export_path: $shell_export_status.shell_export_path
    shell_export_refreshed: $shell_export_status.shell_export_refreshed
  }
}

export def bootstrap [target_path?: path]: nothing -> record {
  bootstrap-one ($target_path | default ".")
}

export def bootstrap-all [target_path?: path]: nothing -> record {
  let target = resolve-target ($target_path | default ".")
  let bootstrap_targets = bootstrapable-repo-records $target.model

  let results = (
    $bootstrap_targets
    | each {|repo|
        try {
          {
            repo_root: $repo.path
            repo_name: $repo.name
            ok: true
            status: (bootstrap-one $repo.path)
            error: null
          }
        } catch {|err|
          {
            repo_root: $repo.path
            repo_name: $repo.name
            ok: false
            status: null
            error: $err.msg
          }
        }
      }
  )
  let failures = ($results | where ok == false)
  let summary = {
    repo_count: ($bootstrap_targets | length)
    success_count: ($results | where ok == true | length)
    failure_count: ($failures | length)
    results: $results
  }

  if not ($failures | is-empty) {
    error make {
      msg: $"bootstrap failed for ($summary.failure_count) repos"
      summary: $summary
      results: $results
    }
  }

  $summary
}

export def check [target_path?: path]: nothing -> record {
  let start_path = (resolve-repo-path (pwd) ($target_path | default "."))
  let polyrepo_root = if ((manifest-path $start_path) | path exists) {
    $start_path | path expand --no-symlink
  } else {
    find-polyrepo-root $start_path
  }

  if (($polyrepo_root | describe) != 'string') {
    fail $"polyrepo root could not be inferred from ($start_path)"
  }

  validate-model (load-manifest $polyrepo_root)
}
