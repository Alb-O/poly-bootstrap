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
    polyrepoManifestText,
    repoDirsRoot,
    repoNames,
    repoPaths,
    repoSources,
    sourcePath,
  }:
  if builtins.pathExists sourcePath then
    builtins.readFile (
      pkgs.runCommand "local-overrides.yaml" {
        nativeBuildInputs = [ pkgs.nushell ];
        passAsFile = [ "manifestJson" ];
        # Pass the full render spec as one manifest file instead of a bundle of
        # positional payload files.
        manifestJson = builtins.toJSON {
          source_yaml_text = builtins.readFile sourcePath;
          polyrepo_manifest_text = polyrepoManifestText;
          local_repo_names = repoNames;
          local_repo_paths = repoPaths;
          repo_sources = repoSources;
          include_inputs = cfg.includeInputs;
          exclude_inputs = cfg.excludeInputs;
          repo_dirs_root = repoDirsRoot;
          url_scheme = cfg.urlScheme;
        };
      } ''
        ${nu} ${localInputOverridesScript} render-manifest "$manifestJsonPath" > "$out"
      ''
    )
  else
    ""
)
