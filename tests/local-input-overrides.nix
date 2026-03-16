{
  lib,
  pkgs,
  repoRoot,
}:
let
  pythonWithYaml = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
  fixtureRoot = "${toString repoRoot}/tests/fixtures";
  fixturePath = name: "${fixtureRoot}/${name}";
  stripContext = builtins.unsafeDiscardStringContext;
  generatorScript = builtins.path {
    path = "${toString repoRoot}/poly-local-inputs.py";
    name = "poly-local-inputs.py";
  };
  localInputOverridesModule = import "${repoRoot}/devenv.nix";

  readYaml =
    path:
    builtins.fromJSON (
      stripContext (
        builtins.readFile (
        pkgs.runCommand "poly-local-inputs-yaml-to-json"
          {
            nativeBuildInputs = [ pythonWithYaml ];
            pathString = path;
            passAsFile = [ "yamlText" ];
            yamlText = builtins.readFile path;
          }
          ''
            python3 - <<'PY' > "$out"
            import json
            import os
            import yaml

            document = yaml.safe_load(os.environ["yamlTextPath"] and open(os.environ["yamlTextPath"], encoding="utf-8").read()) or {}
            print(json.dumps(document, sort_keys=True))
            PY
          ''
        )
      )
    );

  runSync =
    {
      derivationNamePrefix,
      fixture,
      repoPath,
      extraArgs ? [ ],
      beforeSync ? "",
    }:
    pkgs.runCommand derivationNamePrefix
      {
        nativeBuildInputs = [ pythonWithYaml ];
        fixtureSource = builtins.path {
          path = fixturePath fixture;
          name = "${derivationNamePrefix}-fixture";
        };
        argsString = lib.escapeShellArgs extraArgs;
      }
      ''
        mkdir -p "$out"
        cp -R "$fixtureSource"/. "$out"/
        chmod -R u+w "$out"
        ${beforeSync}
        python3 ${generatorScript} sync "$out/${repoPath}" $argsString
      '';

  supportOptionsModule =
    { lib, ... }:
    {
      options = {
        assertions = lib.mkOption {
          type = lib.types.listOf (
            lib.types.submodule {
              options = {
                assertion = lib.mkOption { type = lib.types.bool; };
                message = lib.mkOption { type = lib.types.str; };
              };
            }
          );
          default = [ ];
        };

        devenv.root = lib.mkOption { type = lib.types.str; };

        files = lib.mkOption {
          type = lib.types.attrsOf (
            lib.types.submodule {
              options = {
                source = lib.mkOption {
                  type = lib.types.nullOr lib.types.path;
                  default = null;
                };
                text = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                };
              };
            }
          );
          default = { };
        };

        outputs = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };

        packages = lib.mkOption {
          type = lib.types.listOf lib.types.anything;
          default = [ ];
        };

        scripts = lib.mkOption {
          type = lib.types.attrsOf (
            lib.types.submodule {
              options.exec = lib.mkOption {
                type = lib.types.lines;
                default = "";
              };
            }
          );
          default = { };
        };

        enterTest = lib.mkOption {
          type = lib.types.lines;
          default = "";
        };
      };
    };

  evalLocalInputOverrides =
    {
      root,
      extraConfig ? { },
    }:
    lib.evalModules {
      modules = [
        localInputOverridesModule
        supportOptionsModule
        {
          _module.args = { inherit pkgs; };
        }
        (
          {
            devenv.root = root;
          }
          // extraConfig
        )
      ];
    };
in
{
  localInputOverrides."test sync emits transitive overrides and matching global imports" = {
    expr =
      let
        output = runSync {
          derivationNamePrefix = "local-input-overrides-sync-basic";
          fixture = "recursive-polyrepo";
          repoPath = "repos/app";
        };
        rendered = readYaml "${output}/repos/app/devenv.local.yaml";
      in
      stripContext rendered.inputs.agent-scripts.url
      == stripContext "path:${output}/repos/agent-scripts"
      && rendered.inputs.agent-scripts.flake == false
      && stripContext rendered.inputs.docs-shared.url
      == stripContext "path:${output}/repos/poly-docs-env"
      && rendered.inputs.docs-shared.flake == false
      && !(rendered.inputs ? remote-only)
      && rendered.imports == [
        "docs-shared/subdir"
        "agent-scripts/tooling"
      ];
    expected = true;
  };

  localInputOverrides."test sync honors include-input filters and git+file urls" = {
    expr =
      let
        output = runSync {
          derivationNamePrefix = "local-input-overrides-sync-filtered";
          fixture = "recursive-polyrepo";
          repoPath = "repos/app";
          extraArgs = [
            "--include-input"
            "agent-scripts"
            "--url-scheme"
            "git+file"
          ];
        };
        rendered = readYaml "${output}/repos/app/devenv.local.yaml";
      in
      builtins.attrNames rendered.inputs == [ "agent-scripts" ]
      && stripContext rendered.inputs.agent-scripts.url
      == stripContext "git+file:${output}/repos/agent-scripts"
      && rendered.imports == [ "agent-scripts/tooling" ];
    expected = true;
  };

  localInputOverrides."test sync removes stale output when no overrides remain" = {
    expr =
      let
        output = runSync {
          derivationNamePrefix = "local-input-overrides-sync-removes-stale";
          fixture = "no-local-polyrepo";
          repoPath = "repos/app";
          beforeSync = ''
            cat > "$out/repos/app/devenv.local.yaml" <<'EOF'
            inputs:
              stale:
                url: path:/tmp/stale
            EOF
          '';
        };
      in
      !(builtins.pathExists "${output}/repos/app/devenv.local.yaml");
    expected = true;
  };

  localInputOverrides."test module infers polyrepo root and materializes generated yaml" = {
    expr =
      let
        root = fixturePath "recursive-polyrepo/repos/app";
        result = evalLocalInputOverrides {
          inherit root;
        };
        rendered = readYaml result.config.outputs.local_input_overrides;
      in
      result.config.files."devenv.local.yaml".text != null
      && stripContext rendered.inputs.agent-scripts.url
      == stripContext "path:${fixturePath "recursive-polyrepo"}/repos/agent-scripts"
      && stripContext rendered.inputs.docs-shared.url
      == stripContext "path:${fixturePath "recursive-polyrepo"}/repos/poly-docs-env"
      && rendered.imports == [
        "docs-shared/subdir"
        "agent-scripts/tooling"
      ];
    expected = true;
  };

  localInputOverrides."test module records false assertion for overlapping repo filters" = {
    expr =
      let
        root = fixturePath "recursive-polyrepo/repos/app";
        result = evalLocalInputOverrides {
          inherit root;
          extraConfig.composer.localInputOverrides = {
            includeRepos = [ "agent-scripts" ];
            excludeRepos = [ "agent-scripts" ];
          };
        };
      in
      lib.any (
        assertion:
        assertion.assertion == false
        && assertion.message == "composer.localInputOverrides.includeRepos and excludeRepos must not overlap."
      ) result.config.assertions;
    expected = true;
  };

  localInputOverrides."test context throws when polyrepo root cannot be inferred" = {
    expr =
      import "${repoRoot}/nix/local-input-overrides/context.nix" {
        inherit lib;
        config = {
          devenv.root = fixturePath "standalone-repo";
          composer.localInputOverrides = {
            polyrepoRoot = null;
            repoDirsPath = "repos";
            sourcePath = "devenv.yaml";
            outputPath = "devenv.local.yaml";
            urlScheme = "path";
            includeRepos = [ ];
            excludeRepos = [ ];
            includeInputs = [ ];
            excludeInputs = [ ];
          };
        };
      };
    expectedError.type = "ThrownError";
    expectedError.msg = ".*polyrepoRoot must be set when the current repo is not nested under.*";
  };
}
