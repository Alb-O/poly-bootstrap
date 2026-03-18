{
  config,
  lib,
  pkgs,
  ...
}:

let
  overlapNames = first: second: lib.lists.intersectLists first second;
  repoRoot = toString ./.;
  isRepoLocalDevEnv = toString config.devenv.root == repoRoot;
in
{
  options.composer.localInputOverrides = {
    polyrepoRoot = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Polyrepo root used for generated overrides. When null, infer it from the nearest enclosing `polyrepo.nuon` whose repo catalog contains the current repo.";
    };

    repoDirsPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Directory path containing consumer repos. When null, read `repoDirsPath` from `polyrepo.nuon` at the effective polyrepo root.";
    };

    outputPath = lib.mkOption {
      type = lib.types.str;
      default = "devenv.local.yaml";
      description = "Output path for generated local input override YAML.";
    };

    urlScheme = lib.mkOption {
      type = lib.types.enum [ "path" "git+file" ];
      default = "path";
      description = "URL scheme used for generated local repo overrides.";
    };

    includeRepos = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Only consider these local repo directory names. Empty means all repos.";
    };

    excludeRepos = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Skip these local repo directory names.";
    };

    includeInputs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Only generate overrides for these input names. Empty means all inputs.";
    };

    excludeInputs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Skip these input names when generating overrides.";
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion =
            overlapNames
              config.composer.localInputOverrides.includeRepos
              config.composer.localInputOverrides.excludeRepos
            == [ ];
          message = "composer.localInputOverrides.includeRepos and excludeRepos must not overlap.";
        }
        {
          assertion =
            overlapNames
              config.composer.localInputOverrides.includeInputs
              config.composer.localInputOverrides.excludeInputs
            == [ ];
          message = "composer.localInputOverrides.includeInputs and excludeInputs must not overlap.";
        }
      ];
    }
    (lib.mkIf isRepoLocalDevEnv {
      packages = [ pkgs.nix-unit ];

      scripts = {
        ci.exec = "run-nix-tests";
        run-nix-tests.exec = ''
          nix-unit --expr 'import ${config.devenv.root}/tests { lib = import ${pkgs.path}/lib; pkgs = import ${pkgs.path} {}; repoRoot = ${config.devenv.root}; }'
        '';
      };

      enterTest = "run-nix-tests";
    })
  ];

  imports = [ ./nix/local-overrides ];
}
