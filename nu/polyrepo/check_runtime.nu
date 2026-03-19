use ../support.nu [fail]
use manifest.nu [find-polyrepo-root load-manifest manifest-path resolve-repo-path]
use resolve.nu [validate-model]

export def check [target_path?: path]: nothing -> record {
  let start_path = (resolve-repo-path (pwd) ($target_path | default "."))
  let polyrepo_root = if ((manifest-path $start_path) | path exists) {
    $start_path | path expand --no-symlink
  } else {
    find-polyrepo-root $start_path
  }

  if (($polyrepo_root | describe) != 'string') {
    fail $"polyrepo root could not be inferred from ($start_path)"
  }

  validate-model (load-manifest $polyrepo_root)
}
