#!/usr/bin/env nu

const global_inputs_basename = ".devenv-global-inputs.yaml"

def fail [message: string] {
  error make --unspanned $message
}

def normalize-yaml-value [value: any] {
  match ($value | describe) {
    $t if $t =~ '^record' => {
      $value
      | items {|key, item| [$key (normalize-yaml-value $item)] }
      | into record
    }
    $t if $t =~ '^list' => { $value | each {|item| normalize-yaml-value $item } }
    _ => { $value }
  }
}

def parse-top-level-mapping [source_label: string yaml_text: string] {
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

  normalize-yaml-value $parsed
}

def get-inputs-block [source_label: string yaml_text: string] {
  let parsed = parse-top-level-mapping $source_label $yaml_text
  let inputs_block = ($parsed | get -o inputs | default {})

  if (($inputs_block | describe) !~ '^record') {
    fail $"expected `inputs` to be a mapping in ($source_label)"
  }

  $inputs_block
}

def get-input-names [source_label: string yaml_text: string] {
  get-inputs-block $source_label $yaml_text | columns
}

def get-imports-list [source_label: string yaml_text: string] {
  let parsed = parse-top-level-mapping $source_label $yaml_text
  let imports_list = ($parsed | get -o imports | default [])

  if (($imports_list | describe) !~ '^list') {
    fail $"expected `imports` to be a list in ($source_label)"
  }

  $imports_list
  | each {|item|
      if (($item | describe) != 'string') or ($item | is-empty) {
        fail $"expected `imports` entries to be non-empty strings in ($source_label)"
      }

      $item
    }
}

def get-import-input-name [import_name: string] {
  if (
    $import_name | str starts-with "path:"
  ) or (
    $import_name | str starts-with "/"
  ) or (
    $import_name | str starts-with "./"
  ) or (
    $import_name | str starts-with "../"
  ) {
    return null
  }

  $import_name | split row "/" | first | into string
}

def repo-name-from-url [url: string] {
  let without_query = ($url | split row "?" | first)
  let without_fragment = ($without_query | split row "#" | first)
  let without_git_prefix = if ($without_fragment | str starts-with "git+") {
    $without_fragment | str substring 4..
  } else {
    $without_fragment
  }
  let without_github_prefix = if ($without_git_prefix | str starts-with "github:") {
    $without_git_prefix | str substring 7..
  } else if ($without_git_prefix | str contains "github.com/") {
    $without_git_prefix | split row "github.com/" | last
  } else {
    $without_git_prefix
  }
  let without_trailing_slash = ($without_github_prefix | str trim --right --char "/")
  let without_git_suffix = if ($without_trailing_slash | str ends-with ".git") {
    $without_trailing_slash | str substring ..<(-4)
  } else {
    $without_trailing_slash
  }
  let parts = ($without_git_suffix | split row "/" | where {|part| $part != "" })

  if ($parts | is-empty) {
    null
  } else {
    $parts | last | into string
  }
}

def read-input-spec [input_spec: any] {
  match ($input_spec | describe) {
    $t if $t =~ '^record' => {
      let url = ($input_spec | get -o url)

      if (($url | describe) == 'string') and (not ($url | is-empty)) {
        {
          url: $url
          spec: $input_spec
        }
      } else {
        null
      }
    }
    "string" => {
      if ($input_spec | is-empty) {
        null
      } else {
        {
          url: $input_spec
          spec: {}
        }
      }
    }
    _ => { null }
  }
}

def read-json-list [json_path: string message: string] {
  let parsed = try {
    open --raw $json_path | from json | default []
  } catch {
    fail $message
  }

  if (($parsed | describe) !~ '^list') {
    fail $message
  }

  $parsed
  | where {|item| (($item | describe) == 'string') and (not ($item | is-empty)) }
  | uniq
}

def read-repo-sources [json_path: string] {
  let parsed = try {
    open --raw $json_path | from json | default {}
  } catch {
    fail "expected repo sources JSON to be a mapping"
  }

  if (($parsed | describe) !~ '^record') {
    fail "expected repo sources JSON to be a mapping"
  }

  $parsed
  | items {|repo_name, yaml_text|
      if (($yaml_text | describe) == 'string') and (not ($repo_name | is-empty)) {
        [$repo_name $yaml_text]
      }
    }
  | compact
  | into record
}

def fail-on-overlap [first_names: list<string> second_names: list<string> first_label: string second_label: string] {
  let overlap = (
    $first_names
    | where {|name| $name in $second_names }
    | uniq
    | sort
  )

  if not ($overlap | is-empty) {
    fail $"($first_label) and ($second_label) must not overlap: ($overlap | str join ', ')"
  }
}

def add-override [overrides: record input_name: string copied_spec: record source_label: string] {
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

def sort-record [value: record] {
  $value
  | columns
  | sort
  | each {|column| [$column ($value | get $column)] }
  | into record
}

def build-overrides [
  source_yaml_text: string
  global_inputs_yaml_text: string
  local_repo_names: list<string>
  repo_sources: record
  include_inputs: list<string>
  exclude_inputs: list<string>
  repo_dirs_root: string
  url_scheme: string
] {
  let url_prefix = if $url_scheme == "git+file" {
    "git+file:"
  } else {
    "path:"
  }

  mut overrides = {}
  mut rendered_imports = []
  mut visited_repo_names = []
  let root_input_names = get-input-names "root source" $source_yaml_text
  mut global_imports = []
  mut pending_sources = [
    {
      source_label: "root source"
      yaml_text: $source_yaml_text
      blocked_input_names: []
    }
  ]

  if ($global_inputs_yaml_text | str trim) != "" {
    $global_imports = get-imports-list $"global inputs '($global_inputs_basename)'" $global_inputs_yaml_text
    $pending_sources = (
      $pending_sources
      | append {
          source_label: $"global inputs '($global_inputs_basename)'"
          yaml_text: $global_inputs_yaml_text
          blocked_input_names: $root_input_names
        }
    )
  }

  loop {
    if ($pending_sources | is-empty) {
      break
    }

    let current = ($pending_sources | first)
    $pending_sources = ($pending_sources | skip 1)

    let inputs_block = get-inputs-block $current.source_label $current.yaml_text

    for input_name in ($inputs_block | columns | each {|name| $name | into string }) {
      if $input_name in $current.blocked_input_names {
        continue
      }

      if (not ($include_inputs | is-empty)) and (not ($input_name in $include_inputs)) {
        continue
      }

      if $input_name in $exclude_inputs {
        continue
      }

      let input_spec = read-input-spec ($inputs_block | get $input_name)

      if ($input_spec | describe) == 'nothing' {
        continue
      }

      let repo_name = repo-name-from-url $input_spec.url

      if (($repo_name | describe) == 'nothing') or (not ($repo_name in $local_repo_names)) {
        continue
      }

      let local_repo_path = ($repo_dirs_root | path join $repo_name)
      let copied_spec = ($input_spec.spec | merge { url: $"($url_prefix)($local_repo_path)" })
      $overrides = add-override $overrides $input_name $copied_spec $current.source_label

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

  for import_name in $global_imports {
    let import_input_name = (get-import-input-name $import_name | default $import_name)

    if (not ($include_inputs | is-empty)) and (not ($import_input_name in $include_inputs)) {
      continue
    }

    if $import_input_name in $exclude_inputs {
      continue
    }

    if $import_input_name in $effective_input_names {
      $rendered_imports = ($rendered_imports | append $import_name | uniq)
    }
  }

  {
    overrides: $overrides
    imports: $rendered_imports
  }
}

def render-overrides-text [overrides: record imports_list: list<string>] {
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

def resolve-repo-path [repo_root: string candidate_path: string] {
  if ($candidate_path | str starts-with "/") {
    $candidate_path | path expand
  } else {
    ($repo_root | path join $candidate_path) | path expand
  }
}

def normalize-segments [path: string] {
  $path | split row "/" | where {|segment| ($segment != "") and ($segment != ".") }
}

def dirname-n [levels: int path: string] {
  mut current = $path
  mut remaining = $levels

  while $remaining > 0 {
    $current = ($current | path dirname)
    $remaining = ($remaining - 1)
  }

  $current
}

def resolve-repo-dirs-root [polyrepo_root: string repo_dirs_path: string] {
  if ($repo_dirs_path | str starts-with "/") {
    $repo_dirs_path | path expand
  } else {
    ($polyrepo_root | path join $repo_dirs_path) | path expand
  }
}

def infer-polyrepo-root [repo_root: string repo_dirs_path: string] {
  if ($repo_dirs_path | str starts-with "/") {
    return null
  }

  let repo_root = ($repo_root | path expand)
  let repo_parent = ($repo_root | path dirname)
  let repo_dirs_segments = normalize-segments $repo_dirs_path
  let repo_dirs_parent = dirname-n ($repo_dirs_segments | length) $repo_parent
  let candidate_repo_dirs_root = if ($repo_dirs_segments | is-empty) {
    $repo_dirs_parent
  } else {
    ($repo_dirs_parent | path join $repo_dirs_path) | path expand
  }

  if $repo_parent == $candidate_repo_dirs_root {
    $repo_dirs_parent
  } else {
    null
  }
}

def resolve-polyrepo-root [repo_root: string polyrepo_root: any repo_dirs_path: string] {
  if ($polyrepo_root | describe) == 'string' {
    return (resolve-repo-path $repo_root $polyrepo_root)
  }

  let inferred = infer-polyrepo-root $repo_root $repo_dirs_path

  if ($inferred | describe) == 'nothing' {
    fail "polyrepo root could not be inferred; pass --polyrepo-root when the current repo is not nested under --repo-dirs-path"
  }

  $inferred
}

def maybe-relativize [path: string root: string] {
  let root = ($root | path expand)
  let path = ($path | path expand)
  let root_prefix = $"($root)/"

  if $path == $root {
    "."
  } else if ($path | str starts-with $root_prefix) {
    $path | str substring ($root_prefix | str length)..
  } else {
    null
  }
}

def list-local-repo-names [repo_dirs_root: string include_repos: list<string> exclude_repos: list<string>] {
  let repo_entries = if ($repo_dirs_root | path exists) {
    ls $repo_dirs_root
  } else {
    []
  }

  $repo_entries
  | where type == dir
  | get name
  | each {|path| $path | path basename }
  | where {|repo_name|
      (($include_repos | is-empty) or ($repo_name in $include_repos)) and (not ($repo_name in $exclude_repos))
    }
  | uniq
  | sort
}

def load-repo-sources [repo_dirs_root: string repo_names: list<string> source_relative_path: any] {
  if ($source_relative_path | describe) == 'nothing' {
    return {}
  }

  $repo_names
  | each {|repo_name|
      let nested_path = ($repo_dirs_root | path join $repo_name | path join $source_relative_path)

      if ($nested_path | path exists) {
        [$repo_name (open --raw $nested_path)]
      }
    }
  | compact
  | into record
}

def sync-local-overrides [
  repo_root: string
  source_path: string
  output_path: string
  polyrepo_root: any
  repo_dirs_path: string
  url_scheme: string
  include_repos: list<string>
  exclude_repos: list<string>
  include_inputs: list<string>
  exclude_inputs: list<string>
] {
  let repo_root = ($repo_root | path expand)
  let source_yaml_path = resolve-repo-path $repo_root $source_path
  let output_yaml_path = resolve-repo-path $repo_root $output_path
  let polyrepo_root = resolve-polyrepo-root $repo_root $polyrepo_root $repo_dirs_path
  let repo_dirs_root = resolve-repo-dirs-root $polyrepo_root $repo_dirs_path

  fail-on-overlap $include_repos $exclude_repos "included repos" "excluded repos"
  fail-on-overlap $include_inputs $exclude_inputs "included inputs" "excluded inputs"

  let source_yaml_text = open --raw $source_yaml_path
  let global_inputs_yaml_path = ($polyrepo_root | path join $global_inputs_basename)
  let global_inputs_yaml_text = if ($global_inputs_yaml_path | path exists) {
    open --raw $global_inputs_yaml_path
  } else {
    ""
  }

  let source_relative_path = maybe-relativize $source_yaml_path $repo_root
  let repo_names = list-local-repo-names $repo_dirs_root $include_repos $exclude_repos
  let repo_sources = load-repo-sources $repo_dirs_root $repo_names $source_relative_path
  let rendered = build-overrides $source_yaml_text $global_inputs_yaml_text $repo_names $repo_sources $include_inputs $exclude_inputs $repo_dirs_root $url_scheme
  let overrides_text = render-overrides-text $rendered.overrides $rendered.imports

  if $overrides_text == "" {
    rm --force $output_yaml_path
    return null
  }

  let existing_text = if ($output_yaml_path | path exists) {
    open --raw $output_yaml_path
  } else {
    null
  }

  if $existing_text != $overrides_text {
    rm --force $output_yaml_path
    $overrides_text | save --force $output_yaml_path
  }

  null
}

def run-generator-mode [
  source_yaml_path: string
  local_repo_names_path: string
  repo_sources_json_path: string
  global_inputs_yaml_path: string
  include_inputs_json_path: string
  exclude_inputs_json_path: string
  repo_dirs_root: string
  url_scheme: string
] {
  let source_yaml_text = open --raw $source_yaml_path
  let global_inputs_yaml_text = open --raw $global_inputs_yaml_path
  let local_repo_names = read-json-list $local_repo_names_path "expected local repo names JSON to be a list"
  let repo_sources = read-repo-sources $repo_sources_json_path
  let include_inputs = read-json-list $include_inputs_json_path "expected included inputs JSON to be a list"
  let exclude_inputs = read-json-list $exclude_inputs_json_path "expected excluded inputs JSON to be a list"

  fail-on-overlap $include_inputs $exclude_inputs "included inputs" "excluded inputs"

  let rendered = build-overrides $source_yaml_text $global_inputs_yaml_text $local_repo_names $repo_sources $include_inputs $exclude_inputs $repo_dirs_root $url_scheme
  render-overrides-text $rendered.overrides $rendered.imports
}

def path-from-url [url: string] {
  if ($url | str starts-with "path:") {
    $url | str substring 5..
  } else if ($url | str starts-with "git+file:") {
    $url | str substring 9..
  } else {
    null
  }
}

def lock-status [output_path: string lock_path: string] {
  if not ($output_path | path exists) {
    return "clean"
  }

  let local_doc = parse-top-level-mapping $output_path (open --raw $output_path)
  let desired_inputs = ($local_doc | get -o inputs | default {})

  if (($desired_inputs | describe) !~ '^record') {
    fail $"expected `inputs` to be a mapping in ($output_path)"
  }

  if ($desired_inputs | columns | is-empty) {
    return "clean"
  }

  if not ($lock_path | path exists) {
    return "missing-lock"
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

  for input_name in ($desired_inputs | columns | each {|name| $name | into string }) {
    if not ($input_name in ($root_inputs | columns)) {
      return $"missing-root-input:($input_name)"
    }

    let input_spec = ($desired_inputs | get $input_name)
    let url = ($input_spec | get -o url)

    if ($url | describe) != 'string' {
      continue
    }

    let expected_path = path-from-url $url

    if ($expected_path | describe) == 'nothing' {
      continue
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
      return $"stale-path:($input_name)"
    }
  }

  "clean"
}

def parse-repeatable-sync-flags [args: list<string>] {
  mut include_repos = []
  mut exclude_repos = []
  mut include_inputs = []
  mut exclude_inputs = []
  mut index = 0

  while $index < ($args | length) {
    let arg = ($args | get $index)

    match $arg {
      "--include-repo" | "-i" => {
        $index = ($index + 1)
        if $index >= ($args | length) {
          fail $"($arg) requires a value"
        }
        $include_repos = ($include_repos | append ($args | get $index))
      }
      "--exclude-repo" | "-x" => {
        $index = ($index + 1)
        if $index >= ($args | length) {
          fail $"($arg) requires a value"
        }
        $exclude_repos = ($exclude_repos | append ($args | get $index))
      }
      "--include-input" | "-I" => {
        $index = ($index + 1)
        if $index >= ($args | length) {
          fail $"($arg) requires a value"
        }
        $include_inputs = ($include_inputs | append ($args | get $index))
      }
      "--exclude-input" | "-X" => {
        $index = ($index + 1)
        if $index >= ($args | length) {
          fail $"($arg) requires a value"
        }
        $exclude_inputs = ($exclude_inputs | append ($args | get $index))
      }
      _ => {
        fail $"unknown sync flag: ($arg)"
      }
    }

    $index = ($index + 1)
  }

  {
    include_repos: ($include_repos | uniq)
    exclude_repos: ($exclude_repos | uniq)
    include_inputs: ($include_inputs | uniq)
    exclude_inputs: ($exclude_inputs | uniq)
  }
}

# Generate local input overrides for sibling repos.
#
# Use `main sync` for normal repo updates, `main generate` for Nix builders,
# and `main lock-status` for bootstrap lockfile drift checks.
def main [] {
  help main
}

# Generate local input overrides from builder inputs.
#
# This subcommand is the structured interface used by the Nix module during
# evaluation-friendly render steps.
def "main generate" [
  source_yaml_path: string         # Root devenv YAML file to scan.
  local_repo_names_path: string    # JSON file containing local repo directory names.
  repo_sources_json_path: string   # JSON mapping of repo names to nested source YAML text.
  global_inputs_yaml_path: string  # YAML file containing shared global inputs.
  include_inputs_json_path: string # JSON list of allowed input names.
  exclude_inputs_json_path: string # JSON list of blocked input names.
  repo_dirs_root: string           # Directory containing sibling repos.
  url_scheme: string               # Override URL scheme: path or git+file.
] {
  run-generator-mode $source_yaml_path $local_repo_names_path $repo_sources_json_path $global_inputs_yaml_path $include_inputs_json_path $exclude_inputs_json_path $repo_dirs_root $url_scheme
}

# Sync local input overrides into a repo checkout.
#
# Repeat `--include-repo`/`-i`, `--exclude-repo`/`-x`,
# `--include-input`/`-I`, and `--exclude-input`/`-X` as needed.
# Use `sync --help` to view the documented signature even though those
# repeatable filters are parsed from the wrapped rest arguments.
def --wrapped "main sync" [
  repo_root?: string              # Consumer repo root. Defaults to `.`.
  --source-path (-s): string      # Source YAML path inside the consumer repo.
  --output-path (-o): string      # Generated override YAML path inside the consumer repo.
  --polyrepo-root (-p): string    # Explicit polyrepo root when inference is not possible.
  --repo-dirs-path (-r): string   # Path to the sibling repo directory.
  --url-scheme (-u): string       # Override URL scheme: path or git+file.
  ...rest: string                 # Repeatable include/exclude filters.
] {
  if ('--help' in $rest) or ('-h' in $rest) or ($repo_root == '--help') or ($repo_root == '-h') {
    return (help main sync)
  }

  let parsed = parse-repeatable-sync-flags $rest
  let repo_root = ($repo_root | default ".")
  let source_path = ($source_path | default "devenv.yaml")
  let output_path = ($output_path | default "devenv.local.yaml")
  let repo_dirs_path = ($repo_dirs_path | default "repos")
  let url_scheme = ($url_scheme | default "path")

  if $url_scheme not-in [ "path" "git+file" ] {
    fail $"--url-scheme must be one of: path, git+file (got '($url_scheme)')"
  }

  sync-local-overrides $repo_root $source_path $output_path $polyrepo_root $repo_dirs_path $url_scheme $parsed.include_repos $parsed.exclude_repos $parsed.include_inputs $parsed.exclude_inputs
}

# Report whether devenv.local.yaml and devenv.lock are aligned.
#
# This is used by the bootstrap wrapper to decide when `devenv update` is
# required after local override generation.
def "main lock-status" [
  output_path: string # Generated devenv.local.yaml path.
  lock_path: string   # devenv.lock path to compare against.
] {
  lock-status $output_path $lock_path
}
