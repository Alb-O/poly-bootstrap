#!/usr/bin/env nu

use ../lib/nu/run.nu *
use ../lib/nu/support.nu [is-nothing is-string]

def --wrapped main [
  --directory(-C): path
  --help(-h)
  --shell(-s): string
  ...command: string
] {
  if $help {
    usage
    return
  }

  if (is-string $shell) and not (is-nothing $directory) {
    run-command --directory $directory --shell $shell ...$command
  } else if (is-string $shell) {
    run-command --shell $shell ...$command
  } else if not (is-nothing $directory) {
    run-command --directory $directory ...$command
  } else {
    run-command ...$command
  }
}
