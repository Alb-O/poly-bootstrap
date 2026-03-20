use support.nu [fail is-string]
use manifest.nu [find_agentroots_root load-manifest manifest-path resolve-repo-path]
use resolve.nu [validate-model]

export def main [target_path?: path]: nothing -> record {
  let start_path = (resolve-repo-path (pwd) ($target_path | default "."))
  let agentroots_root = if ((manifest-path $start_path) | path exists) {
    $start_path | path expand --no-symlink
  } else {
    find_agentroots_root $start_path
  }

  if not (is-string $agentroots_root) {
    fail $"AgentRoots root could not be inferred from ($start_path)"
  }

  validate-model (load-manifest $agentroots_root)
}
