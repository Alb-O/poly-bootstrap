{
  config,
  lib,
  pkgs,
  ...
}:

let
  repoRoot = toString ./.;
  isRepoLocalDevEnv = toString config.devenv.root == repoRoot;
in
{
  config = lib.mkIf isRepoLocalDevEnv {
    packages = [ pkgs.nix-unit ];

    scripts = {
      ci.exec = "run-nix-tests";
      run-nix-tests.exec = ''
        nix-unit --expr 'import ${config.devenv.root}/tests { lib = import ${pkgs.path}/lib; pkgs = import ${pkgs.path} {}; repoRoot = ${config.devenv.root}; }'
      '';
    };

    enterTest = "run-nix-tests";
  };
}
