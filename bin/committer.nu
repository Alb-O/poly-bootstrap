#!/usr/bin/env nu

use ../nu/tooling/committer.nu [run]

def main [
  repo_path: path
  commit_message: string
  ...file_or_glob: string
] {
  run $repo_path $commit_message ...$file_or_glob
}
