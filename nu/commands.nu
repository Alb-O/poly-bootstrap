use overrides.nu [build-overrides render-overrides-text]
use paths.nu [
  find-repo-root
  list-local-repo-paths
  list-local-repo-names
  load-repo-sources
  maybe-relativize
  path-from-url
  resolve-polyrepo-root
  resolve-repo-dirs-root
  resolve-repo-path
]
use sources.nu [
  expect-string-list
  expect-string-record
  parse-json-record
  parse-top-level-mapping
]
use support.nu [fail fail-on-overlap global-inputs-basename]

def require-string [value: any field_label: string]: nothing -> oneof<string, error> {
  if (($value | describe) != 'string') {
    fail $"expected ($field_label) to be a string"
  }

  $value
}

def require-path [value: any field_label: string]: nothing -> oneof<path, error> {
  if (($value | describe) != 'string') {
    fail $"expected ($field_label) to be a path"
  }

  $value
}

def validate-url-scheme [url_scheme: string]: nothing -> oneof<nothing, error> {
  if $url_scheme not-in [ "path" "git+file" ] {
    fail $"expected url scheme to be one of: path, git+file (got '($url_scheme)')"
  }
}

def render-normalized-overrides [spec: record]: nothing -> string {
  let rendered = build-overrides $spec.source_yaml_text $spec.global_inputs_yaml_text $spec.local_repo_names $spec.local_repo_paths $spec.repo_sources $spec.include_inputs $spec.exclude_inputs $spec.repo_dirs_root $spec.url_scheme
  render-overrides-text $rendered.overrides $rendered.imports
}

def normalize-render-spec [spec: record]: nothing -> record {
  # The machine render API allows a compact manifest, so fill in the optional
  # fields once here and keep the renderer itself on a fully normalized shape.
  let spec = (
    {
      global_inputs_yaml_text: ""
      local_repo_names: []
      local_repo_paths: {}
      repo_sources: {}
      include_inputs: []
      exclude_inputs: []
    }
    | merge $spec
  )

  let source_yaml_text = require-string ($spec | get -o source_yaml_text) "source_yaml_text"
  let global_inputs_yaml_text = require-string ($spec | get -o global_inputs_yaml_text) "global_inputs_yaml_text"
  let local_repo_names = expect-string-list ($spec | get -o local_repo_names | default []) "local_repo_names"
  let local_repo_paths = expect-string-record ($spec | get -o local_repo_paths | default {}) "local_repo_paths"
  let repo_sources = expect-string-record ($spec | get -o repo_sources | default {}) "repo_sources"
  let include_inputs = expect-string-list ($spec | get -o include_inputs | default []) "include_inputs"
  let exclude_inputs = expect-string-list ($spec | get -o exclude_inputs | default []) "exclude_inputs"
  let repo_dirs_root = require-path ($spec | get -o repo_dirs_root) "repo_dirs_root"
  let url_scheme = require-string ($spec | get -o url_scheme) "url_scheme"

  validate-url-scheme $url_scheme
  fail-on-overlap $include_inputs $exclude_inputs "included inputs" "excluded inputs"

  {
    source_yaml_text: $source_yaml_text
    global_inputs_yaml_text: $global_inputs_yaml_text
    local_repo_names: $local_repo_names
    local_repo_paths: $local_repo_paths
    repo_sources: $repo_sources
    include_inputs: $include_inputs
    exclude_inputs: $exclude_inputs
    repo_dirs_root: $repo_dirs_root
    url_scheme: $url_scheme
  }
}

def normalize-sync-spec [spec: record]: nothing -> record {
  # Sync callers get repo-oriented defaults that match the CLI, but the command
  # implementation works against one explicit record shape after normalization.
  let spec = (
    {
      source_path: "devenv.yaml"
      output_path: "devenv.local.yaml"
      polyrepo_root: null
      repo_dirs_path: "repos"
      url_scheme: "path"
      include_repos: []
      exclude_repos: []
      include_inputs: []
      exclude_inputs: []
    }
    | merge $spec
  )

  let repo_root = require-path ($spec | get -o repo_root) "repo_root"
  let source_path = require-path ($spec | get -o source_path) "source_path"
  let output_path = require-path ($spec | get -o output_path) "output_path"
  let repo_dirs_path = require-path ($spec | get -o repo_dirs_path) "repo_dirs_path"
  let url_scheme = require-string ($spec | get -o url_scheme) "url_scheme"
  let include_repos = expect-string-list ($spec | get -o include_repos | default []) "include_repos"
  let exclude_repos = expect-string-list ($spec | get -o exclude_repos | default []) "exclude_repos"
  let include_inputs = expect-string-list ($spec | get -o include_inputs | default []) "include_inputs"
  let exclude_inputs = expect-string-list ($spec | get -o exclude_inputs | default []) "exclude_inputs"

  validate-url-scheme $url_scheme
  fail-on-overlap $include_repos $exclude_repos "included repos" "excluded repos"
  fail-on-overlap $include_inputs $exclude_inputs "included inputs" "excluded inputs"

  {
    repo_root: $repo_root
    source_path: $source_path
    output_path: $output_path
    polyrepo_root: ($spec | get -o polyrepo_root)
    repo_dirs_path: $repo_dirs_path
    url_scheme: $url_scheme
    include_repos: $include_repos
    exclude_repos: $exclude_repos
    include_inputs: $include_inputs
    exclude_inputs: $exclude_inputs
  }
}

def make-lock-status [status: string input_name?: any]: nothing -> record {
  {
    status: $status
    clean: ($status == "clean")
    input_name: ($input_name | default null)
  }
}

def sync-needs-refresh [status: record]: nothing -> bool {
  $status.changed or $status.lock_refresh_needed
}

def parse-render-manifest [manifest_path: path]: nothing -> record {
  normalize-render-spec (
    parse-json-record $manifest_path "expected render manifest JSON to be a mapping"
  )
}

def cargo-manifest-path [repo_root: path]: nothing -> oneof<path, nothing> {
  let manifest_path = (resolve-repo-path $repo_root "Cargo.toml")

  if ($manifest_path | path exists) {
    return $manifest_path
  }

  let poly_manifest_path = (resolve-repo-path $repo_root "Cargo.poly.toml")

  if ($poly_manifest_path | path exists) {
    return $poly_manifest_path
  }
}

def managed-cargo-refresh-needed [repo_root: path]: nothing -> bool {
  let manifest_path = (resolve-repo-path $repo_root "Cargo.toml")
  let poly_manifest_path = (resolve-repo-path $repo_root "Cargo.poly.toml")

  (not ($manifest_path | path exists)) and ($poly_manifest_path | path exists)
}

def load-cargo-manifest [manifest_path: path]: nothing -> oneof<record, error> {
  try {
    open --raw $manifest_path | from toml
  } catch {
    fail $"expected valid TOML in ($manifest_path)"
  }
}

def collect-local-dependency-paths [value: any]: nothing -> list<path> {
  let value_type = ($value | describe)

  if $value_type =~ '^record' {
    let direct_path = ($value | get -o path)
    let nested_paths = (
      $value
      | values
      | each {|entry| collect-local-dependency-paths $entry }
      | flatten
    )

    [
      (if (($direct_path | describe) == 'string') { [ $direct_path ] } else { [] })
      $nested_paths
    ]
    | flatten
  } else if $value_type =~ '^list' {
    $value
    | each {|entry| collect-local-dependency-paths $entry }
    | flatten
  } else {
    []
  }
}

def list-cargo-dependency-repo-roots [repo_root: path]: nothing -> list<path> {
  let manifest_path = cargo-manifest-path $repo_root

  if ($manifest_path | describe) == 'nothing' {
    return []
  }

  let manifest = load-cargo-manifest $manifest_path

  collect-local-dependency-paths $manifest
  | each {|dependency_path|
      let dependency_root = (
        find-repo-root (resolve-repo-path $repo_root $dependency_path)
      )

      if (($dependency_root | describe) == 'string') and ($dependency_root != $repo_root) and (($dependency_root | path join "devenv.yaml") | path exists) {
        $dependency_root
      }
    }
  | compact
  | uniq
  | sort
}

def refresh-generated-files [repo_root: path]: nothing -> nothing {
  do {
    cd $repo_root
    ^devenv tasks --no-tui --no-eval-cache --refresh-eval-cache run devenv:files | ignore
  }
}

def latest-shell-export [repo_root: path]: nothing -> oneof<path, nothing> {
  let shell_glob = ((resolve-repo-path $repo_root ".devenv") | path join "shell-*.sh")
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
    return
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
    fail $"expected devenv shell export under (($repo_root | path expand --no-symlink) | path join '.devenv')"
  }

  {
    shell_export_path: $refreshed_export
    shell_export_refreshed: true
  }
}

def bootstrap-recursive [spec: record root_repo_root: path repo_root: path visited_roots: list<string>]: nothing -> record {
  let normalized_repo_root = ($repo_root | path expand --no-symlink)
  let root_repo_root = ($root_repo_root | path expand --no-symlink)

  if $normalized_repo_root in $visited_roots {
    return {
      status: null
      visited_roots: $visited_roots
    }
  }

  let visited_roots = ($visited_roots | append $normalized_repo_root)
  let root_status = sync-local-overrides ($spec | merge { repo_root: $normalized_repo_root })
  let local_repo_roots = (
    $root_status.local_repo_roots
    | default []
    | where {|path| (($path | describe) == 'string') and (not ($path | is-empty)) }
    | each {|path| $path | path expand --no-symlink }
  )
  let cargo_repo_roots = list-cargo-dependency-repo-roots $normalized_repo_root
  let dependency_repo_roots = (
    [
      $local_repo_roots
      $cargo_repo_roots
    ]
    | flatten
    | uniq
    | sort
  )
  mut recursion_state = {
    status: $root_status
    visited_roots: $visited_roots
  }
  mut generated_files_refreshed = false

  for dependency_repo_root in $dependency_repo_roots {
    if $dependency_repo_root == $normalized_repo_root {
      continue
    }

    $recursion_state = bootstrap-recursive $spec $root_repo_root $dependency_repo_root $recursion_state.visited_roots
  }

  if (managed-cargo-refresh-needed $normalized_repo_root) {
    refresh-generated-files $normalized_repo_root
    $generated_files_refreshed = true
  }

  if ($normalized_repo_root == $root_repo_root) and (sync-needs-refresh $root_status) {
    do {
      cd $normalized_repo_root
      ^devenv update | ignore
    }
  }

  let shell_export_status = if $normalized_repo_root == $root_repo_root {
    # Dependents only need their local overrides and generated files refreshed.
    # The caller is the only repo that needs a guaranteed reusable shell export.
    ensure-shell-export $normalized_repo_root ($generated_files_refreshed or (sync-needs-refresh $root_status))
  } else {
    {
      shell_export_path: null
      shell_export_refreshed: false
    }
  }

  {
    status: (
      $root_status
      | merge {
          generated_files_refreshed: $generated_files_refreshed
        }
      | merge $shell_export_status
    )
    visited_roots: $recursion_state.visited_roots
  }
}

def bootstrap-target-repo-roots [spec: record]: nothing -> list<path> {
  let spec = normalize-sync-spec $spec
  let repo_root = ($spec.repo_root | path expand --no-symlink)
  let polyrepo_root = resolve-polyrepo-root $repo_root $spec.polyrepo_root $spec.repo_dirs_path
  let repo_dirs_root = resolve-repo-dirs-root $polyrepo_root $spec.repo_dirs_path

  list-local-repo-paths $repo_dirs_root [] []
  | values
  | each {|path| $path | path expand --no-symlink }
  | sort
}

export def render-local-overrides [spec: record]: nothing -> string {
  render-normalized-overrides (normalize-render-spec $spec)
}

export def sync-local-overrides [spec: record]: nothing -> record {
  let spec = normalize-sync-spec $spec
  let repo_root = ($spec.repo_root | path expand --no-symlink)
  let source_yaml_path = resolve-repo-path $repo_root $spec.source_path
  let output_yaml_path = resolve-repo-path $repo_root $spec.output_path
  let lock_path = (resolve-repo-path $repo_root "devenv.lock")
  let polyrepo_root = resolve-polyrepo-root $repo_root $spec.polyrepo_root $spec.repo_dirs_path
  let repo_dirs_root = resolve-repo-dirs-root $polyrepo_root $spec.repo_dirs_path

  let source_yaml_text = open --raw $source_yaml_path
  let global_inputs_yaml_path = ($polyrepo_root | path join (global-inputs-basename))
  let global_inputs_yaml_text = if ($global_inputs_yaml_path | path exists) {
    open --raw $global_inputs_yaml_path
  } else {
    ""
  }

  # Recursive scans only reuse the same repo-relative source path in sibling
  # repos. Absolute or unrelated paths intentionally disable that recursion.
  let source_relative_path = maybe-relativize $source_yaml_path $repo_root
  let local_repo_paths = list-local-repo-paths $repo_dirs_root $spec.include_repos $spec.exclude_repos
  let repo_names = ($local_repo_paths | columns | sort)
  let repo_sources = load-repo-sources $local_repo_paths $source_relative_path
  let rendered = build-overrides $source_yaml_text $global_inputs_yaml_text $repo_names $local_repo_paths $repo_sources $spec.include_inputs $spec.exclude_inputs $repo_dirs_root $spec.url_scheme
  let overrides_text = render-overrides-text $rendered.overrides $rendered.imports
  let local_repo_roots = (
    $rendered.local_repo_names
    | each {|repo_name| $local_repo_paths | get $repo_name }
  )
  let local_repo_names = $rendered.local_repo_names
  let local_repo_count = ($local_repo_names | length)

  let existing_text = if ($output_yaml_path | path exists) {
    open --raw $output_yaml_path
  }
  mut mode = "unchanged"

  if $overrides_text == "" {
    if ($existing_text | describe) == 'string' {
      rm --force $output_yaml_path
      $mode = "removed"
    }
  } else if $existing_text != $overrides_text {
    rm --force $output_yaml_path
    $overrides_text | save --force $output_yaml_path
    $mode = "written"
  }

  # Lock drift matters even when the YAML itself is unchanged, because the root
  # lock node controls which inputs are actually available during evaluation.
  let lock_status = lock-status $output_yaml_path $lock_path

  {
    output_path: $output_yaml_path
    mode: $mode
    changed: ($mode != "unchanged")
    removed: ($mode == "removed")
    local_repo_names: $local_repo_names
    local_repo_roots: $local_repo_roots
    local_repo_count: $local_repo_count
    lock_status: $lock_status
    lock_refresh_needed: (not $lock_status.clean)
  }
}

export def bootstrap [spec: record]: nothing -> record {
  let spec = normalize-sync-spec $spec
  let repo_root = ($spec.repo_root | path expand --no-symlink)

  (bootstrap-recursive $spec $repo_root $repo_root []).status
}

export def bootstrap-all [spec: record]: nothing -> record {
  let spec = normalize-sync-spec $spec
  let repo_roots = bootstrap-target-repo-roots $spec
  let results = (
    $repo_roots
    | each {|repo_root|
        try {
          {
            repo_root: $repo_root
            ok: true
            status: (bootstrap ($spec | merge { repo_root: $repo_root }))
            error: null
          }
        } catch {|err|
          {
            repo_root: $repo_root
            ok: false
            status: null
            error: $err.msg
          }
        }
      }
  )
  let failures = ($results | where ok == false)

  let summary = {
    repo_count: ($repo_roots | length)
    success_count: ($results | where ok == true | length)
    failure_count: ($failures | length)
    results: $results
  }

  if not ($failures | is-empty) {
    error make {
      # Callers such as `bin/bootstrap-repo.nu --json` re-emit this structured
      # payload so automation can inspect partial successes before exiting.
      msg: $"bootstrap failed for ($summary.failure_count) repos"
      results: $results
      summary: $summary
    }
  }

  $summary
}

export def render-manifest-file [manifest_path: path]: nothing -> string {
  render-normalized-overrides (parse-render-manifest $manifest_path)
}

export def lock-status [output_path: path lock_path: path]: nothing -> oneof<record, error> {
  if not ($output_path | path exists) {
    return (make-lock-status "clean")
  }

  let local_doc = parse-top-level-mapping $output_path (open --raw $output_path)
  let desired_inputs = ($local_doc | get -o inputs | default {})

  if (($desired_inputs | describe) !~ '^record') {
    fail $"expected `inputs` to be a mapping in ($output_path)"
  }

  if ($desired_inputs | columns | is-empty) {
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

  for input_name in ($desired_inputs | columns) {
    if not ($input_name in ($root_inputs | columns)) {
      return (make-lock-status "missing-root-input" $input_name)
    }

    let input_spec = ($desired_inputs | get $input_name)
    let url = ($input_spec | get -o url)

    if ($url | describe) != 'string' {
      continue
    }

    let expected_path = match (path-from-url $url) {
      null => { continue }
      $expected_path => { $expected_path }
    }

    let node_name = ($root_inputs | get $input_name)
    let node = if (($node_name | describe) == 'string') and ($node_name in ($nodes | columns)) {
      $nodes | get $node_name
    } else {
      {}
    }
    let locked_path = ($node | get -o locked | default {} | get -o path)
    let original_path = ($node | get -o original | default {} | get -o path)

    if $expected_path not-in [ $locked_path $original_path ] {
      return (make-lock-status "stale-path" $input_name)
    }
  }

  make-lock-status "clean"
}
