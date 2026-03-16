{
  lib,
  pkgs,
  repoRoot,
}:
let
  pythonWithYaml = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
  nu = lib.getExe pkgs.nushell;
  fixtureRoot = "${toString repoRoot}/tests/fixtures";
  fixturePath = name: "${fixtureRoot}/${name}";
  stripContext = builtins.unsafeDiscardStringContext;
  generatorSource = builtins.path {
    path = repoRoot;
    name = "poly-local-inputs-source";
  };
  generatorScript = "${generatorSource}/poly-local-inputs.nu";
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

  readJson = path: builtins.fromJSON (stripContext (builtins.readFile path));

  runFixture =
    {
      derivationNamePrefix,
      fixture,
      repoPath,
      extraArgs ? [ ],
      beforeRun ? "",
      script,
    }:
    pkgs.runCommand derivationNamePrefix
      {
        nativeBuildInputs = [
          pkgs.nushell
          pythonWithYaml
        ];
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
        repo_path="$out/${repoPath}"
        ${beforeRun}
        ${script}
      '';

  runSync =
    args:
    runFixture (
      args
      // {
        script = ''
          ${nu} ${generatorScript} sync "$repo_path" $argsString
        '';
      }
    );

  runSyncJson =
    {
      derivationNamePrefix,
      fixture,
      repoPath,
      extraArgs ? [ ],
      beforeSync ? "",
      prepare ? "",
    }:
    runFixture {
      inherit derivationNamePrefix fixture repoPath extraArgs;
      beforeRun = beforeSync;
      script = ''
        ${prepare}
        ${nu} ${generatorScript} sync --json "$repo_path" $argsString > "$out/status.json"
      '';
    };

  runRenderManifest =
    {
      derivationNamePrefix,
      manifest,
    }:
    pkgs.runCommand derivationNamePrefix
      {
        nativeBuildInputs = [ pkgs.nushell ];
        passAsFile = [ "manifestJson" ];
        manifestJson = builtins.toJSON manifest;
      }
      ''
        ${nu} ${generatorScript} render-manifest "$manifestJsonPath" > "$out"
      '';

  runModuleSync =
    {
      derivationNamePrefix,
      fixture,
      repoPath,
      beforeSync ? "",
    }:
    pkgs.runCommand derivationNamePrefix
      {
        nativeBuildInputs = [
          pkgs.nushell
          pythonWithYaml
        ];
        fixtureSource = builtins.path {
          path = fixturePath fixture;
          name = "${derivationNamePrefix}-fixture";
        };
      }
      ''
        mkdir -p "$out"
        cp -R "$fixtureSource"/. "$out"/
        chmod -R u+w "$out"
        export REPO_PATH="$out/${repoPath}"
        ${beforeSync}
        cd "${generatorSource}"
        ${nu} -c '
          use nu/mod.nu [render-local-overrides sync-local-overrides lock-status]

          let sync_status = sync-local-overrides { repo_root: $env.REPO_PATH }
          {
            sync: $sync_status
            lock: (lock-status $sync_status.output_path ($env.REPO_PATH | path join "devenv.lock"))
          } | to json --raw
        ' > "$out/status.json"
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
          beforeRun = ''
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

  localInputOverrides."test render-manifest emits expected yaml" = {
    expr =
      let
        fixture = fixturePath "recursive-polyrepo";
        rendered = readYaml (
          runRenderManifest {
            derivationNamePrefix = "local-input-overrides-render-manifest";
            manifest = {
              source_yaml_text = builtins.readFile "${fixture}/repos/app/devenv.yaml";
              global_inputs_yaml_text = builtins.readFile "${fixture}/.devenv-global-inputs.yaml";
              local_repo_names = [
                "agent-scripts"
                "poly-docs-env"
              ];
              repo_sources = {
                agent-scripts = builtins.readFile "${fixture}/repos/agent-scripts/devenv.yaml";
                poly-docs-env = builtins.readFile "${fixture}/repos/poly-docs-env/devenv.yaml";
              };
              include_inputs = [ ];
              exclude_inputs = [ ];
              repo_dirs_root = "${fixture}/repos";
              url_scheme = "path";
            };
          }
        );
      in
      stripContext rendered.inputs.agent-scripts.url
      == stripContext "path:${fixturePath "recursive-polyrepo"}/repos/agent-scripts"
      && stripContext rendered.inputs.docs-shared.url
      == stripContext "path:${fixturePath "recursive-polyrepo"}/repos/poly-docs-env"
      && rendered.imports == [
        "docs-shared/subdir"
        "agent-scripts/tooling"
      ];
    expected = true;
  };

  localInputOverrides."test sync json reports written status and missing lock" = {
    expr =
      let
        output = runSyncJson {
          derivationNamePrefix = "local-input-overrides-sync-json-written";
          fixture = "recursive-polyrepo";
          repoPath = "repos/app";
        };
        status = readJson "${output}/status.json";
      in
      status.mode == "written"
      && status.changed == true
      && status.removed == false
      && status.lock_status.status == "missing-lock"
      && status.lock_refresh_needed == true;
    expected = true;
  };

  localInputOverrides."test sync json reports unchanged status when rerun" = {
    expr =
      let
        output = runSyncJson {
          derivationNamePrefix = "local-input-overrides-sync-json-unchanged";
          fixture = "recursive-polyrepo";
          repoPath = "repos/app";
          prepare = ''
            ${nu} ${generatorScript} sync "$repo_path"
          '';
        };
        status = readJson "${output}/status.json";
      in
      status.mode == "unchanged"
      && status.changed == false
      && status.removed == false
      && status.lock_status.status == "missing-lock"
      && status.lock_refresh_needed == true;
    expected = true;
  };

  localInputOverrides."test sync json reports removed status for stale output cleanup" = {
    expr =
      let
        output = runSyncJson {
          derivationNamePrefix = "local-input-overrides-sync-json-removed";
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
        status = readJson "${output}/status.json";
      in
      status.mode == "removed"
      && status.changed == true
      && status.removed == true
      && status.lock_status.status == "clean"
      && status.lock_refresh_needed == false
      && !(builtins.pathExists "${output}/repos/app/devenv.local.yaml");
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

  localInputOverrides."test supported nu module exports sync and lock helpers" = {
    expr =
      let
        output = runModuleSync {
          derivationNamePrefix = "local-input-overrides-module-sync";
          fixture = "recursive-polyrepo";
          repoPath = "repos/app";
        };
        status = readJson "${output}/status.json";
        rendered = readYaml "${output}/repos/app/devenv.local.yaml";
      in
      status.sync.mode == "written"
      && status.sync.changed == true
      && status.sync.lock_status.status == "missing-lock"
      && status.lock.status == "missing-lock"
      && stripContext rendered.inputs.agent-scripts.url
      == stripContext "path:${output}/repos/agent-scripts";
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
