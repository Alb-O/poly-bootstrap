#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
polyrepo_helper_path='@polyrepo_helper_path@'
if [[ ! -e "$polyrepo_helper_path" ]]; then
  polyrepo_helper_path="$script_dir/polyrepo.sh"
fi
# shellcheck disable=SC1090,SC1091
source "$polyrepo_helper_path"
polyrepo_shell_export_meta_path_value=""
polyrepo_shell_export_meta_fingerprint=""

usage() {
  cat <<'EOF'
Usage: devenv-run [-C repo_root] [--shell '<command>'] [--] <command> [args...]

Run a command inside a repo's generated devenv environment without executing
the repo's shellHook / enterShell tasks during steady-state reuse. On first use,
it may materialize a shell export so later runs can stay side-effect-light.
EOF
}

latest_shell_export() {
  find .devenv -maxdepth 1 -type f -name 'shell-*.sh' -printf '%T@ %p\n' 2>/dev/null |
    sort -nr |
    head -n 1 |
    cut -d' ' -f2-
}

materialize_shell_export() {
  # A real `devenv shell` run is the reliable way to produce `.devenv/shell-*`.
  # We only do this on the cold path, then later runs can reuse the export.
  devenv shell --no-tui --no-eval-cache --refresh-eval-cache -- bash -lc 'true' >/dev/null
}

repo_root=$(pwd)
shell_command=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -C)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for -C" >&2
        exit 2
      fi
      repo_root=$2
      shift 2
      ;;
    -s | --shell)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for $1" >&2
        exit 2
      fi
      shell_command=$2
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      break
      ;;
  esac
done

if [[ -z "$shell_command" && $# -eq 0 ]]; then
  usage >&2
  exit 2
fi

if [[ -n "$shell_command" && $# -gt 0 ]]; then
  echo "--shell cannot be combined with a direct command invocation" >&2
  exit 2
fi

cd "$repo_root"
repo_root=$(pwd)

if [[ ! -f devenv.nix || ! -f devenv.yaml ]]; then
  echo "Not a devenv repo root: $repo_root" >&2
  exit 1
fi

polyrepo_bootstrap_repo "$repo_root"

# Reuse the repo's generated shell export if it already exists. This avoids
# entering `devenv shell`, which can run enterShell tasks with side effects.
shell_script=$(latest_shell_export)
shell_export_reason=""

if [[ -n "$shell_script" ]]; then
  if polyrepo_load_shell_export_meta "$repo_root"; then
    current_fingerprint=$(polyrepo_shell_export_fingerprint "$repo_root")
    if [[ "$polyrepo_shell_export_meta_path_value" == "$shell_script" ]] \
      && [[ "$polyrepo_shell_export_meta_fingerprint" == "$current_fingerprint" ]]; then
      shell_export_reason="reused"
    else
      shell_export_reason="stale_fingerprint"
    fi
  else
    case "$?" in
      1)
        shell_export_reason="missing_meta"
        ;;
      *)
        shell_export_reason="meta_parse_error"
        ;;
    esac
  fi
else
  shell_export_reason="missing_export"
fi

if [[ "$shell_export_reason" != "reused" ]]; then
  materialize_shell_export
  shell_script=$(latest_shell_export)
fi

if [[ -z "$shell_script" ]]; then
  echo "No generated .devenv shell export found under $repo_root/.devenv." >&2
  if [[ -n "$shell_export_reason" ]]; then
    echo "Last shell export decision: $shell_export_reason" >&2
  fi
  echo "Run 'devenv tasks run devenv:files' and try again." >&2
  exit 1
fi

if [[ "$shell_export_reason" != "reused" ]]; then
  current_fingerprint=$(polyrepo_shell_export_fingerprint "$repo_root")
  polyrepo_write_shell_export_meta "$repo_root" "$shell_script" "$current_fingerprint"
fi

export PS1=""

# The generated shell script contains plain environment exports followed by the
# shell hook evaluation. Stop before the `eval`/`shellHook` tail so we keep the
# environment but skip formatter or enterShell side effects.
# shellcheck disable=SC1090
source <(awk '/^eval($| )/ || /\$\{shellHook:-\}/ { exit } { print }' "$shell_script")

if [[ -n "$shell_command" ]]; then
  # Shell mode is for builtins, pipes, and env expansion that cannot be `exec`'d
  # directly the way the normal binary path can.
  exec bash -lc "$shell_command"
fi

exec "$@"
