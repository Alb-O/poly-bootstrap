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
    runPackagedRun
    runtimeFixture
    ;
in
{
  localInputOverrides."test packaged run refreshes shell export after AgentRoots wrapper source changes" =
    {
      expr =
        let
          initialSourceTree = runtimeFixture "ar_packaged_run_source_initial";
          initialModule = evalSharedModule {
            root = initialSourceTree;
            pkgsForTooling = pkgsWithFakeDevenv;
          };
          initialRun = runPackagedRun {
            derivationNamePrefix = "ar_packaged_run_initial";
            sourceTree = initialSourceTree;
            runPackage = initialModule.config.outputs.run;
          };
          changedSourceTree = pkgs.runCommand "ar_packaged_run_source_changed" { } ''
            mkdir -p "$out"
            cp -R ${initialRun}/. "$out"/
            chmod -R u+w "$out"
            printf '\n# changed\n' >> "$out/repos/agentroots/lib/nu/run.nu"
          '';
          changedModule = evalSharedModule {
            root = changedSourceTree;
            pkgsForTooling = pkgsWithFakeDevenv;
          };
          changedRun = runPackagedRun {
            derivationNamePrefix = "ar_packaged_run_changed";
            sourceTree = changedSourceTree;
            runPackage = changedModule.config.outputs.run;
          };
          initialShellExportLog = builtins.filter (line: line != "") (
            lib.splitString "\n" (builtins.readFile "${initialRun}/shell-export.log")
          );
          changedShellExportLog = builtins.filter (line: line != "") (
            lib.splitString "\n" (builtins.readFile "${changedRun}/shell-export.log")
          );
        in
        initialModule.config.outputs.run != changedModule.config.outputs.run
        &&
          builtins.readFile "${initialRun}/report/run-path.txt"
          != builtins.readFile "${changedRun}/report/run-path.txt"
        && builtins.readFile "${initialRun}/report/devenv-fake.txt" == "1\n"
        && builtins.readFile "${changedRun}/report/devenv-fake.txt" == "1\n"
        && (builtins.length initialShellExportLog) == 1
        && (builtins.length changedShellExportLog) == 2;
      expected = true;
    };
}
