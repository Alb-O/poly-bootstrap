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
          let local_yaml_path = (pwd | path join "devenv.local.yaml")
          let local_doc = if ($local_yaml_path | path exists) {
            open --raw $local_yaml_path | from yaml | default {}
          } else {
            {}
          }
          let input_specs = ($local_doc | get -o inputs | default {})
          let root_inputs = (
            $input_specs
            | columns
            | each {|input_name| [$input_name $input_name] }
            | into record
          )
          let input_nodes = (
            $input_specs
            | items {|input_name, input_spec|
                [
                  $input_name
                  {
                    original: ($input_spec | get -o url | default null)
                  }
                ]
              }
            | into record
          )
          {
            root: "root"
            nodes: (
              ({ root: { inputs: $root_inputs } } | merge $input_nodes)
            )
          } | to json --raw | save --force (pwd | path join "devenv.lock")
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

        if (($args | str join " ") == "shell --no-tui --no-eval-cache --refresh-eval-cache -- bash -lc true") {
          let existing_calls = if ("SHELL_EXPORT_LOG" in $env) and ($env.SHELL_EXPORT_LOG | path exists) {
              open --raw $env.SHELL_EXPORT_LOG | lines | where {|line| $line != "" } | length
          } else {
            0
          }

          if "SHELL_EXPORT_LOG" in $env {
            $"(pwd)\n" | save --append --raw $env.SHELL_EXPORT_LOG
          }

          let export_index = ($existing_calls + 1)
          let shell_dir = (pwd | path join ".devenv")
          mkdir $shell_dir
          [
            "#!/usr/bin/env bash"
            "export DEVENV_FAKE=1"
            'eval "${shellHook:-}"'
          ] | str join "\n" | save --force ($shell_dir | path join $"shell-fake-($export_index).sh")
          return
        }

        error make { msg: $"unexpected devenv invocation: ($args | str join ' ')" }
      }
    '';
  };
  generatorSource = builtins.path {
    path = repoRoot;
    name = "agentroots-source";
  };
  agentroots_script = "${generatorSource}/bin/agentroots.nu";
  bootstrapScript = "${generatorSource}/bootstrap";
  fakeDevenvPackage = pkgs.runCommand "fake-devenv-package" { } ''
    mkdir -p "$out/bin"
    install -Dm755 ${fakeDevenvScript} "$out/bin/devenv"
  '';
  pkgsWithFakeDevenv = import pkgs.path {
    overlays = [
      (_final: _prev: {
        devenv = fakeDevenvPackage;
      })
    ];
  };
  toolingSupportOptionsModule =
    { lib, ... }:
    {
      options = {
        packages = lib.mkOption {
          type = lib.types.listOf lib.types.package;
          default = [ ];
        };

        outputs = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };
      };
    };

  readYaml =
    path:
    builtins.fromJSON (
      stripContext (
        builtins.readFile (
          pkgs.runCommand "agentroots-yaml-to-json"
            {
              nativeBuildInputs = [ pkgs.nushell ];
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

  evalSharedTooling =
    {
      root,
      pkgsForTooling ? pkgs,
    }:
    lib.evalModules {
      specialArgs = {
        pkgs = pkgsForTooling;
      };
      modules = [
        toolingSupportOptionsModule
        "${root}/repos/agentroots/tooling"
      ];
    };

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
        ${nu} ${agentroots_script} check "$repo_path" --json $argsString > "$out/status.json"
      '';
    };

  runSync =
    {
      derivationNamePrefix,
      fixture,
      repoPath,
      beforeRun ? "",
    }:
    runFixture {
      inherit derivationNamePrefix fixture repoPath beforeRun;
      script = ''
        ${nu} ${agentroots_script} sync "$repo_path"
      '';
    };

  runSyncJson =
    {
      derivationNamePrefix,
      fixture,
      repoPath,
      beforeRun ? "",
      prepare ? "",
    }:
    runFixture {
      inherit derivationNamePrefix fixture repoPath beforeRun;
      script = ''
        ${prepare}
        ${nu} ${agentroots_script} sync "$repo_path" --json > "$out/status.json"
      '';
    };

  runSyncFailure =
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
        set +e
        ${nu} ${agentroots_script} sync "$repo_path" $argsString > "$out/stdout.txt" 2> "$out/stderr.txt"
        status="$?"
        printf '%s' "$status" > "$out/exit-code.txt"
        if [ "$status" -eq 0 ]; then
          echo "expected sync to fail" >&2
          exit 1
        fi
      '';
    };

  runBootstrap =
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
        ${pkgs.bash}/bin/bash "${bootstrapScript}" "$repo_path" $argsString
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
        ${nu} ${agentroots_script} bootstrap "$repo_path" --json $argsString > "$out/status.json"
      '';
    };

  runBootstrapJsonTwice =
    {
      derivationNamePrefix,
      fixture,
      repoPath,
      extraArgs ? [ ],
      beforeRun ? "",
      betweenRuns ? "",
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
        ${nu} ${agentroots_script} bootstrap "$repo_path" --json $argsString > "$out/first-status.json"
        ${betweenRuns}
        ${nu} ${agentroots_script} bootstrap "$repo_path" --json $argsString > "$out/second-status.json"
      '';
    };

  runtimeFixture =
    derivationNamePrefix:
    runFixture {
      inherit derivationNamePrefix;
      fixture = "recursive_agentroots";
      repoPath = ".";
      beforeRun = ''
        rm -rf "$out/repos/agentroots"
        cp -R ${generatorSource}/. "$out/repos/agentroots"
        chmod -R u+w "$out/repos/agentroots"
      '';
      script = ":";
    };

  runPackagedDevenvRun =
    {
      derivationNamePrefix,
      sourceTree,
      devenvRunPackage,
    }:
    pkgs.runCommand derivationNamePrefix
      {
        nativeBuildInputs = [
          pkgs.gawk
          pkgs.bash
          pkgs.nushell
        ];
      }
      ''
        mkdir -p "$out"
        cp -R ${sourceTree}/. "$out"/
        chmod -R u+w "$out"
        mkdir -p "$out/report"
        if [ -f "$out/repos/app/.devenv/ar_shell_export.meta" ] && [ -f "$out/repos/app/.devenv/shell-fake-1.sh" ]; then
          awk -F= -v OFS== -v shell_export_path="$out/repos/app/.devenv/shell-fake-1.sh" '
            $1 == "AR_SHELL_EXPORT_PATH" {
              print $1, shell_export_path
              next
            }
            { print }
          ' "$out/repos/app/.devenv/ar_shell_export.meta" > "$out/repos/app/.devenv/ar_shell_export.meta.tmp"
          mv "$out/repos/app/.devenv/ar_shell_export.meta.tmp" "$out/repos/app/.devenv/ar_shell_export.meta"
        fi
        export REPORT_DIR="$out/report"
        export BOOTSTRAP_LOG="$out/bootstrap.log"
        export DEVENV_FILES_LOG="$out/devenv-files.log"
        export SHELL_EXPORT_LOG="$out/shell-export.log"
        export PATH="${devenvRunPackage}/bin:$PATH"
        "${devenvRunPackage}/bin/devenv-run" -C "$out/repos/app" --shell \
          'type -P devenv-run > "$REPORT_DIR/devenv-run-path.txt"; printf "%s\n" "''${DEVENV_FAKE:-}" > "$REPORT_DIR/devenv-fake.txt"'
      '';

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
      stripContext rendered.inputs.nusurf.url
      == stripContext "path:${output}/repos/nusurf"
      && stripContext rendered.inputs.agentroots.url
      == stripContext "path:${output}/repos/agentroots"
      && stripContext rendered.inputs.ar_rust_env.url
      == stripContext "path:${output}/repos/ar_rust_env"
      && rendered.imports == [
        "nusurf/nushell-plugin"
        "agentroots/tooling"
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
      && status.local_repo_count == 3
      && stripContext rendered.inputs.agentroots.url
      == stripContext "path:${output}/repos/agentroots"
      && rendered.imports == [
        "nusurf/nushell-plugin"
        "agentroots/tooling"
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
      && status.repo_count == 6
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
                  imports: [ "missing-input/tooling" ]
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
      && errorPaths == [
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
        bootstrapLog = builtins.filter (line: line != "") (lib.splitString "\n" (builtins.readFile "${output}/bootstrap.log"));
        filesLog = builtins.filter (line: line != "") (lib.splitString "\n" (builtins.readFile "${output}/devenv-files.log"));
      in
      status.target_name == "app"
      && status.dependency_repos == [ "bootstrap_dep" ]
      && stripContext appRendered.inputs.agentroots.url
      == stripContext "path:${output}/repos/agentroots"
      && stripContext depRendered.inputs.docs-shared.url
      == stripContext "path:${output}/repos/ar_docs_env"
      && bootstrapLog == [ "${output}/repos/app" ]
      && filesLog == [
        "${output}/repos/bootstrap_dep"
        "${output}/repos/app"
      ];
    expected = true;
  };

  localInputOverrides."test consumer tooling module exposes committer and devenv-run from AgentRoots tooling" = {
    expr =
      let
        output = runtimeFixture "ar_consumer_tooling_module";
        result = evalSharedTooling {
          root = output;
          pkgsForTooling = pkgsWithFakeDevenv;
        };
      in
      result.config.outputs ? committer
      && result.config.outputs ? devenv-run
      && builtins.pathExists "${result.config.outputs.committer}/bin/committer"
      && builtins.pathExists "${result.config.outputs.devenv-run}/bin/devenv-run";
    expected = true;
  };

  localInputOverrides."test bootstrap materializes a shell export and metadata for the target repo" = {
    expr =
      let
        output = runBootstrapJson {
          derivationNamePrefix = "ar_bootstrap_shell_export_meta";
          fixture = "recursive_agentroots";
          repoPath = "repos/app";
        };
        status = readJson "${output}/status.json";
        shellExportLog = builtins.filter (line: line != "") (lib.splitString "\n" (builtins.readFile "${output}/shell-export.log"));
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
        shellExportLog = builtins.filter (line: line != "") (lib.splitString "\n" (builtins.readFile "${output}/shell-export.log"));
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
        shellExportLog = builtins.filter (line: line != "") (lib.splitString "\n" (builtins.readFile "${output}/shell-export.log"));
      in
      secondStatus.shell_export_refreshed == true
      && secondStatus.shell_export_reason == "missing_meta"
      && shellExportLog == [
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
        shellExportLog = builtins.filter (line: line != "") (lib.splitString "\n" (builtins.readFile "${output}/shell-export.log"));
      in
      secondStatus.shell_export_refreshed == true
      && secondStatus.shell_export_reason == "meta_parse_error"
      && shellExportLog == [
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
        shellExportLog = builtins.filter (line: line != "") (lib.splitString "\n" (builtins.readFile "${output}/shell-export.log"));
      in
      secondStatus.shell_export_refreshed == true
      && secondStatus.shell_export_reason == "stale_fingerprint"
      && shellExportLog == [
        "${output}/repos/nusurf"
        "${output}/repos/nusurf"
      ];
    expected = true;
  };

  localInputOverrides."test bootstrap refreshes shell export when AgentRoots tooling changes" = {
    expr =
      let
        output = runBootstrapJsonTwice {
          derivationNamePrefix = "ar_bootstrap_shell_export_agentroots_change";
          fixture = "recursive_agentroots";
          repoPath = "repos/nusurf";
          beforeRun = ''
            mkdir -p "$out/repos/agentroots/bin" "$out/repos/agentroots/nu/agentroots" "$out/repos/agentroots/tooling"
            cat > "$out/repos/agentroots/bin/devenv-run.nu" <<'EOF'
            echo initial
            EOF
            cat > "$out/repos/agentroots/nu/agentroots/common.nu" <<'EOF'
            echo helper
            EOF
            cat > "$out/repos/agentroots/tooling/default.nix" <<'EOF'
            { }
            EOF
          '';
          betweenRuns = ''
            printf '\n# changed\n' >> "$out/repos/agentroots/bin/devenv-run.nu"
          '';
        };
        secondStatus = readJson "${output}/second-status.json";
        shellExportLog = builtins.filter (line: line != "") (lib.splitString "\n" (builtins.readFile "${output}/shell-export.log"));
      in
      secondStatus.shell_export_refreshed == true
      && secondStatus.shell_export_reason == "stale_fingerprint"
      && shellExportLog == [
        "${output}/repos/nusurf"
        "${output}/repos/nusurf"
      ];
    expected = true;
  };

  localInputOverrides."test packaged devenv-run refreshes shell export after AgentRoots wrapper source changes" = {
    expr =
      let
        initialSourceTree = runtimeFixture "ar_packaged_devenv_run_source_initial";
        initialTooling = evalSharedTooling {
          root = initialSourceTree;
          pkgsForTooling = pkgsWithFakeDevenv;
        };
        initialRun = runPackagedDevenvRun {
          derivationNamePrefix = "ar_packaged_devenv_run_initial";
          sourceTree = initialSourceTree;
          devenvRunPackage = initialTooling.config.outputs.devenv-run;
        };
        changedSourceTree = pkgs.runCommand "ar_packaged_devenv_run_source_changed" { } ''
          mkdir -p "$out"
          cp -R ${initialRun}/. "$out"/
          chmod -R u+w "$out"
          printf '\n# changed\n' >> "$out/repos/agentroots/nu/agentroots/devenv_run.nu"
        '';
        changedTooling = evalSharedTooling {
          root = changedSourceTree;
          pkgsForTooling = pkgsWithFakeDevenv;
        };
        changedRun = runPackagedDevenvRun {
          derivationNamePrefix = "ar_packaged_devenv_run_changed";
          sourceTree = changedSourceTree;
          devenvRunPackage = changedTooling.config.outputs.devenv-run;
        };
        initialShellExportLog = builtins.filter (line: line != "") (lib.splitString "\n" (builtins.readFile "${initialRun}/shell-export.log"));
        changedShellExportLog = builtins.filter (line: line != "") (lib.splitString "\n" (builtins.readFile "${changedRun}/shell-export.log"));
      in
      initialTooling.config.outputs.devenv-run != changedTooling.config.outputs.devenv-run
      && builtins.readFile "${initialRun}/report/devenv-run-path.txt"
      != builtins.readFile "${changedRun}/report/devenv-run-path.txt"
      && builtins.readFile "${initialRun}/report/devenv-fake.txt" == "1\n"
      && builtins.readFile "${changedRun}/report/devenv-fake.txt" == "1\n"
      && (builtins.length initialShellExportLog) == 1
      && (builtins.length changedShellExportLog) == 2;
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
      status.repo_count == 6
      && status.success_count == 6
      && status.failure_count == 0
      && resultRoots == [
        "${output}/repos/agentroots"
        "${output}/repos/app"
        "${output}/repos/ar_docs_env"
        "${output}/repos/ar_rust_env"
        "${output}/repos/bootstrap_dep"
        "${output}/repos/nusurf"
      ]
      && lib.all (result: result.ok == true && result.status.shell_export_refreshed == true) status.results;
    expected = true;
  };

  localInputOverrides."test bootstrap uses manifest dependency order and declared devenv files tasks" = {
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
        filesLog = builtins.filter (line: line != "") (lib.splitString "\n" (builtins.readFile "${output}/devenv-files.log"));
      in
      appManifestExists
      && depManifestExists
      && transitiveManifestExists
      && filesLog == [
        "${output}/repos/transitive"
        "${output}/repos/dep"
        "${output}/repos/app"
      ];
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
      lib.hasInfix "manifest-owned repo catalog" stderr
      && lib.hasInfix "agentroots.nuon" stderr;
    expected = true;
  };
}
