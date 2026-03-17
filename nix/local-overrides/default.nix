{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.composer.localInputOverrides;
  context = import ./context.nix { inherit config lib; };
  renderLocalInputOverrides = import ./render.nix { inherit pkgs; };
  localInputOverridesText = renderLocalInputOverrides {
    inherit cfg;
    inherit (context) globalInputsText repoDirsRoot repoNames repoPaths repoSources sourcePath;
  };
in
{
  config = lib.mkIf (localInputOverridesText != "") {
    files."${cfg.outputPath}".text = localInputOverridesText;
    outputs.local_input_overrides =
      pkgs.writeText "local-overrides.yaml" localInputOverridesText;
  };
}
