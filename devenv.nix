{ pkgs, config, lib, ... }:

let
  cfg = config.materializer;
  pythonWithYaml = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
  localInputOverridesScript = ./env-local-overrides.py;
  localInputOverridesReposRoot =
    if cfg.localInputOverrides.reposRoot != null
    then cfg.localInputOverrides.reposRoot
    else dirOf config.devenv.root;
  localInputOverridesSourcePath =
    if lib.hasPrefix "/" cfg.localInputOverrides.sourcePath
    then cfg.localInputOverrides.sourcePath
    else "${config.devenv.root}/${cfg.localInputOverrides.sourcePath}";
  localInputOverridesText =
    if builtins.pathExists localInputOverridesSourcePath
    then builtins.readFile (pkgs.runCommand "materialized-local-input-overrides.yaml" {
      nativeBuildInputs = [ pythonWithYaml ];
      passAsFile = [ "sourceYaml" ];
      sourceYaml = builtins.readFile localInputOverridesSourcePath;
      reposRoot = localInputOverridesReposRoot;
      urlScheme = cfg.localInputOverrides.urlScheme;
    } ''
      python3 ${localInputOverridesScript} "$sourceYamlPath" "$reposRoot" "$urlScheme" > "$out"
    '')
    else "";
in
{
  options.materializer.localInputOverrides = {
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
  };

  config = lib.mkIf (localInputOverridesText != "") {
    files."${cfg.localInputOverrides.outputPath}".text = localInputOverridesText;
    outputs.materialized_local_input_overrides = pkgs.writeText "devenv-local-input-overrides.yaml" localInputOverridesText;
  };
}
