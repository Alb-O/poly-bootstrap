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
    runCheckJson
    ;
in
{
  localInputOverrides."test check json reports valid manifest catalog status" = {
    expr =
      let
        output = runCheckJson {
          derivationNamePrefix = "ar_check_valid";
          fixture = "recursive_agentroots";
          repoPath = ".";
        };
        status = readJson "${output}/status.json";
      in
      status.ok == true
      && status.repo_count == 7
      && status.group_count == 1
      && status.layer_count == 3
      && status.error_count == 0;
    expected = true;
  };

  localInputOverrides."test check json aggregates manifest reference errors" = {
    expr =
      let
        output = runCheckJson {
          derivationNamePrefix = "ar_check_invalid";
          fixture = "recursive_agentroots";
          repoPath = ".";
          beforeRun = ''
            cat > "$out/agentroots.nuon" <<'EOF'
            {
              repoDirsPath: "repos"

              root: {
                layers: [ "missing-root-layer" ]
              }

              inputs: {
                alias: {
                  url: "github:Alb-O/alias"
                  flake: false
                  localRepo: "missing-repo"
                  requiresInputs: [ "missing-input" ]
                }
              }

              layers: {
                broken: {
                  extends: [ "missing-layer" ]
                  inputs: [ "missing-input" ]
                  imports: [ "missing-input/module" ]
                }
              }

              repos: {
                app: {
                  path: "repos/app"
                  layers: [ "broken" "missing-layer" ]
                  bootstrapDeps: [ "missing-repo" ]
                }
              }
            }
            EOF
          '';
        };
        status = readJson "${output}/status.json";
        errorPaths = builtins.map (entry: entry.path) status.errors;
      in
      status.ok == false
      && status.error_count == 9
      &&
        errorPaths == [
          "root.layers"
          "inputs.alias.localRepo"
          "inputs.alias.requiresInputs"
          "layers.broken.extends"
          "layers.broken.inputs"
          "layers.broken.imports"
          "layers.broken"
          "repos.app.layers"
          "repos.app.bootstrapDeps"
        ];
    expected = true;
  };
}
