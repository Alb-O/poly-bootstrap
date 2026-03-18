{ pkgs }:

let
  nu = pkgs.lib.getExe pkgs.nushell;
  localInputOverridesSource = builtins.path {
    path = ../..;
    name = "poly-bootstrap-source";
  };
  localInputOverridesScript = "${localInputOverridesSource}/bin/local-overrides.nu";
in
(
  {
    cfg,
    currentRepoName,
    polyrepoManifestText,
    repoPaths,
  }:
  builtins.readFile (
    pkgs.runCommand "local-overrides.yaml" {
      nativeBuildInputs = [ pkgs.nushell ];
      passAsFile = [ "manifestJson" ];
      # Pass the full render spec as one manifest file instead of a bundle of
      # positional payload files.
      manifestJson = builtins.toJSON {
        current_repo_name = currentRepoName;
        polyrepo_manifest_text = polyrepoManifestText;
        local_repo_paths = repoPaths;
        include_inputs = cfg.includeInputs;
        exclude_inputs = cfg.excludeInputs;
        url_scheme = cfg.urlScheme;
      };
    } ''
      ${nu} ${localInputOverridesScript} render-manifest "$manifestJsonPath" > "$out"
    ''
  )
)
