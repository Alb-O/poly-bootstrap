use support.nu [fail]

export def get-import-input-name [import_name: string]: nothing -> oneof<string, nothing> {
  if ([ "path:" "/" "./" "../" ] | any {|prefix| $import_name | str starts-with $prefix }) {
    return null
  }

  $import_name | split row "/" | first | into string
}

export def repo-name-from-url [url: string]: nothing -> oneof<string, nothing> {
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

export def resolve-repo-path [repo_root: path candidate_path: path]: nothing -> path {
  if ($candidate_path | str starts-with "/") {
    $candidate_path | path expand --no-symlink
  } else {
    ($repo_root | path join $candidate_path) | path expand --no-symlink
  }
}

def normalize-segments [path_value: path]: nothing -> list<string> {
  $path_value | split row "/" | where {|segment| ($segment != "") and ($segment != ".") }
}

def dirname-n [levels: int path_value: path]: nothing -> path {
  mut current = $path_value
  mut remaining = $levels

  while $remaining > 0 {
    $current = ($current | path dirname)
    $remaining = ($remaining - 1)
  }

  $current
}

export def resolve-repo-dirs-root [polyrepo_root: path repo_dirs_path: path]: nothing -> path {
  resolve-repo-path $polyrepo_root $repo_dirs_path
}

def is-repo-root [path_value: path]: nothing -> bool {
  let git_path = ($path_value | path join ".git")
  let devenv_yaml = ($path_value | path join "devenv.yaml")

  ($git_path | path exists) or ($devenv_yaml | path exists)
}

def infer-polyrepo-root [repo_root: path repo_dirs_path: path]: nothing -> oneof<path, nothing> {
  if ($repo_dirs_path | str starts-with "/") {
    return null
  }

  let repo_root = ($repo_root | path expand --no-symlink)
  let repo_parent = ($repo_root | path dirname)
  let repo_grandparent = ($repo_parent | path dirname)
  let repo_dirs_segments = normalize-segments $repo_dirs_path
  let direct_polyrepo_root = dirname-n (($repo_dirs_segments | length) + 1) $repo_root
  let grouped_polyrepo_root = dirname-n (($repo_dirs_segments | length) + 2) $repo_root
  let direct_candidate_repo_dirs_root = if ($repo_dirs_segments | is-empty) {
    $direct_polyrepo_root
  } else {
    ($direct_polyrepo_root | path join $repo_dirs_path) | path expand --no-symlink
  }
  let grouped_candidate_repo_dirs_root = if ($repo_dirs_segments | is-empty) {
    $grouped_polyrepo_root
  } else {
    ($grouped_polyrepo_root | path join $repo_dirs_path) | path expand --no-symlink
  }

  # Inference is valid when the current repo lives directly under the configured
  # repo-dirs root, or one group-directory below it, e.g.
  # `<polyrepo>/<repoDirsPath>/<repo>` or `<polyrepo>/<repoDirsPath>/<group>/<repo>`.
  if $repo_parent == $direct_candidate_repo_dirs_root {
    return $direct_polyrepo_root
  }

  if $repo_grandparent == $grouped_candidate_repo_dirs_root {
    return $grouped_polyrepo_root
  }
}

export def resolve-polyrepo-root [repo_root: path polyrepo_root: any repo_dirs_path: path]: nothing -> oneof<path, error> {
  if ($polyrepo_root | describe) == 'string' {
    return (resolve-repo-path $repo_root $polyrepo_root)
  }

  let inferred = infer-polyrepo-root $repo_root $repo_dirs_path

  if ($inferred | describe) == 'nothing' {
    fail "polyrepo root could not be inferred; pass --polyrepo-root when the current repo is not nested under --repo-dirs-path"
  }

  $inferred
}

export def maybe-relativize [target_path: path root: path]: nothing -> oneof<path, nothing> {
  let root = ($root | path expand --no-symlink)
  let path = ($target_path | path expand --no-symlink)
  let root_prefix = $"($root)/"

  if $path == $root {
    "."
  } else if ($path | str starts-with $root_prefix) {
    $path | str substring ($root_prefix | str length)..
  }
}

export def list-local-repo-paths [repo_dirs_root: path include_repos: list<string> exclude_repos: list<string>]: nothing -> record {
  let repo_entries = if ($repo_dirs_root | path exists) { ls $repo_dirs_root } else { [] }
  mut repo_roots = []

  for entry in ($repo_entries | where type == dir) {
    let direct_path = ($entry | get name)

    if (is-repo-root $direct_path) {
      $repo_roots = ($repo_roots | append { name: ($direct_path | path basename), path: $direct_path })
      continue
    }

    let nested_entries = if ($direct_path | path exists) { ls $direct_path } else { [] }

    for nested_entry in ($nested_entries | where type == dir) {
      let nested_path = ($nested_entry | get name)

      if (is-repo-root $nested_path) {
        $repo_roots = ($repo_roots | append { name: ($nested_path | path basename), path: $nested_path })
      }
    }
  }

  let filtered = (
    $repo_roots
    | where {|repo|
        (($include_repos | is-empty) or ($repo.name in $include_repos)) and (not ($repo.name in $exclude_repos))
      }
  )
  let duplicate_names = (
    $filtered
    | group-by name
    | transpose name entries
    | where {|group| (($group.entries | length) > 1) }
  )

  if not ($duplicate_names | is-empty) {
    let duplicate_list = (
      $duplicate_names
      | each {|group| $group.name }
      | sort
      | str join ", "
    )
    fail $"multiple local repos share the same basename under ($repo_dirs_root): ($duplicate_list)"
  }

  $filtered
  | sort-by name
  | each {|repo| [$repo.name (($repo.path | path expand --no-symlink) | into string)] }
  | into record
}

export def list-local-repo-names [repo_dirs_root: path include_repos: list<string> exclude_repos: list<string>]: nothing -> list<string> {
  list-local-repo-paths $repo_dirs_root $include_repos $exclude_repos | columns | sort
}

export def load-repo-sources [local_repo_paths: record source_relative_path: any]: nothing -> record {
  if ($source_relative_path | describe) == 'nothing' {
    return {}
  }

  $local_repo_paths
  | transpose repo_name repo_root
  | each {|repo|
      let nested_path = ($repo.repo_root | path join $source_relative_path)

      if ($nested_path | path exists) {
        [$repo.repo_name (open --raw $nested_path)]
      }
    }
  | compact
  | into record
}

export def path-from-url [url: string]: nothing -> oneof<path, nothing> {
  if ($url | str starts-with "path:") {
    $url | str substring 5..
  } else if ($url | str starts-with "git+file:") {
    $url | str substring 9..
  }
}
