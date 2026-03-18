use sources.nu [repo-dirs-path-from-polyrepo-manifest repo-paths-from-polyrepo-manifest repo-records-from-polyrepo-manifest]
use support.nu [fail polyrepo-manifest-basename]

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

export def resolve-repo-dirs-root [polyrepo_root: path repo_dirs_path: path]: nothing -> path {
  resolve-repo-path $polyrepo_root $repo_dirs_path
}

def polyrepo-manifest-path [polyrepo_root: path]: nothing -> path {
  ($polyrepo_root | path join (polyrepo-manifest-basename))
}

def is-repo-root [path_value: path]: nothing -> bool {
  let git_path = ($path_value | path join ".git")
  let devenv_yaml = ($path_value | path join "devenv.yaml")

  ($git_path | path exists) or ($devenv_yaml | path exists)
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

export def find-polyrepo-root [repo_root: path]: nothing -> oneof<path, nothing> {
  let repo_root = ($repo_root | path expand --no-symlink)
  mut current = $repo_root

  while true {
    let manifest_path = (polyrepo-manifest-path $current)

    if ($manifest_path | path exists) {
      let current_root = $current
      let manifest_label = $"polyrepo manifest '($manifest_path)'"
      let manifest_text = open --raw $manifest_path
      let repo_catalog_paths = (
        repo-paths-from-polyrepo-manifest $manifest_label $manifest_text
        | each {|repo_path| resolve-repo-path $current_root $repo_path }
      )

      if $repo_root in $repo_catalog_paths {
        return $current
      }
    }

    let parent = ($current | path dirname)
    if $parent == $current {
      return null
    }

    $current = $parent
  }
}

export def resolve-polyrepo-root [repo_root: path polyrepo_root: any repo_dirs_path: any]: nothing -> oneof<path, error> {
  if ($polyrepo_root | describe) == 'string' {
    return (resolve-repo-path $repo_root $polyrepo_root)
  }

  let manifest_root = find-polyrepo-root $repo_root

  if (($manifest_root | describe) == 'string') {
    return $manifest_root
  }

  fail $"polyrepo root could not be inferred for repo root (($repo_root | path expand --no-symlink)); searched ancestor (polyrepo-manifest-basename) files for a repos entry that resolves to this repo. Pass --polyrepo-root explicitly or add this repo to the manifest repo catalog."
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

export def list-local-repo-paths [polyrepo_root: path repo_dirs_root: path include_repos: list<string> exclude_repos: list<string>]: nothing -> record {
  let manifest_path = (polyrepo-manifest-path $polyrepo_root)

  if not ($manifest_path | path exists) {
    fail $"expected (polyrepo-manifest-basename) at ($polyrepo_root)"
  }

  let manifest_label = $"polyrepo manifest '($manifest_path)'"
  let manifest_text = open --raw $manifest_path
  let declared_repo_roots = (
    repo-records-from-polyrepo-manifest $manifest_label $manifest_text
    | items {|resolved_name, repo_entry|
        let resolved_path = resolve-repo-path $polyrepo_root ($repo_entry | get path)
        let relative_path = maybe-relativize $resolved_path $repo_dirs_root

        if (($relative_path | describe) == 'nothing') {
          fail $"repo '($resolved_name)' at ($resolved_path) is outside repoDirsPath rooted at ($repo_dirs_root)"
        }

        if not (is-repo-root $resolved_path) {
          fail $"repo '($resolved_name)' at ($resolved_path) is not a repo root"
        }

        {
          name: $resolved_name
          path: $resolved_path
        }
      }
  )

  let filtered = (
    $declared_repo_roots
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
    fail $"multiple local repos share the same manifest name under ($repo_dirs_root): ($duplicate_list)"
  }

  $filtered
  | sort-by name
  | each {|repo| [$repo.name (($repo.path | path expand --no-symlink) | into string)] }
  | into record
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
