{ pkgs }:

let
  nu = pkgs.lib.getExe pkgs.nushell;
  localInputOverridesScript = ../../poly-local-inputs.nu;
in
(
  {
    cfg,
    globalInputsText,
    repoDirsRoot,
    repoNames,
    repoSources,
    sourcePath,
  }:
  if builtins.pathExists sourcePath then
    builtins.readFile (
      pkgs.runCommand "local-input-overrides.yaml" {
        nativeBuildInputs = [ pkgs.nushell ];
        passAsFile = [
          "sourceYaml"
          "repoNamesJson"
          "repoSourcesJson"
          "globalInputsYaml"
          "includeInputsJson"
          "excludeInputsJson"
        ];
        # Pass larger YAML/JSON payloads via files instead of shell-escaped env.
        sourceYaml = builtins.readFile sourcePath;
        repoNamesJson = builtins.toJSON repoNames;
        repoSourcesJson = builtins.toJSON repoSources;
        globalInputsYaml = globalInputsText;
        includeInputsJson = builtins.toJSON cfg.includeInputs;
        excludeInputsJson = builtins.toJSON cfg.excludeInputs;
        repoDirsRoot = repoDirsRoot;
        urlScheme = cfg.urlScheme;
      } ''
        ${nu} ${localInputOverridesScript} generate \
          "$sourceYamlPath" \
          "$repoNamesJsonPath" \
          "$repoSourcesJsonPath" \
          "$globalInputsYamlPath" \
          "$includeInputsJsonPath" \
          "$excludeInputsJsonPath" \
          "$repoDirsRoot" \
          "$urlScheme" \
          > "$out"
      ''
    )
  else
    ""
)
