#!/usr/bin/env nu

use ../nu/polyrepo/devenv_run.nu *

def main [
  --directory(-C): path
  --shell(-s): string
  ...command: string
] {
  if (($shell | describe) == 'string') and (($directory | describe) != 'nothing') {
    run --directory $directory --shell $shell ...$command
  } else if (($shell | describe) == 'string') {
    run --shell $shell ...$command
  } else if (($directory | describe) != 'nothing') {
    run --directory $directory ...$command
  } else {
    run ...$command
  }
}
