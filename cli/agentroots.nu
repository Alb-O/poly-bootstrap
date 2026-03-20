#!/usr/bin/env nu

use ../lib/nu/mod.nu [bootstrap bootstrap-all check sync]

def render-json [value: any emit_json: bool]: nothing -> oneof<string, nothing> {
  if $emit_json {
    $value | to json --raw
  }
}

def main [] {
  help main
}

def "main check" [
  target_path?: path
  --json (-j)
] {
  let status = check $target_path

  if $json {
    render-json $status true
  } else if $status.ok {
    $"ok: ($status.repo_count) repos validated from ($status.manifest_path)"
  } else {
    $status.errors
    | each {|entry| $"($entry.path): ($entry.message)" }
    | str join "\n"
  }
}

def "main sync" [
  target_path?: path
  --json (-j)
] {
  let status = sync $target_path

  if $json {
    render-json $status true
  } else {
    $status.mode
  }
}

def "main bootstrap" [
  target_path?: path
  --all-repos (-a)
  --json (-j)
] {
  let status = if $all_repos {
    try {
      bootstrap-all $target_path
    } catch {|err|
      let failure_status = ($err.summary? | default ($err.results? | default { error: $err.msg }))
      if $json {
        render-json $failure_status true
      }
      error make $err
    }
  } else {
    bootstrap $target_path
  }

  if $json {
    render-json $status true
  }
}
