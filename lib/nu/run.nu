use bootstrap.nu *
use support.nu [fail is-non-empty-string is-string]
use shell_export.nu [run-in-shell-export]

export def usage []: nothing -> string {
  [
    "Usage: run [-C repo_root] [--shell '<command>'] [--] <command> [args...]"
    ""
    "Run a command inside a repo's generated devenv environment without executing"
    "the repo's shellHook / enterShell tasks during steady-state reuse. On first use,"
    "it may materialize a shell export so later runs can stay side-effect-light."
    ""
    "The executed command runs from the repo selected by -C (or CWD if omitted)."
  ] | str join "\n"
}

export def run-command [
  --directory(-C): path
  --shell(-s): string
  ...command: string
]: nothing -> nothing {
  let repo_root = (($directory | default ".") | path expand --no-symlink)

  if not (is-string $shell) and ($command | is-empty) {
    fail (usage)
  }

  if (is-string $shell) and ($command | is-not-empty) {
    fail "--shell cannot be combined with a direct command invocation"
  }

  if not (($repo_root | path join "devenv.nix") | path exists) or not (($repo_root | path join "devenv.yaml") | path exists) {
    fail $"Not a devenv repo root: ($repo_root)"
  }

  let bootstrap_status = bootstrap $repo_root
  let shell_script = ($bootstrap_status | get shell_export_path)

  if not (is-non-empty-string $shell_script) {
    fail $"expected devenv shell export under (($repo_root | path join '.devenv'))"
  }

  if (is-string $shell) {
    run-in-shell-export $repo_root $shell_script --shell-command $shell
  } else {
    run-in-shell-export $repo_root $shell_script ...$command
  }
}
