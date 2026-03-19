{ pkgs, lib, options, ... }:

let
  toolingSource = pkgs.runCommand "agentroots_tooling_source" { } ''
    mkdir -p "$out/bin" "$out/nu/agentroots" "$out/nu/tooling"
    cp ${../bin/committer.nu} "$out/bin/committer.nu"
    cp ${../bin/devenv-run.nu} "$out/bin/devenv-run.nu"
    cp ${../bin/agentroots.nu} "$out/bin/agentroots.nu"
    cp ${../nu/support.nu} "$out/nu/support.nu"
    cp ${../nu/agentroots/bootstrap_runtime.nu} "$out/nu/agentroots/bootstrap_runtime.nu"
    cp ${../nu/agentroots/check_runtime.nu} "$out/nu/agentroots/check_runtime.nu"
    cp ${../nu/agentroots/common.nu} "$out/nu/agentroots/common.nu"
    cp ${../nu/agentroots/devenv_run.nu} "$out/nu/agentroots/devenv_run.nu"
    cp ${../nu/agentroots/manifest.nu} "$out/nu/agentroots/manifest.nu"
    cp ${../nu/agentroots/mod.nu} "$out/nu/agentroots/mod.nu"
    cp ${../nu/agentroots/resolve.nu} "$out/nu/agentroots/resolve.nu"
    cp ${../nu/agentroots/sync_runtime.nu} "$out/nu/agentroots/sync_runtime.nu"
    cp ${../nu/tooling/committer.nu} "$out/nu/tooling/committer.nu"
  '';
  committer = pkgs.writeShellApplication {
    name = "committer";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.git
      pkgs.nushell
      pkgs.pre-commit
      pkgs.prek
    ];
    text = ''
      exec ${lib.getExe pkgs.nushell} ${toolingSource}/bin/committer.nu "$@"
    '';
  };
  devenvRun = pkgs.writeShellApplication {
    name = "devenv-run";
    runtimeInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.devenv
      pkgs.nushell
    ];
    text = ''
      repo_root=$(pwd)
      shell_command=""

      usage() {
        cat <<'EOF'
Usage: devenv-run [-C repo_root] [--shell '<command>'] [--] <command> [args...]

Run a command inside a repo's generated devenv environment without executing
the repo's shellHook / enterShell tasks during steady-state reuse. On first use,
it may materialize a shell export so later runs can stay side-effect-light.
EOF
      }

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
          -s|--shell)
            if [[ $# -lt 2 ]]; then
              echo "Missing value for $1" >&2
              exit 2
            fi
            shell_command=$2
            shift 2
            ;;
          -h|--help)
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

      if [[ -n "$shell_command" ]]; then
        if [[ $# -gt 0 ]]; then
          echo "--shell cannot be combined with a direct command invocation" >&2
          exit 2
        fi

        exec ${lib.getExe pkgs.nushell} ${toolingSource}/bin/devenv-run.nu -C "$repo_root" --shell "$shell_command"
      fi

      if [[ $# -eq 0 ]]; then
        exec ${lib.getExe pkgs.nushell} ${toolingSource}/bin/devenv-run.nu -C "$repo_root"
      fi

      quoted_command=$(printf '%q ' "$@")
      quoted_command=''${quoted_command% }
      exec ${lib.getExe pkgs.nushell} ${toolingSource}/bin/devenv-run.nu -C "$repo_root" --shell "$quoted_command"
    '';
  };
in
{
  config = lib.mkMerge [
    {
      packages = [
        committer
        devenvRun
      ];

      outputs.committer = committer;
      outputs.devenv-run = devenvRun;
    }
    (lib.optionalAttrs (options ? instructions && options.instructions ? instructions) {
      instructions.instructions = lib.mkOrder 300 [ (builtins.readFile ./AGENTS.md) ];
    })
  ];
}
