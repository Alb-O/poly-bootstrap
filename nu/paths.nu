use support.nu [fail]

export def get-import-input-name [import_name: string] {
  if ([ "path:" "/" "./" "../" ] | any {|prefix| $import_name | str starts-with $prefix }) {
    return null
  }

  $import_name | split row "/" | first | into string
}

export def repo-name-from-url [url: string] {
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

export def resolve-repo-path [repo_root: string candidate_path: string] {
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

export def resolve-repo-dirs-root [polyrepo_root: string repo_dirs_path: string] {
  resolve-repo-path $polyrepo_root $repo_dirs_path
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

  # Inference is only valid when the current repo really lives immediately under
  # the configured repo-dirs root, e.g. `<polyrepo>/<repoDirsPath>/<repo>`.
  if $repo_parent == $candidate_repo_dirs_root {
    $repo_dirs_parent
  } else {
    null
  }
}

export def resolve-polyrepo-root [repo_root: string polyrepo_root: any repo_dirs_path: string] {
  if ($polyrepo_root | describe) == 'string' {
    return (resolve-repo-path $repo_root $polyrepo_root)
  }

  let inferred = infer-polyrepo-root $repo_root $repo_dirs_path

  if ($inferred | describe) == 'nothing' {
    fail "polyrepo root could not be inferred; pass --polyrepo-root when the current repo is not nested under --repo-dirs-path"
  }

  $inferred
}

export def maybe-relativize [path: string root: string] {
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

export def list-local-repo-names [repo_dirs_root: string include_repos: list<string> exclude_repos: list<string>] {
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

export def load-repo-sources [repo_dirs_root: string repo_names: list<string> source_relative_path: any] {
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

export def path-from-url [url: string] {
  if ($url | str starts-with "path:") {
    $url | str substring 5..
  } else if ($url | str starts-with "git+file:") {
    $url | str substring 9..
  } else {
    null
  }
}
