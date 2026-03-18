{ pkgs, lib, options, ... }:

let
  polyrepoHelperPath = toString ../sh/polyrepo.sh;
  devenvRun = pkgs.writeShellApplication {
    name = "devenv-run";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.devenv
      pkgs.findutils
      pkgs.gawk
    ];
    text = builtins.replaceStrings
      [ "@polyrepo_helper_path@" ]
      [ polyrepoHelperPath ]
      (builtins.readFile ../sh/devenv-run.sh);
  };
in
{
  config = lib.mkMerge [
    {
      packages = [ devenvRun ];

      outputs.devenv-run = devenvRun;
    }
    (lib.optionalAttrs (options ? instructions && options.instructions ? instructions) {
      instructions.instructions = lib.mkOrder 300 [ (builtins.readFile ./AGENTS.md) ];
    })
  ];
}
