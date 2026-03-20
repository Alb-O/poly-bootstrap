{
  pkgs,
  lib,
  options,
  ...
}:

let
  packageTools = import ../nix/package-tools.nix {
    inherit
      pkgs
      lib
      ;
  };
  agentroots = packageTools.makeNuCli {
    name = "agentroots";
    entrypoint = "cli/agentroots.nu";
    runtimeInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.devenv
    ];
  };
  committer = packageTools.makeNuCli {
    name = "committer";
    entrypoint = "cli/committer.nu";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.git
      pkgs.pre-commit
      pkgs.prek
    ];
  };
  runCli = packageTools.makeNuCli {
    name = "run";
    entrypoint = "cli/run.nu";
    runtimeInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.devenv
    ];
  };
in
{
  config = lib.mkMerge [
    {
      packages = [
        agentroots
        committer
        runCli
      ];

      outputs.agentroots = agentroots;
      outputs.committer = committer;
      outputs.run = runCli;
    }
    (lib.optionalAttrs (options ? instructions && options.instructions ? instructions) {
      instructions.instructions = lib.mkOrder 300 [ (builtins.readFile ./AGENTS.md) ];
    })
  ];
}
