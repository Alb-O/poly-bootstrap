use ../support.nu [fail is-record]
use common.nu [ensure-shell-export]
use manifest.nu [is-bootstrap-target]
use resolve.nu [resolve-target]
use sync_runtime.nu [sync]

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
  if not (is-record $repo_entry) {
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

  let repo_results = (
    $dependency_names
    | each {|repo_name|
        let repo_entry = ($target_model.repos | get $repo_name)
        let repo_root = ($repo_entry | get path)

        {
          repo_name: $repo_name
          repo_root: $repo_root
          sync: (sync $repo_root)
          bootstrap_tasks: (
            $repo_entry.bootstrapTasks
            | each {|task_name| run-bootstrap-task $repo_root $task_name }
          )
        }
      }
  )

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
    target_name: $target.target_name
    dependency_repos: ($repo_results | each {|entry| $entry.repo_name })
    dependency_results: $repo_results
    sync: $target_sync
    bootstrap_tasks: $target_task_results
    lock_refreshed: $lock_refreshed
    shell_export_path: $shell_export_status.shell_export_path
    shell_export_refreshed: $shell_export_status.shell_export_refreshed
    shell_export_reason: $shell_export_status.shell_export_reason
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
