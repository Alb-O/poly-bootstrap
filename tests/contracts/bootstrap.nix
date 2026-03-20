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
    readJson
    readYaml
    runBootstrap
    runBootstrapFailure
    runBootstrapJson
    runBootstrapJsonTwice
    seedStubAgentrootsRuntime
    stripContext
    ;
in
{
  localInputOverrides."test bootstrap recurses manifest deps before target update" = {
    expr =
      let
        output = runBootstrapJson {
          derivationNamePrefix = "ar_bootstrap_recursive";
          fixture = "recursive_agentroots";
          repoPath = "repos/app";
        };
        status = readJson "${output}/status.json";
        appRendered = readYaml "${output}/repos/app/devenv.local.yaml";
        depRendered = readYaml "${output}/repos/bootstrap_dep/devenv.local.yaml";
        bootstrapLog = builtins.filter (line: line != "") (
          lib.splitString "\n" (builtins.readFile "${output}/bootstrap.log")
        );
        filesLog = builtins.filter (line: line != "") (
          lib.splitString "\n" (builtins.readFile "${output}/devenv-files.log")
        );
      in
      status.target_name == "app"
      && status.dependency_repos == [ "bootstrap_dep" ]
      && stripContext appRendered.inputs.agentroots.url == stripContext "path:${output}/repos/agentroots"
      &&
        stripContext depRendered.inputs.docs-shared.url
        == stripContext "path:${output}/repos/ar_devenv_docs"
      && bootstrapLog == [ "${output}/repos/app" ]
      &&
        filesLog == [
          "${output}/repos/bootstrap_dep"
          "${output}/repos/app"
        ];
    expected = true;
  };

  localInputOverrides."test bootstrap materializes a shell export and metadata for the target repo" =
    {
      expr =
        let
          output = runBootstrapJson {
            derivationNamePrefix = "ar_bootstrap_shell_export_meta";
            fixture = "recursive_agentroots";
            repoPath = "repos/app";
          };
          status = readJson "${output}/status.json";
          shellExportLog = builtins.filter (line: line != "") (
            lib.splitString "\n" (builtins.readFile "${output}/shell-export.log")
          );
        in
        status.shell_export_refreshed == true
        && status.shell_export_reason == "forced_refresh"
        && builtins.pathExists "${output}/repos/app/.devenv/ar_shell_export.meta"
        && shellExportLog == [ "${output}/repos/app" ];
      expected = true;
    };

  localInputOverrides."test bootstrap reuses shell export when metadata matches" = {
    expr =
      let
        output = runBootstrapJsonTwice {
          derivationNamePrefix = "ar_bootstrap_shell_export_reuse";
          fixture = "recursive_agentroots";
          repoPath = "repos/nusurf";
        };
        secondStatus = readJson "${output}/second-status.json";
        shellExportLog = builtins.filter (line: line != "") (
          lib.splitString "\n" (builtins.readFile "${output}/shell-export.log")
        );
      in
      secondStatus.shell_export_refreshed == false
      && secondStatus.shell_export_reason == "reused"
      && shellExportLog == [ "${output}/repos/nusurf" ];
    expected = true;
  };

  localInputOverrides."test bootstrap refreshes shell export when metadata is missing" = {
    expr =
      let
        output = runBootstrapJsonTwice {
          derivationNamePrefix = "ar_bootstrap_shell_export_missing_meta";
          fixture = "recursive_agentroots";
          repoPath = "repos/nusurf";
          betweenRuns = ''
            rm "$out/repos/nusurf/.devenv/ar_shell_export.meta"
          '';
        };
        secondStatus = readJson "${output}/second-status.json";
        shellExportLog = builtins.filter (line: line != "") (
          lib.splitString "\n" (builtins.readFile "${output}/shell-export.log")
        );
      in
      secondStatus.shell_export_refreshed == true
      && secondStatus.shell_export_reason == "missing_meta"
      &&
        shellExportLog == [
          "${output}/repos/nusurf"
          "${output}/repos/nusurf"
        ];
    expected = true;
  };

  localInputOverrides."test bootstrap refreshes shell export when metadata is corrupt" = {
    expr =
      let
        output = runBootstrapJsonTwice {
          derivationNamePrefix = "ar_bootstrap_shell_export_corrupt_meta";
          fixture = "recursive_agentroots";
          repoPath = "repos/nusurf";
          betweenRuns = ''
            cat > "$out/repos/nusurf/.devenv/ar_shell_export.meta" <<'EOF'
            not-valid-metadata
            EOF
          '';
        };
        secondStatus = readJson "${output}/second-status.json";
        shellExportLog = builtins.filter (line: line != "") (
          lib.splitString "\n" (builtins.readFile "${output}/shell-export.log")
        );
      in
      secondStatus.shell_export_refreshed == true
      && secondStatus.shell_export_reason == "meta_parse_error"
      &&
        shellExportLog == [
          "${output}/repos/nusurf"
          "${output}/repos/nusurf"
        ];
    expected = true;
  };

  localInputOverrides."test bootstrap refreshes shell export when tracked repo files change" = {
    expr =
      let
        output = runBootstrapJsonTwice {
          derivationNamePrefix = "ar_bootstrap_shell_export_target_change";
          fixture = "recursive_agentroots";
          repoPath = "repos/nusurf";
          betweenRuns = ''
            printf '\n# refresh shell export fingerprint\n' >> "$out/repos/nusurf/devenv.yaml"
          '';
        };
        secondStatus = readJson "${output}/second-status.json";
        shellExportLog = builtins.filter (line: line != "") (
          lib.splitString "\n" (builtins.readFile "${output}/shell-export.log")
        );
      in
      secondStatus.shell_export_refreshed == true
      && secondStatus.shell_export_reason == "stale_fingerprint"
      &&
        shellExportLog == [
          "${output}/repos/nusurf"
          "${output}/repos/nusurf"
        ];
    expected = true;
  };

  localInputOverrides."test bootstrap refreshes shell export when AgentRoots runtime changes" = {
    expr =
      let
        output = runBootstrapJsonTwice {
          derivationNamePrefix = "ar_bootstrap_shell_export_agentroots_change";
          fixture = "recursive_agentroots";
          repoPath = "repos/nusurf";
          beforeRun = seedStubAgentrootsRuntime {
            targetRoot = "$out/repos/agentroots";
          };
          betweenRuns = ''
            printf '\n# changed\n' >> "$out/repos/agentroots/cli/devenv-run.nu"
          '';
        };
        secondStatus = readJson "${output}/second-status.json";
        shellExportLog = builtins.filter (line: line != "") (
          lib.splitString "\n" (builtins.readFile "${output}/shell-export.log")
        );
      in
      secondStatus.shell_export_refreshed == true
      && secondStatus.shell_export_reason == "stale_fingerprint"
      &&
        shellExportLog == [
          "${output}/repos/nusurf"
          "${output}/repos/nusurf"
        ];
    expected = true;
  };

  localInputOverrides."test bootstrap reports a clear runtime manifest error for incomplete AgentRoots fixtures" =
    {
      expr =
        let
          output = runBootstrapFailure {
            derivationNamePrefix = "ar_bootstrap_shell_export_missing_runtime_entry";
            fixture = "recursive_agentroots";
            repoPath = "repos/nusurf";
            hydrateAgentroots = false;
            beforeRun = seedStubAgentrootsRuntime {
              targetRoot = "$out/repos/agentroots";
              includeModuleDevenv = false;
            };
          };
          stderr = builtins.readFile "${output}/stderr.txt";
        in
        lib.hasInfix "runtime manifest entry missing from AgentRoots input" stderr
        && lib.hasInfix "module/devenv.nix" stderr;
      expected = true;
    };

  localInputOverrides."test bootstrap all emits per-repo json summary" = {
    expr =
      let
        output = runBootstrapJson {
          derivationNamePrefix = "ar_bootstrap_all";
          fixture = "recursive_agentroots";
          repoPath = ".";
          extraArgs = [ "--all-repos" ];
        };
        status = readJson "${output}/status.json";
        resultRoots = builtins.map (result: stripContext result.repo_root) status.results;
      in
      status.repo_count == 7
      && status.success_count == 7
      && status.failure_count == 0
      &&
        resultRoots == [
          "${output}/repos/agentroots"
          "${output}/repos/app"
          "${output}/repos/ar_devenv_base"
          "${output}/repos/ar_devenv_docs"
          "${output}/repos/ar_devenv_rust"
          "${output}/repos/bootstrap_dep"
          "${output}/repos/nusurf"
        ]
      && lib.all (
        result: result.ok == true && result.status.shell_export_refreshed == true
      ) status.results;
    expected = true;
  };

  localInputOverrides."test bootstrap uses manifest dependency order and declared devenv files tasks" =
    {
      expr =
        let
          output = runBootstrap {
            derivationNamePrefix = "ar_bootstrap_declared_tasks";
            fixture = "cargo_path_agentroots";
            repoPath = "repos/app";
          };
          appManifestExists = builtins.pathExists "${output}/repos/app/Cargo.toml";
          depManifestExists = builtins.pathExists "${output}/repos/dep/Cargo.toml";
          transitiveManifestExists = builtins.pathExists "${output}/repos/transitive/Cargo.toml";
          filesLog = builtins.filter (line: line != "") (
            lib.splitString "\n" (builtins.readFile "${output}/devenv-files.log")
          );
        in
        appManifestExists
        && depManifestExists
        && transitiveManifestExists
        &&
          filesLog == [
            "${output}/repos/transitive"
            "${output}/repos/dep"
            "${output}/repos/app"
          ];
      expected = true;
    };
}
