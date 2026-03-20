{
  pkgs,
  lib,
  options,
  ...
}:

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
  devenvRun =
    pkgs.writers.writeNuBin "devenv-run"
      {
        makeWrapperArgs = [
          "--prefix"
          "PATH"
          ":"
          (lib.makeBinPath [
            pkgs.bash
            pkgs.coreutils
            pkgs.devenv
            pkgs.nushell
          ])
        ];
      }
      ''
        def --wrapped main [...rest: string] {
          exec ${lib.getExe pkgs.nushell} ${toolingSource}/bin/devenv-run.nu ...$rest
        }
      '';
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
