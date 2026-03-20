{
  lib,
  pkgs,
  repoRoot,
}:
let
  support = import ../support.nix {
    inherit
      lib
      pkgs
      repoRoot
      ;
  };
  inherit (support)
    evalSharedModule
    pkgsWithFakeDevenv
    readJson
    runtimeFixture
    runPackagedAgentroots
    ;
in
{
  localInputOverrides."test consumer module exposes agentroots committer and run from AgentRoots module" =
    {
      expr =
        let
          output = runtimeFixture "ar_consumer_module";
          result = evalSharedModule {
            root = output;
            pkgsForTooling = pkgsWithFakeDevenv;
          };
        in
        result.config.outputs ? agentroots
        && result.config.outputs ? committer
        && result.config.outputs ? run
        && builtins.pathExists "${result.config.outputs.agentroots}/bin/agentroots"
        && builtins.pathExists "${result.config.outputs.committer}/bin/committer"
        && builtins.pathExists "${result.config.outputs.run}/bin/run";
      expected = true;
    };

  localInputOverrides."test packaged agentroots bootstraps through the staged runtime" = {
    expr =
      let
        sourceTree = runtimeFixture "ar_packaged_agentroots_source";
        result = evalSharedModule {
          root = sourceTree;
          pkgsForTooling = pkgsWithFakeDevenv;
        };
        run = runPackagedAgentroots {
          derivationNamePrefix = "ar_packaged_agentroots_run";
          inherit sourceTree;
          agentrootsPackage = result.config.outputs.agentroots;
        };
        status = readJson "${run}/status.json";
        shellExportLog = builtins.filter (line: line != "") (
          lib.splitString "\n" (builtins.readFile "${run}/shell-export.log")
        );
      in
      builtins.readFile "${run}/report/agentroots-path.txt"
      == "${result.config.outputs.agentroots}/bin/agentroots\n"
      && status.target_name == "app"
      && status.shell_export_refreshed == true
      && shellExportLog == [ "${run}/repos/app" ];
    expected = true;
  };

  localInputOverrides."test module import is satisfied by module/devenv.nix" = {
    expr =
      let
        output = runtimeFixture "ar_module_devenv_entry";
      in
      builtins.pathExists "${output}/repos/agentroots/module/default.nix"
      && builtins.pathExists "${output}/repos/agentroots/module/devenv.nix"
      && builtins.pathExists "${output}/repos/agentroots/module/AGENTS.md"
      && !(builtins.pathExists "${output}/repos/agentroots/nix/module/default.nix");
    expected = true;
  };
}
