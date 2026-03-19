use ../support.nu [
  fail
  is-list
  is-non-empty-string
  is-nothing
  is-record
  polyrepo-manifest-basename
]

def normalize-structured-value [value: any]: nothing -> any {
  match ($value | describe) {
    $t if ($t =~ '^record') => {
      $value
      | items {|key, item| [$key (normalize-structured-value $item)] }
      | into record
    }
    $t if ($t =~ '^list') => {
      $value | each {|item| normalize-structured-value $item }
    }
    _ => $value
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

  if not (is-record $parsed) {
    fail $"expected a top-level mapping in ($source_label)"
  }

  normalize-structured-value $parsed
}

export def parse-yaml-mapping [source_label: string yaml_text: string]: nothing -> record {
  let parsed = if ($yaml_text | str trim) == "" {
    {}
  } else {
    try {
      $yaml_text | from yaml | default {}
    } catch {
      fail $"expected a top-level mapping in ($source_label)"
    }
  }

  if not (is-record $parsed) {
    fail $"expected a top-level mapping in ($source_label)"
  }

  normalize-structured-value $parsed
}

def require-string [value: any field_label: string]: nothing -> string {
  if not (is-non-empty-string $value) {
    fail $"expected ($field_label) to be a non-empty string"
  }

  $value
}

def optional-string [value: any field_label: string]: nothing -> oneof<string, nothing> {
  if (is-nothing $value) {
    return null
  }

  require-string $value $field_label
}

def expect-string-list [value: any field_label: string]: nothing -> list<string> {
  if (is-nothing $value) {
    return []
  }

  if not (is-list $value) {
    fail $"expected ($field_label) to be a list"
  }

  $value
  | each {|item| require-string $item $"entries in ($field_label)" }
  | uniq
}

def expect-string-record [value: any field_label: string]: nothing -> record {
  if not (is-record $value) {
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

export def resolve-repo-path [base_path: path candidate_path: path]: nothing -> path {
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

export def is-repo-root [path_value: path]: nothing -> bool {
  (
    (($path_value | path join ".git") | path exists)
    or (($path_value | path join "devenv.yaml") | path exists)
    or (($path_value | path join "devenv.nix") | path exists)
  )
}

export def is-bootstrap-target [path_value: path]: nothing -> bool {
  (
    (($path_value | path join "devenv.yaml") | path exists)
    or (($path_value | path join "devenv.nix") | path exists)
  )
}

export def find-repo-root [start_path: path]: nothing -> oneof<path, nothing> {
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

export def manifest-path [polyrepo_root: path]: nothing -> path {
  ($polyrepo_root | path join (polyrepo-manifest-basename))
}

export def get-import-input-name [import_name: string]: nothing -> oneof<string, nothing> {
  if ([ "path:" "/" "./" "../" ] | any {|prefix| $import_name | str starts-with $prefix }) {
    return null
  }

  $import_name | split row "/" | first | into string
}

def normalize-input-entry [input_name: string input_value: any manifest_label: string]: nothing -> record {
  let source_label = $"inputs.($input_name) in ($manifest_label)"

  if not (is-record $input_value) {
    fail $"expected ($source_label) to be a mapping"
  }

  let spec = ($input_value | reject --optional imports requiresInputs localRepo)
  let url = ($spec | get -o url)
  if not (is-non-empty-string $url) {
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

  if not (is-record $layer_value) {
    fail $"expected ($source_label) to be a mapping"
  }

  {
    extends: (expect-string-list ($layer_value | get -o extends) $"extends in ($source_label)")
    inputs: (expect-string-list ($layer_value | get -o inputs) $"inputs in ($source_label)")
    imports: (expect-string-list ($layer_value | get -o imports) $"imports in ($source_label)")
  }
}

def normalize-repo-config [entry_label: string entry_value: any]: nothing -> record {
  if not (is-record $entry_value) {
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

export def merge-layer-spec [first: record second: record]: nothing -> record {
  {
    inputs: (($first.inputs | append $second.inputs) | uniq)
    imports: (($first.imports | append $second.imports) | uniq)
  }
}

export def append-error [errors: list<record> path: string message: string]: nothing -> list<record> {
  $errors | append { path: $path, message: $message }
}

export def describe-repo-list [repo_names: list<string>]: nothing -> string {
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

    if (is-nothing $relative_path) {
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

  if not (is-record $root_entry) {
    fail $"expected root in ($manifest_label) to be a mapping"
  }

  let inputs_catalog = ($manifest | get -o inputs | default {})
  let layers_catalog = ($manifest | get -o layers | default {})
  let repo_groups_catalog = ($manifest | get -o repoGroups | default {})
  let repos_catalog = ($manifest | get -o repos | default {})

  if not (is-record $inputs_catalog) {
    fail $"expected inputs in ($manifest_label) to be a mapping"
  }

  if not (is-record $layers_catalog) {
    fail $"expected layers in ($manifest_label) to be a mapping"
  }

  if not (is-record $repo_groups_catalog) {
    fail $"expected repoGroups in ($manifest_label) to be a mapping"
  }

  if not (is-record $repos_catalog) {
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

export def find-polyrepo-root [start_path: path]: nothing -> oneof<path, nothing> {
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
