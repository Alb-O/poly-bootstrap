{ config, lib, ... }:

let
  overlapNames = first: second: lib.lists.intersectLists first second;
in
{
  options.composer.localInputOverrides = {
    reposRoot = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Base directory containing local repos used for generated overrides. When null, defaults to `builtins.dirOf config.devenv.root`.";
    };

    sourcePath = lib.mkOption {
      type = lib.types.str;
      default = "devenv.yaml";
      description = "Source devenv YAML file to scan for inputs and URLs.";
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

  config = {
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
  };

  imports = [ ./nix/local-input-overrides ];
}
