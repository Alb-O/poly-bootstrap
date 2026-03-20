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
    runPackagedDevenvRun
    runtimeFixture
    ;
in
{
  localInputOverrides."test packaged devenv-run refreshes shell export after AgentRoots wrapper source changes" =
    {
      expr =
        let
          initialSourceTree = runtimeFixture "ar_packaged_devenv_run_source_initial";
          initialModule = evalSharedModule {
            root = initialSourceTree;
            pkgsForTooling = pkgsWithFakeDevenv;
          };
          initialRun = runPackagedDevenvRun {
            derivationNamePrefix = "ar_packaged_devenv_run_initial";
            sourceTree = initialSourceTree;
            devenvRunPackage = initialModule.config.outputs.devenv-run;
          };
          changedSourceTree = pkgs.runCommand "ar_packaged_devenv_run_source_changed" { } ''
            mkdir -p "$out"
            cp -R ${initialRun}/. "$out"/
            chmod -R u+w "$out"
            printf '\n# changed\n' >> "$out/repos/agentroots/lib/nu/devenv_run.nu"
          '';
          changedModule = evalSharedModule {
            root = changedSourceTree;
            pkgsForTooling = pkgsWithFakeDevenv;
          };
          changedRun = runPackagedDevenvRun {
            derivationNamePrefix = "ar_packaged_devenv_run_changed";
            sourceTree = changedSourceTree;
            devenvRunPackage = changedModule.config.outputs.devenv-run;
          };
          initialShellExportLog = builtins.filter (line: line != "") (
            lib.splitString "\n" (builtins.readFile "${initialRun}/shell-export.log")
          );
          changedShellExportLog = builtins.filter (line: line != "") (
            lib.splitString "\n" (builtins.readFile "${changedRun}/shell-export.log")
          );
        in
        initialModule.config.outputs.devenv-run != changedModule.config.outputs.devenv-run
        &&
          builtins.readFile "${initialRun}/report/devenv-run-path.txt"
          != builtins.readFile "${changedRun}/report/devenv-run-path.txt"
        && builtins.readFile "${initialRun}/report/devenv-fake.txt" == "1\n"
        && builtins.readFile "${changedRun}/report/devenv-fake.txt" == "1\n"
        && (builtins.length initialShellExportLog) == 1
        && (builtins.length changedShellExportLog) == 2;
      expected = true;
    };
}
