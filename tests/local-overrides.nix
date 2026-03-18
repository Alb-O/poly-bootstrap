{
  lib,
  pkgs,
  repoRoot,
}:
let
  nu = lib.getExe pkgs.nushell;
  fixtureRoot = "${toString repoRoot}/tests/fixtures";
  fixturePath = name: "${fixtureRoot}/${name}";
  stripContext = builtins.unsafeDiscardStringContext;
  staleLocalOverridesFile = pkgs.writeText "stale-devenv-local.yaml" ''
    inputs:
      stale:
        url: path:/tmp/stale
  '';
  fakeDevenvScript = pkgs.writeTextFile {
    name = "fake-devenv";
    executable = true;
    text = ''
      #!${nu}

      def --wrapped main [...raw_args] {
        let args = ($raw_args | each {|arg| $arg | into string })

        if (($args | length) > 0) and (($args | get 0) == "update") {
          $"(pwd)\n" | save --append --raw $env.BOOTSTRAP_LOG
          return
        }

        if (($args | str join " ") == "tasks --no-tui --no-eval-cache --refresh-eval-cache run devenv:files") {
          if ("DEVENV_FILES_LOG" in $env) {
            $"(pwd)\n" | save --append --raw $env.DEVENV_FILES_LOG
          }

          let manifest_path = (pwd | path join "Cargo.toml")
          let spec_path = (pwd | path join "Cargo.poly.toml")

          if (not ($manifest_path | path exists)) and ($spec_path | path exists) {
            open --raw $spec_path | save --force $manifest_path
          }

          return
        }

        if (($args | str join " ") == "shell --no-tui -- bash -lc true") {
          if ("SHELL_EXPORT_LOG" in $env) {
            $"(pwd)\n" | save --append --raw $env.SHELL_EXPORT_LOG
          }

          let shell_dir = (pwd | path join ".devenv")
          mkdir $shell_dir
          [
            "#!/usr/bin/env bash"
            "export DEVENV_FAKE=1"
            'eval "${shellHook:-}"'
          ] | str join "\n" | save --force ($shell_dir | path join "shell-fake.sh")
          return
        }

        error make { msg: $"unexpected devenv invocation: ($args | str join ' ')" }
      }
    '';
  };
  generatorSource = builtins.path {
    path = repoRoot;
    name = "poly-bootstrap-source";
  };
  generatorScript = "${generatorSource}/bin/local-overrides.nu";
  bootstrapScript = "${generatorSource}/bootstrap";
  localInputOverridesModule = import "${repoRoot}/devenv.nix";

  readYaml =
    path:
    builtins.fromJSON (
      stripContext (
        builtins.readFile (
        pkgs.runCommand "poly-bootstrap-yaml-to-json"
          {
            nativeBuildInputs = [ pkgs.nushell ];
            pathString = path;
            passAsFile = [ "yamlText" ];
            yamlText = builtins.readFile path;
          }
          ''
            ${nu} -c '
              let raw = (open --raw $env.yamlTextPath)
              if ($raw | str trim | is-empty) {
                {}
              } else {
                $raw | from yaml
              } | to json --raw
            ' > "$out"
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
        nativeBuildInputs = [ pkgs.nushell ];
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

  runCheckJson =
    {
      derivationNamePrefix,
      fixture,
      repoPath,
      beforeRun ? "",
      extraArgs ? [ ],
    }:
    runFixture {
      inherit derivationNamePrefix fixture repoPath extraArgs beforeRun;
      script = ''
        ${nu} ${generatorScript} check "$repo_path" --json $argsString > "$out/status.json"
      '';
    };

  runSyncFailure =
    {
      derivationNamePrefix,
      fixture,
      repoPath,
      extraArgs ? [ ],
    }:
    runFixture {
      inherit derivationNamePrefix fixture repoPath extraArgs;
      script = ''
        set +e
        ${nu} ${generatorScript} sync "$repo_path" $argsString > "$out/stdout.txt" 2> "$out/stderr.txt"
        status="$?"
        printf '%s' "$status" > "$out/exit-code.txt"
        if [ "$status" -eq 0 ]; then
          echo "expected sync to fail" >&2
          exit 1
        fi
      '';
    };

  runModuleSync =
    {
      derivationNamePrefix,
      fixture,
      repoPath,
      beforeSync ? "",
    }:
    pkgs.runCommand derivationNamePrefix
      {
        nativeBuildInputs = [ pkgs.nushell ];
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
          use nu/mod.nu [bootstrap render-local-overrides sync-local-overrides lock-status]

          let sync_status = sync-local-overrides { repo_root: $env.REPO_PATH }
          {
            sync: $sync_status
            lock: (lock-status $sync_status.output_path ($env.REPO_PATH | path join "devenv.lock"))
          } | to json --raw
        ' > "$out/status.json"
      '';

  runBootstrap =
    {
      derivationNamePrefix,
      fixture,
      repoPath,
    }:
    runFixture {
      inherit derivationNamePrefix fixture repoPath;
      script = ''
        mkdir -p "$out/bin"
        install -Dm755 ${fakeDevenvScript} "$out/bin/devenv"
        export PATH="$out/bin:$PATH"
        export BOOTSTRAP_LOG="$out/bootstrap.log"
        export DEVENV_FILES_LOG="$out/devenv-files.log"
        export SHELL_EXPORT_LOG="$out/shell-export.log"
        ${pkgs.bash}/bin/bash "${bootstrapScript}" "$repo_path" --polyrepo-root "$out"
      '';
    };

  runBootstrapJson =
    {
      derivationNamePrefix,
      fixture,
      repoPath,
      extraArgs ? [ ],
      beforeRun ? "",
    }:
    runFixture {
      inherit derivationNamePrefix fixture repoPath extraArgs beforeRun;
      script = ''
        mkdir -p "$out/bin"
        install -Dm755 ${fakeDevenvScript} "$out/bin/devenv"
        export PATH="$out/bin:$PATH"
        export BOOTSTRAP_LOG="$out/bootstrap.log"
        export DEVENV_FILES_LOG="$out/devenv-files.log"
        export SHELL_EXPORT_LOG="$out/shell-export.log"
        ${pkgs.bash}/bin/bash "${bootstrapScript}" --json "$repo_path" --polyrepo-root "$out" $argsString > "$out/status.json"
      '';
    };

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
  localInputOverrides."test sync emits explicit input closure overrides and matching global imports" = {
    expr =
      let
        output = runSync {
          derivationNamePrefix = "local-overrides-sync-basic";
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
        "agent-scripts/tooling"
        "nusurf/nushell-plugin"
        "docs-shared/subdir"
      ];
    expected = true;
  };

  localInputOverrides."test sync honors include-input filters and git+file urls" = {
    expr =
      let
        output = runSync {
          derivationNamePrefix = "local-overrides-sync-filtered";
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
          derivationNamePrefix = "local-overrides-sync-removes-stale";
          fixture = "no-local-polyrepo";
          repoPath = "repos/app";
          beforeRun = ''
            install -Dm644 ${staleLocalOverridesFile} "$out/repos/app/devenv.local.yaml"
          '';
        };
      in
      !(builtins.pathExists "${output}/repos/app/devenv.local.yaml");
    expected = true;
  };

  localInputOverrides."test sync no longer depends on consumer devenv yaml" = {
    expr =
      let
        output = runSync {
          derivationNamePrefix = "local-overrides-sync-without-source-yaml";
          fixture = "recursive-polyrepo";
          repoPath = "repos/app";
          beforeRun = ''
            mkdir "$out/repos/app/.git"
            rm "$out/repos/app/devenv.yaml"
          '';
        };
        rendered = readYaml "${output}/repos/app/devenv.local.yaml";
      in
      stripContext rendered.inputs.agent-scripts.url
      == stripContext "path:${output}/repos/agent-scripts"
      && stripContext rendered.inputs.docs-shared.url
      == stripContext "path:${output}/repos/poly-docs-env";
    expected = true;
  };

  localInputOverrides."test sync allows polyrepo root outside repo catalog" = {
    expr =
      let
        output = runSyncJson {
          derivationNamePrefix = "local-overrides-sync-polyrepo-root";
          fixture = "recursive-polyrepo";
          repoPath = ".";
          extraArgs = [
            "--polyrepo-root"
            "."
          ];
          beforeSync = ''
            cat > "$out/devenv.yaml" <<'EOF'
            inputs: {}
            imports: []
            EOF
          '';
        };
        status = readJson "${output}/status.json";
        rendered = readYaml "${output}/devenv.local.yaml";
      in
      status.mode == "written"
      && status.changed == true
      && status.local_repo_count == 4
      && stripContext rendered.inputs.agent-scripts.url
      == stripContext "path:${output}/repos/agent-scripts"
      && stripContext rendered.inputs.docs-shared.url
      == stripContext "path:${output}/repos/poly-docs-env"
      && rendered.imports == [
        "agent-scripts/tooling"
        "nusurf/nushell-plugin"
        "docs-shared/subdir"
      ];
    expected = true;
  };

  localInputOverrides."test render-manifest emits expected yaml" = {
    expr =
      let
        fixture = fixturePath "recursive-polyrepo";
        rendered = readYaml (
          runRenderManifest {
            derivationNamePrefix = "local-overrides-render-manifest";
            manifest = {
              current_repo_name = "app";
              polyrepo_manifest_text = builtins.readFile "${fixture}/polyrepo.nuon";
              local_repo_paths = {
                agent-scripts = "${fixture}/repos/agent-scripts";
                app = "${fixture}/repos/app";
                nusurf = "${fixture}/repos/nusurf";
                poly-docs-env = "${fixture}/repos/poly-docs-env";
                poly-rust-env = "${fixture}/repos/poly-rust-env";
              };
              include_inputs = [ ];
              exclude_inputs = [ ];
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
        "agent-scripts/tooling"
        "nusurf/nushell-plugin"
        "docs-shared/subdir"
      ];
    expected = true;
  };

  localInputOverrides."test render-manifest accepts polyrepo manifest text" = {
    expr =
      let
        fixture = fixturePath "recursive-polyrepo";
        rendered = readYaml (
          runRenderManifest {
            derivationNamePrefix = "local-overrides-render-manifest-polyrepo";
            manifest = {
              current_repo_name = "app";
              polyrepo_manifest_text = builtins.readFile "${fixture}/polyrepo.nuon";
              local_repo_paths = {
                agent-scripts = "${fixture}/repos/agent-scripts";
                app = "${fixture}/repos/app";
                nusurf = "${fixture}/repos/nusurf";
                poly-docs-env = "${fixture}/repos/poly-docs-env";
                poly-rust-env = "${fixture}/repos/poly-rust-env";
              };
              include_inputs = [ ];
              exclude_inputs = [ ];
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
        "agent-scripts/tooling"
        "nusurf/nushell-plugin"
        "docs-shared/subdir"
      ];
    expected = true;
  };

  localInputOverrides."test sync json reports written status and missing lock" = {
    expr =
      let
        output = runSyncJson {
          derivationNamePrefix = "local-overrides-sync-json-written";
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

  localInputOverrides."test check json reports valid manifest catalog status" = {
    expr =
      let
        output = runCheckJson {
          derivationNamePrefix = "local-overrides-check-json-valid";
          fixture = "recursive-polyrepo";
          repoPath = ".";
          extraArgs = [
            "--polyrepo-root"
            "."
          ];
        };
        status = readJson "${output}/status.json";
      in
      status.ok == true
      && status.error_count == 0
      && status.repo_count == 5
      && status.resolved_repo_count == 5;
    expected = true;
  };

  localInputOverrides."test check json aggregates manifest reference errors" = {
    expr =
      let
        output = runCheckJson {
          derivationNamePrefix = "local-overrides-check-json-invalid";
          fixture = "recursive-polyrepo";
          repoPath = ".";
          beforeRun = ''
            cat > "$out/polyrepo.nuon" <<'EOF'
            {
              repoDirsPath: "repos"

              rootProfiles: [ "missing-root-profile" ]
              repoDefaultProfiles: [ "shared-tooling" ]

              inputs: {
                agent-scripts: {
                  url: "github:Alb-O/agent-scripts"
                  flake: false
                  imports: [ "agent-scripts/tooling" ]
                  requiresInputs: [ "missing-input" ]
                }
                alias: {
                  url: "github:Alb-O/alias"
                  flake: false
                  localRepo: "missing-repo"
                }
              }

              bundles: {
                app: {
                  extends: [ "missing-bundle" ]
                  inputs: [ "agent-scripts" ]
                }
              }

              profiles: {
                shared-tooling: {
                  imports: [ "missing-input/tooling" ]
                }
              }

              repos: {
                app: {
                  path: "repos/app"
                  bundle: "missing-bundle"
                  profiles: [ "missing-repo-profile" ]
                }
              }
            }
            EOF
          '';
          extraArgs = [
            "--polyrepo-root"
            "."
          ];
        };
        status = readJson "${output}/status.json";
        errorPaths = builtins.map (entry: entry.path) status.errors;
      in
      status.ok == false
      && status.error_count == 7
      && errorPaths == [
        "rootProfiles"
        "inputs.agent-scripts.requiresInputs"
        "inputs.alias.localRepo"
        "bundles.app.extends"
        "profiles.shared-tooling.imports"
        "repos.app.bundle"
        "repos.app.profiles"
      ];
    expected = true;
  };

  localInputOverrides."test sync json reports unchanged status when rerun" = {
    expr =
      let
        output = runSyncJson {
          derivationNamePrefix = "local-overrides-sync-json-unchanged";
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

  localInputOverrides."test sync reports clearer repo catalog mismatch errors" = {
    expr =
      let
        output = runSyncFailure {
          derivationNamePrefix = "local-overrides-sync-clearer-current-repo-error";
          fixture = "recursive-polyrepo";
          repoPath = "repos/app";
          extraArgs = [
            "--include-repo"
            "agent-scripts"
          ];
        };
        stderr = builtins.readFile "${output}/stderr.txt";
      in
      lib.hasInfix "manifest-owned repo catalog after repo filters" stderr
      && lib.hasInfix "available repo names: agent-scripts" stderr
      && lib.hasInfix "polyrepo.nuon" stderr;
    expected = true;
  };

  localInputOverrides."test sync json exposes declared local repo roots" = {
    expr =
      let
        output = runSyncJson {
          derivationNamePrefix = "local-overrides-sync-json-roots";
          fixture = "recursive-polyrepo";
          repoPath = "repos/app";
        };
        status = readJson "${output}/status.json";
      in
      status.local_repo_count == 4
      && status.local_repo_names == [
        "agent-scripts"
        "nusurf"
        "poly-docs-env"
        "poly-rust-env"
      ];
    expected = true;
  };

  localInputOverrides."test sync json reports removed status for stale output cleanup" = {
    expr =
      let
        output = runSyncJson {
          derivationNamePrefix = "local-overrides-sync-json-removed";
          fixture = "no-local-polyrepo";
          repoPath = "repos/app";
          beforeSync = ''
            install -Dm644 ${staleLocalOverridesFile} "$out/repos/app/devenv.local.yaml"
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
        "agent-scripts/tooling"
        "nusurf/nushell-plugin"
        "docs-shared/subdir"
      ];
    expected = true;
  };

  localInputOverrides."test bootstrap recurses into local dependency repos before update" = {
    expr =
      let
        output = runBootstrap {
          derivationNamePrefix = "local-overrides-bootstrap-recursive";
          fixture = "recursive-polyrepo";
          repoPath = "repos/app";
        };
        appRendered = readYaml "${output}/repos/app/devenv.local.yaml";
        depRendered = readYaml "${output}/repos/agent-scripts/devenv.local.yaml";
        bootstrapLog = builtins.filter (line: line != "") (lib.splitString "\n" (builtins.readFile "${output}/bootstrap.log"));
      in
      stripContext appRendered.inputs.agent-scripts.url
      == stripContext "path:${output}/repos/agent-scripts"
      && stripContext depRendered.inputs.docs-shared.url
      == stripContext "path:${output}/repos/poly-docs-env"
      && bootstrapLog == [ "${output}/repos/app" ];
    expected = true;
  };

  localInputOverrides."test bootstrap materializes a shell export for the root repo" = {
    expr =
      let
        output = runBootstrap {
          derivationNamePrefix = "local-overrides-bootstrap-shell-export";
          fixture = "recursive-polyrepo";
          repoPath = "repos/app";
        };
        shellExportLog = builtins.filter (line: line != "") (lib.splitString "\n" (builtins.readFile "${output}/shell-export.log"));
      in
      builtins.pathExists "${output}/repos/app/.devenv/shell-fake.sh"
      && shellExportLog == [ "${output}/repos/app" ];
    expected = true;
  };

  localInputOverrides."test bootstrap all emits per-repo json summary" = {
    expr =
      let
        output = runBootstrapJson {
          derivationNamePrefix = "local-overrides-bootstrap-all-json";
          fixture = "recursive-polyrepo";
          repoPath = ".";
          extraArgs = [ "--all-repos" ];
        };
        status = readJson "${output}/status.json";
        resultRoots = builtins.map (result: stripContext result.repo_root) status.results;
      in
      status.repo_count == 5
      && status.success_count == 5
      && status.failure_count == 0
      && resultRoots == [
        "${output}/repos/agent-scripts"
        "${output}/repos/app"
        "${output}/repos/nusurf"
        "${output}/repos/poly-docs-env"
        "${output}/repos/poly-rust-env"
      ]
      && lib.all (result: result.ok == true && result.status.shell_export_refreshed == true) status.results;
    expected = true;
  };

  localInputOverrides."test bootstrap materializes managed Cargo manifests for local path dependency repos" = {
    expr =
      let
        output = runBootstrap {
          derivationNamePrefix = "local-overrides-bootstrap-cargo-path-deps";
          fixture = "cargo-path-polyrepo";
          repoPath = "repos/app";
        };
        appManifestExists = builtins.pathExists "${output}/repos/app/Cargo.toml";
        depManifestExists = builtins.pathExists "${output}/repos/dep/Cargo.toml";
        transitiveManifestExists = builtins.pathExists "${output}/repos/transitive/Cargo.toml";
        filesLog = builtins.filter (line: line != "") (lib.splitString "\n" (builtins.readFile "${output}/devenv-files.log"));
      in
      appManifestExists
      && depManifestExists
      && transitiveManifestExists
      && filesLog
      == [
        "${output}/repos/transitive"
        "${output}/repos/dep"
        "${output}/repos/app"
      ];
    expected = true;
  };

  localInputOverrides."test supported nu module exports bootstrap sync and lock helpers" = {
    expr =
      let
        output = runModuleSync {
          derivationNamePrefix = "local-overrides-module-sync";
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
      import "${repoRoot}/nix/local-overrides/context.nix" {
        inherit lib;
        config = {
          devenv.root = fixturePath "standalone-repo";
          composer.localInputOverrides = {
            polyrepoRoot = null;
            repoDirsPath = null;
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
    expectedError.msg = ".*polyrepoRoot must be set when devenv.root is not nested under a polyrepo.nuon root with a repos entry for the current repo.*";
  };
}
