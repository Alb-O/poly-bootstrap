def usage [cmd_name: string]: nothing -> string {
  $"Usage: ($cmd_name) <repo-path> \"commit message\" <file-or-glob> [more files/globs...]"
}

def print-stderr [text: string]: nothing -> nothing {
  print --stderr -n $text
}

def exit-with-message [message: string code: int]: nothing -> nothing {
  print-stderr $"($message)\n"
  exit $code
}

def trimmed-lines [text: string]: nothing -> list<string> {
  $text
  | lines
  | where {|line| $line != "" }
}

def git-complete [repo_path: path args: list<string>]: nothing -> record<stdout: string, stderr: string, exit_code: int> {
  do { ^git -C $repo_path ...$args } | complete
}

def git-lines [repo_path: path args: list<string>]: nothing -> list<string> {
  let result = (git-complete $repo_path $args)

  if $result.exit_code == 0 {
    trimmed-lines $result.stdout
  } else {
    []
  }
}

def pathspec-is-glob [pattern: string]: nothing -> bool {
  $pattern =~ `[\*\?\[]`
}

def git-pathspec [pattern: string]: nothing -> string {
  if (pathspec-is-glob $pattern) {
    (':(glob)' + $pattern)
  } else {
    $pattern
  }
}

def worktree-pattern-path [repo_path: path pattern: string]: nothing -> path {
  if ($pattern | str starts-with "/") {
    $pattern | path expand
  } else {
    [$repo_path $pattern] | path join | path expand
  }
}

def nested-git-worktree-path [candidate: path]: nothing -> bool {
  (
    ($candidate | path exists)
    and (($candidate | path type) == dir)
    and ([$candidate ".git"] | path join | path exists)
  )
}

def tracked-glob-has-live-match [repo_root: path tracked_paths: list<string>]: nothing -> bool {
  $tracked_paths
  | any {|tracked_path| ([ $repo_root $tracked_path ] | path join | path exists) }
}

def empty-selection []: nothing -> record<files: list<string>, initial_add_files: list<string>, initial_delete_files: list<string>, retry_add_files: list<string>> {
  {
    files: []
    initial_add_files: []
    initial_delete_files: []
    retry_add_files: []
  }
}

def select-pattern [
  repo_path: path
  repo_root: path
  selection: record<files: list<string>, initial_add_files: list<string>, initial_delete_files: list<string>, retry_add_files: list<string>>
  pattern: string
]: nothing -> record<files: list<string>, initial_add_files: list<string>, initial_delete_files: list<string>, retry_add_files: list<string>> {
  mut next = $selection

  # Normalize shell globs into git pathspec globs so the same selection logic
  # works whether the caller passes a literal file or a pattern.
  let pathspec = (git-pathspec $pattern)
  let pattern_is_glob = (pathspec-is-glob $pattern)
  let staged_matches = (git-lines $repo_path [diff --cached --name-only -- $pathspec])

  # Existing worktree paths still need `git add -A` so content changes, adds,
  # and deletions under the selected path are refreshed in the index first.
  let pattern_in_repo = (worktree-pattern-path $repo_path $pattern)
  # One exception: if the caller already has a staged deletion for a literal
  # path that now points at a nested Git worktree, keep that staged deletion and
  # skip `git add -A`. Re-adding such a path would stage the embedded repo
  # itself instead of preserving the selected gitlink removal.
  if (not $pattern_is_glob) and (not ($staged_matches | is-empty)) and (nested-git-worktree-path $pattern_in_repo) {
    $next.files = ($next.files | append $pathspec)
    return $next
  }

  if ($pattern_in_repo | path exists) {
    $next.files = ($next.files | append $pathspec)
    $next.initial_add_files = ($next.initial_add_files | append $pathspec)
    $next.retry_add_files = ($next.retry_add_files | append $pathspec)
    return $next
  }

  # Globs that match tracked paths need one more split: if any matched file
  # still exists in the worktree, use `git add -A` so content changes and
  # deletions refresh together. If all matches are already gone, expand the
  # glob to concrete tracked paths and treat it as a deletion-only selection so
  # later git commands do not see a dead directory glob.
  if $pattern_is_glob {
    let tracked_glob_matches = (git-lines $repo_path [ls-files --cached -- $pathspec])

    if not ($tracked_glob_matches | is-empty) {
      if (tracked-glob-has-live-match $repo_root $tracked_glob_matches) {
        $next.files = ($next.files | append $pathspec)
        $next.initial_add_files = ($next.initial_add_files | append $pathspec)
        $next.retry_add_files = ($next.retry_add_files | append $pathspec)
      } else {
        $next.files = ($next.files ++ $tracked_glob_matches)
        $next.initial_delete_files = ($next.initial_delete_files ++ $tracked_glob_matches)
      }

      return $next
    }
  }

  # Quoted globs should target new untracked files. Preserve the
  # glob pathspec so `git add -A` can stage them.
  if not ((git-lines $repo_path [ls-files --others --exclude-standard -- $pathspec]) | is-empty) {
    $next.files = ($next.files | append $pathspec)
    $next.initial_add_files = ($next.initial_add_files | append $pathspec)
    $next.retry_add_files = ($next.retry_add_files | append $pathspec)
    return $next
  }

  # Deleted tracked paths are valid selections too; `git ls-files` lets the
  # caller target them even though the path no longer exists on disk.
  #
  # Stage them once up front via `git rm --cached`, but do not include them in
  # later retry restages. `git add -A` rejects ignored pathspecs even when the
  # tracked file has been deleted, which breaks selected deletions once a path
  # has become ignored.
  let tracked_result = (git-complete $repo_path [ls-files --error-unmatch -- $pathspec])
  if $tracked_result.exit_code == 0 {
    $next.files = ($next.files | append $pathspec)
    $next.initial_delete_files = ($next.initial_delete_files | append $pathspec)
    return $next
  }

  # A path can already be staged away by a previous failed commit attempt.
  # Keep it in the commit set, but skip `git add -A` because there is nothing
  # left in the worktree for git to match.
  if not ($staged_matches | is-empty) {
    $next.files = ($next.files | append $pathspec)
    return $next
  }

  print-stderr $"warning: pathspec did not match tracked or staged files: ($pattern)\n"
  $next
}

def hook-files [repo_path: path files: list<string>]: nothing -> list<string> {
  git-lines $repo_path ([diff --cached --name-only --diff-filter=ACMRTUXB --] ++ $files)
}

def combined-output [result: record<stdout: string, stderr: string, exit_code: int>]: nothing -> string {
  [$result.stdout $result.stderr] | str join ""
}

def emit-command-output [result: record<stdout: string, stderr: string, exit_code: int>]: nothing -> nothing {
  if ($result.stdout | is-not-empty) {
    print -n $result.stdout
  }

  if ($result.stderr | is-not-empty) {
    print-stderr $result.stderr
  }
}

def staged-nested-gitlink-deletions [repo_path: path files: list<string>]: nothing -> list<path> {
  $files
  | where {|pathspec| not (pathspec-is-glob $pathspec) }
  | each {|pathspec|
      let worktree_path = (worktree-pattern-path $repo_path $pathspec)
      let staged_matches = (git-lines $repo_path [diff --cached --name-only -- $pathspec])

      if (not ($staged_matches | is-empty)) and (nested-git-worktree-path $worktree_path) {
        $worktree_path
      }
    }
  | where {|path| $path != null }
}

def hide-worktree-paths [paths: list<path> tmpdir: path]: nothing -> list<record<original: path, hidden: path>> {
  $paths
  | enumerate
  | each {|entry|
      let hidden = [$tmpdir $"($entry.index)-($entry.item | path basename)"] | path join
      ^mv $entry.item $hidden
      {
        original: $entry.item
        hidden: $hidden
      }
    }
}

def restore-worktree-paths [hidden_paths: list<record<original: path, hidden: path>>]: nothing -> nothing {
  $hidden_paths
  | reverse
  | each {|entry|
      ^mv $entry.hidden $entry.original
    }
  | ignore
}

def run-pre-commit-hooks [
  repo_path: path
  pre_commit_config: path
  hook_files: list<string>
]: nothing -> record<stdout: string, stderr: string, exit_code: int> {
  if not ($pre_commit_config | path exists) {
    return { stdout: "", stderr: "", exit_code: 0 }
  }

  if not ((which prek | get -o path | default []) | is-empty) {
    do {
      cd $repo_path
      ^prek run --color always --stage pre-commit --files ...$hook_files
    } | complete
  } else if not ((which pre-commit | get -o path | default []) | is-empty) {
    do {
      cd $repo_path
      ^pre-commit run --hook-stage pre-commit --files ...$hook_files
    } | complete
  } else {
    exit-with-message 'error: neither `prek` nor `pre-commit` is available on PATH' 1
  }
}

def snapshot-selected-state [repo_path: path files: list<string> prefix: path]: nothing -> nothing {
  let worktree_diff = (git-complete $repo_path ([diff --binary --] ++ $files))
  $worktree_diff.stdout | save -f --raw $"($prefix).worktree"

  let index_diff = (git-complete $repo_path ([diff --binary --cached --] ++ $files))
  $index_diff.stdout | save -f --raw $"($prefix).index"
}

def files-match [first: path second: path]: nothing -> bool {
  ((do { ^cmp -s $first $second } | complete).exit_code == 0)
}

export def run [
  repo_path: path
  commit_message: string
  ...file_or_glob: string
]: nothing -> nothing {
  if ($file_or_glob | is-empty) {
    exit-with-message (usage "committer") 2
  }

  let repo_path = ($repo_path | path expand)
  let repo_check = (git-complete $repo_path [rev-parse --is-inside-work-tree])
  if $repo_check.exit_code != 0 {
    exit-with-message $"error: not a git repository: ($repo_path)" 2
  }

  let repo_root = (
    git-complete $repo_path [rev-parse --show-toplevel]
    | get stdout
    | str trim
  )
  let pre_commit_config = [$repo_root ".pre-commit-config.yaml"] | path join

  let selection = (
    $file_or_glob
    | reduce --fold (empty-selection) {|pattern, selection|
      select-pattern $repo_path $repo_root $selection $pattern
    }
  )

  if ($selection.files | is-empty) {
    exit-with-message "No files selected after glob expansion." 1
  }

  # Only restage selections that still resolve in the worktree or the first add
  # pass. Staged-only deletions were already captured above and would make repeat
  # `git add -A` calls fail.
  if not ($selection.initial_add_files | is-empty) {
    ^git -C $repo_path add -A -- ...$selection.initial_add_files
  }

  if not ($selection.initial_delete_files | is-empty) {
    ^git -C $repo_path rm -q -r --cached --ignore-unmatch -- ...$selection.initial_delete_files
  }

  let selected_hook_files = (hook-files $repo_path $selection.files)

  # `git commit --only` runs hooks against a locked temporary next-index, which
  # breaks fixup-style hooks that restage files (for example treefmt wrappers that
  # call `git add`). Run pre-commit eagerly against the selected staged files, let
  # those hooks update the real index, then disable hook re-entry for the actual
  # commit step.
  if not ($selected_hook_files | is-empty) {
    let hook_tmpdir = (^mktemp -d | str trim)
    mut attempt = 0
    let max_attempts = 5

    while true {
      $attempt = ($attempt + 1)
      let hook_log = [$hook_tmpdir $"hook-($attempt).log"] | path join
      let before_prefix = [$hook_tmpdir "before"] | path join
      let after_prefix = [$hook_tmpdir "after"] | path join

      snapshot-selected-state $repo_path $selection.files $before_prefix
      let hook_result = (run-pre-commit-hooks $repo_path $pre_commit_config $selected_hook_files)
      let hook_output = (combined-output $hook_result)
      $hook_output | save -f --raw $hook_log

      if $hook_result.exit_code == 0 {
        if ($hook_output | is-not-empty) {
          print -n $hook_output
        }

        break
      }

      if not ($selection.retry_add_files | is-empty) {
        ^git -C $repo_path add -A -- ...$selection.retry_add_files
      }

      snapshot-selected-state $repo_path $selection.files $after_prefix
      if (
        (files-match $"($before_prefix).worktree" $"($after_prefix).worktree")
        and (files-match $"($before_prefix).index" $"($after_prefix).index")
      ) {
        if ($hook_output | is-not-empty) {
          print-stderr $hook_output
        }

        ^rm -rf $hook_tmpdir
        exit $hook_result.exit_code
      }

      if $attempt >= $max_attempts {
        if ($hook_output | is-not-empty) {
          print-stderr $hook_output
        }

        print-stderr $"error: pre-commit hooks kept modifying selected files after ($max_attempts) attempts\n"
        ^rm -rf $hook_tmpdir
        exit $hook_result.exit_code
      }
    }

    ^rm -rf $hook_tmpdir
  }

  let commit_hidden_paths = (staged-nested-gitlink-deletions $repo_path $selection.files)

  if ($commit_hidden_paths | is-empty) {
    ^git -C $repo_path commit --only --no-verify -m $commit_message -- ...$selection.files
    return
  }

  let commit_tmpdir = (^mktemp -d | str trim)
  let hidden_paths = (hide-worktree-paths $commit_hidden_paths $commit_tmpdir)
  let commit_result = (do { ^git -C $repo_path commit --only --no-verify -m $commit_message -- ...$selection.files } | complete)
  restore-worktree-paths $hidden_paths
  ^rm -rf $commit_tmpdir
  emit-command-output $commit_result

  if $commit_result.exit_code != 0 {
    exit $commit_result.exit_code
  }
}
