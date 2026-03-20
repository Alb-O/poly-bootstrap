export def main [] {
  help agentroots
}

# command modules keep clean filenames and export `main`
# import and re-export them with `use ... *` so the module name stays the command name
export use bootstrap.nu *
export use check.nu *
export module bootstrap.nu
export module check.nu
export module committer.nu
export module devenv_run.nu
export module manifest.nu
export module resolve.nu
export module shell_export.nu
export use sync.nu *
export module sync.nu
