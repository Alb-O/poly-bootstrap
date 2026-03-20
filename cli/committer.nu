#!/usr/bin/env nu

use ../lib/nu/committer.nu [run usage]
use ../lib/nu/support.nu [is-nothing]

def --wrapped main [
  --directory(-C): path
  ...args: string
] {
  if not (is-nothing $directory) {
    if ($args | length) < 2 {
      print (usage "committer")
      exit 2
    }

    run $directory ($args | first) ...($args | skip 1)
    return
  }

  if ($args | length) < 2 {
    print (usage "committer")
    exit 2
  }

  run (pwd) ($args | get 0) ...($args | skip 1)
}
