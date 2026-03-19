use bootstrap_runtime.nu [bootstrap]
use ../support.nu [fail]
use common.nu [run-in-shell-export]

def usage []: nothing -> string {
  [
    "Usage: devenv-run [-C repo_root] [--shell '<command>'] [--] <command> [args...]"
    ""
    "Run a command inside a repo's generated devenv environment without executing"
    "the repo's shellHook / enterShell tasks during steady-state reuse. On first use,"
    "it may materialize a shell export so later runs can stay side-effect-light."
  ] | str join "\n"
}

export def run [
  --directory(-C): path
  --shell(-s): string
  ...command: string
]: nothing -> nothing {
  let repo_root = (($directory | default ".") | path expand --no-symlink)

  if (($shell | describe) != 'string') and ($command | is-empty) {
    fail (usage)
  }

  if (($shell | describe) == 'string') and not ($command | is-empty) {
    fail "--shell cannot be combined with a direct command invocation"
  }

  if not (($repo_root | path join "devenv.nix") | path exists) or not (($repo_root | path join "devenv.yaml") | path exists) {
    fail $"Not a devenv repo root: ($repo_root)"
  }

  let bootstrap_status = bootstrap $repo_root
  let shell_script = ($bootstrap_status | get shell_export_path)

  if (($shell_script | describe) != 'string') or ($shell_script | is-empty) {
    fail $"expected devenv shell export under (($repo_root | path join '.devenv'))"
  }

  if (($shell | describe) == 'string') {
    run-in-shell-export $shell_script --shell-command $shell
  } else {
    run-in-shell-export $shell_script ...$command
  }
}
