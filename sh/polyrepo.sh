#!/usr/bin/env bash

polyrepo_find_root() {
  local search_dir parent
  search_dir=$(cd "${1:-.}" && pwd)

  while [[ ! -x "$search_dir/repos/poly-bootstrap/bootstrap" ]]; do
    parent=$(dirname "$search_dir")
    if [[ "$parent" == "$search_dir" ]]; then
      return 1
    fi
    search_dir=$parent
  done

  printf '%s\n' "$search_dir"
}

polyrepo_bootstrap_repo() {
  local repo_root polyrepo_root bootstrap_script
  repo_root=$(cd "${1:-.}" && pwd)

  if ! polyrepo_root=$(polyrepo_find_root "$repo_root"); then
    return 0
  fi

  bootstrap_script="$polyrepo_root/repos/poly-bootstrap/bootstrap"
  bash "$bootstrap_script" "$repo_root"
}

polyrepo_shell_export_meta_path() {
  printf '%s\n' "$1/.devenv/polyrepo-shell-export.meta"
}

polyrepo_shell_export_file_stat_line() {
  local label=$1
  local path_value=$2

  if [[ ! -e "$path_value" ]]; then
    printf '%s\t0\t-\t-\n' "$label"
    return 0
  fi

  printf '%s\t1\t%s\t%s\n' \
    "$label" \
    "$(stat -c '%s' "$path_value")" \
    "$(stat -c '%Y' "$path_value")"
}

polyrepo_shell_export_local_inputs() {
  local repo_root=$1
  local local_yaml_path="$repo_root/devenv.local.yaml"

  [[ -f "$local_yaml_path" ]] || return 0

  awk '
    /^inputs:$/ {
      in_inputs = 1
      current = ""
      next
    }
    in_inputs && /^[^[:space:]]/ {
      in_inputs = 0
    }
    in_inputs && /^  [^[:space:]][^:]*:$/ {
      current = $1
      sub(/:$/, "", current)
      next
    }
    in_inputs && /^    url: path:/ && current != "" {
      path = $0
      sub(/^    url: path:/, "", path)
      printf "%s\t%s\n", current, path
    }
  ' "$local_yaml_path" | LC_ALL=C sort
}

polyrepo_shell_export_fingerprint() {
  local repo_root=$1
  local input_name input_path rel_path

  {
    printf 'version\t1\n'
    printf 'repo_root\t%s\n' "$repo_root"

    for rel_path in devenv.nix devenv.yaml devenv.local.yaml devenv.lock; do
      polyrepo_shell_export_file_stat_line "target:${rel_path}" "$repo_root/$rel_path"
    done

    while IFS=$'\t' read -r input_name input_path; do
      [[ -n "$input_name" ]] || continue

      printf 'input\t%s\t%s\n' "$input_name" "$input_path"

      for rel_path in devenv.nix devenv.yaml devenv.lock; do
        polyrepo_shell_export_file_stat_line "input:${input_name}:${rel_path}" "$input_path/$rel_path"
      done

      if [[ "$input_name" == "poly-bootstrap" ]]; then
        for rel_path in \
          sh/devenv-run.sh \
          sh/polyrepo.sh \
          tooling/default.nix
        do
          polyrepo_shell_export_file_stat_line "input:${input_name}:${rel_path}" "$input_path/$rel_path"
        done
      fi
    done < <(polyrepo_shell_export_local_inputs "$repo_root")
  } | sha256sum | cut -d' ' -f1
}

polyrepo_load_shell_export_meta() {
  local repo_root=$1
  local meta_path key value

  polyrepo_shell_export_meta_version=""
  polyrepo_shell_export_meta_path_value=""
  polyrepo_shell_export_meta_fingerprint=""
  polyrepo_shell_export_meta_created_at=""

  meta_path=$(polyrepo_shell_export_meta_path "$repo_root")
  [[ -f "$meta_path" ]] || return 1

  while IFS='=' read -r key value; do
    [[ -n "$key" ]] || continue

    case "$key" in
      POLYREPO_SHELL_EXPORT_VERSION)
        polyrepo_shell_export_meta_version=$value
        ;;
      POLYREPO_SHELL_EXPORT_PATH)
        polyrepo_shell_export_meta_path_value=$value
        ;;
      POLYREPO_SHELL_EXPORT_FINGERPRINT)
        polyrepo_shell_export_meta_fingerprint=$value
        ;;
      POLYREPO_SHELL_EXPORT_CREATED_AT)
        polyrepo_shell_export_meta_created_at=$value
        ;;
    esac
  done < "$meta_path"

  if [[ "$polyrepo_shell_export_meta_version" != "1" ]] \
    || [[ -z "$polyrepo_shell_export_meta_path_value" ]] \
    || [[ -z "$polyrepo_shell_export_meta_fingerprint" ]]; then
    return 2
  fi
}

polyrepo_write_shell_export_meta() {
  local repo_root=$1
  local shell_export_path=$2
  local fingerprint=$3
  local meta_path

  meta_path=$(polyrepo_shell_export_meta_path "$repo_root")
  mkdir -p "$(dirname "$meta_path")"

  cat > "$meta_path" <<EOF
POLYREPO_SHELL_EXPORT_VERSION=1
POLYREPO_SHELL_EXPORT_PATH=$shell_export_path
POLYREPO_SHELL_EXPORT_FINGERPRINT=$fingerprint
POLYREPO_SHELL_EXPORT_CREATED_AT=$(date -Iseconds)
EOF
}
