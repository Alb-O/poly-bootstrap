use ../support.nu [fail is-record is-string]
use manifest.nu [
  append-error
  describe-repo-list
  find-polyrepo-root
  find-repo-root
  get-import-input-name
  load-manifest
  manifest-path
  merge-layer-spec
  resolve-repo-path
]

def resolve-layer-spec [model: record layer_name: string stack: list<string>]: nothing -> record {
  if $layer_name in $stack {
    fail $"cyclic layer chain: (($stack | append $layer_name) | str join ' -> ')"
  }

  let layer_entry = ($model.layers | get -o $layer_name)
  if not (is-record $layer_entry) {
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

export def resolve-target-layer-spec [model: record target_kind: string target_name: any]: nothing -> record {
  let layer_names = if $target_kind == "root" {
    $model.root.layers
  } else {
    let repo_entry = ($model.repos | get -o $target_name)
    if not (is-record $repo_entry) {
      fail $"unknown repo '($target_name)'"
    }
    $repo_entry.layers
  }

  $layer_names
  | reduce --fold { inputs: [], imports: [] } {|layer_name, resolved|
      merge-layer-spec $resolved (resolve-layer-spec $model $layer_name [])
    }
}

export def validate-model [model: record]: nothing -> record {
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
    if (is-string $local_repo) and (not ($local_repo in $repo_names)) {
      $errors = append-error $errors $"inputs.($input_name).localRepo" $"references unknown repo '($local_repo)'"
    }

    for dependency_name in ($input_entry | get requiresInputs) {
      if not ($dependency_name in $input_names) {
        $errors = append-error $errors $"inputs.($input_name).requiresInputs" $"references unknown input '($dependency_name)'"
      }
    }

    for import_name in ($input_entry | get imports) {
      let import_input_name = (get-import-input-name $import_name)
      if (is-string $import_input_name) and (not ($import_input_name in $input_names)) {
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
      if (is-string $import_input_name) and (not ($import_input_name in $input_names)) {
        $errors = append-error $errors $"layers.($layer_name).imports" $"references import '($import_name)' whose base input '($import_input_name)' is not declared in inputs"
      }
    }

    let layer_error = try {
      resolve-layer-spec $model $layer_name [] | ignore
      null
    } catch {|err|
      $err.msg
    }
    if (is-string $layer_error) {
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
  if not (is-record $match) {
    return null
  }

  {
    name: $match.repo_name
    entry: $match.repo_entry
  }
}

export def require-valid-model [model: record]: nothing -> record {
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

export def resolve-target [target_path: path]: nothing -> record {
  let start_path = (resolve-repo-path (pwd) $target_path)
  let repo_root = (find-repo-root $start_path | default $start_path)
  let polyrepo_root = (find-polyrepo-root $start_path)

  if not (is-string $polyrepo_root) {
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
  if not (is-record $repo_record) {
    let repo_names = ($model.repos | columns)
    let catalog_path = (manifest-path $normalized_polyrepo_root)
    fail $"expected repo root ($normalized_repo_root) to be present in the manifest-owned repo catalog at ($catalog_path); available repo names: (describe-repo-list $repo_names)"
  }

  {
    polyrepo_root: $normalized_polyrepo_root
    model: $model
    target_root: $normalized_repo_root
    target_kind: "repo"
    target_name: $repo_record.name
  }
}
