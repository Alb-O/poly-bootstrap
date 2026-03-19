#!/usr/bin/env nu

use ../nu/polyrepo/devenv_run.nu *
use ../nu/support.nu [is-nothing is-string]

def main [
  --directory(-C): path
  --shell(-s): string
  ...command: string
] {
  if (is-string $shell) and not (is-nothing $directory) {
    run --directory $directory --shell $shell ...$command
  } else if (is-string $shell) {
    run --shell $shell ...$command
  } else if not (is-nothing $directory) {
    run --directory $directory ...$command
  } else {
    run ...$command
  }
}
