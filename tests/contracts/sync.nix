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
    runSync
    runSyncFailure
    runSyncJson
    staleLocalOverridesFile
    stripContext
    ;
in
{
  localInputOverrides."test sync emits local overrides and imports for repo target" = {
    expr =
      let
        output = runSync {
          derivationNamePrefix = "ar_sync_basic";
          fixture = "recursive_agentroots";
          repoPath = "repos/app";
        };
        rendered = readYaml "${output}/repos/app/devenv.local.yaml";
      in
      stripContext rendered.inputs.nusurf.url == stripContext "path:${output}/repos/nusurf"
      &&
        stripContext rendered.inputs.ar_devenv_base.url
        == stripContext "path:${output}/repos/ar_devenv_base"
      && stripContext rendered.inputs.agentroots.url == stripContext "path:${output}/repos/agentroots"
      &&
        stripContext rendered.inputs.ar_devenv_rust.url
        == stripContext "path:${output}/repos/ar_devenv_rust"
      &&
        rendered.imports == [
          "ar_devenv_base"
          "nusurf/nushell-plugin"
          "agentroots/module"
        ];
    expected = true;
  };

  localInputOverrides."test sync allows the AgentRoots root as a first-class target" = {
    expr =
      let
        output = runSyncJson {
          derivationNamePrefix = "ar_sync_root";
          fixture = "recursive_agentroots";
          repoPath = ".";
          beforeRun = ''
            cat > "$out/devenv.yaml" <<'EOF'
            inputs: {}
            imports: []
            EOF
          '';
        };
        status = readJson "${output}/status.json";
        rendered = readYaml "${output}/devenv.local.yaml";
      in
      status.target_kind == "root"
      && status.mode == "written"
      && status.local_repo_count == 4
      &&
        stripContext rendered.inputs.ar_devenv_base.url
        == stripContext "path:${output}/repos/ar_devenv_base"
      && stripContext rendered.inputs.agentroots.url == stripContext "path:${output}/repos/agentroots"
      &&
        rendered.imports == [
          "ar_devenv_base"
          "nusurf/nushell-plugin"
          "agentroots/module"
        ];
    expected = true;
  };

  localInputOverrides."test sync removes stale output when no local overrides remain" = {
    expr =
      let
        output = runSyncJson {
          derivationNamePrefix = "ar_sync_removes_stale";
          fixture = "no_local_agentroots";
          repoPath = "repos/app";
          beforeRun = ''
            install -Dm644 ${staleLocalOverridesFile} "$out/repos/app/devenv.local.yaml"
          '';
        };
        status = readJson "${output}/status.json";
      in
      status.mode == "removed"
      && status.removed == true
      && !(builtins.pathExists "${output}/repos/app/devenv.local.yaml");
    expected = true;
  };

  localInputOverrides."test sync reports clearer repo catalog mismatch errors" = {
    expr =
      let
        output = runSyncFailure {
          derivationNamePrefix = "ar_sync_clearer_current_repo_error";
          fixture = "recursive_agentroots";
          repoPath = "repos/missing";
          beforeRun = ''
            mkdir -p "$out/repos/missing"
            cat > "$out/repos/missing/devenv.yaml" <<'EOF'
            inputs: {}
            imports: []
            EOF
          '';
        };
        stderr = builtins.readFile "${output}/stderr.txt";
      in
      lib.hasInfix "manifest-owned repo catalog" stderr && lib.hasInfix "agentroots.nuon" stderr;
    expected = true;
  };
}
