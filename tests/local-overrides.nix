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
  polyrepoScript = "${generatorSource}/bin/polyrepo.nu";
  bootstrapScript = "${generatorSource}/bootstrap";

  readYaml =
    path:
    builtins.fromJSON (
      stripContext (
        builtins.readFile (
          pkgs.runCommand "poly-bootstrap-yaml-to-json"
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
        ${nu} ${polyrepoScript} check "$repo_path" --json $argsString > "$out/status.json"
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
        ${nu} ${polyrepoScript} sync "$repo_path"
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
        ${nu} ${polyrepoScript} sync "$repo_path" --json > "$out/status.json"
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
        ${nu} ${polyrepoScript} sync "$repo_path" $argsString > "$out/stdout.txt" 2> "$out/stderr.txt"
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
        ${nu} ${polyrepoScript} bootstrap "$repo_path" --json $argsString > "$out/status.json"
      '';
    };
in
{
  localInputOverrides."test sync emits local overrides and imports for repo target" = {
    expr =
      let
        output = runSync {
          derivationNamePrefix = "polyrepo-sync-basic";
          fixture = "recursive-polyrepo";
          repoPath = "repos/app";
        };
        rendered = readYaml "${output}/repos/app/devenv.local.yaml";
      in
      stripContext rendered.inputs.agent-scripts.url
      == stripContext "path:${output}/repos/agent-scripts"
      && stripContext rendered.inputs.docs-shared.url
      == stripContext "path:${output}/repos/poly-docs-env"
      && stripContext rendered.inputs.nusurf.url
      == stripContext "path:${output}/repos/nusurf"
      && stripContext rendered.inputs.poly-rust-env.url
      == stripContext "path:${output}/repos/poly-rust-env"
      && rendered.imports == [
        "agent-scripts/tooling"
        "nusurf/nushell-plugin"
        "docs-shared/subdir"
      ];
    expected = true;
  };

  localInputOverrides."test sync allows the polyrepo root as a first-class target" = {
    expr =
      let
        output = runSyncJson {
          derivationNamePrefix = "polyrepo-sync-root";
          fixture = "recursive-polyrepo";
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
      && stripContext rendered.inputs.agent-scripts.url
      == stripContext "path:${output}/repos/agent-scripts"
      && rendered.imports == [
        "agent-scripts/tooling"
        "nusurf/nushell-plugin"
        "docs-shared/subdir"
      ];
    expected = true;
  };

  localInputOverrides."test sync removes stale output when no local overrides remain" = {
    expr =
      let
        output = runSyncJson {
          derivationNamePrefix = "polyrepo-sync-removes-stale";
          fixture = "no-local-polyrepo";
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
          derivationNamePrefix = "polyrepo-check-valid";
          fixture = "recursive-polyrepo";
          repoPath = ".";
        };
        status = readJson "${output}/status.json";
      in
      status.ok == true
      && status.repo_count == 5
      && status.group_count == 1
      && status.layer_count == 3
      && status.error_count == 0;
    expected = true;
  };

  localInputOverrides."test check json aggregates manifest reference errors" = {
    expr =
      let
        output = runCheckJson {
          derivationNamePrefix = "polyrepo-check-invalid";
          fixture = "recursive-polyrepo";
          repoPath = ".";
          beforeRun = ''
            cat > "$out/polyrepo.nuon" <<'EOF'
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
          derivationNamePrefix = "polyrepo-bootstrap-recursive";
          fixture = "recursive-polyrepo";
          repoPath = "repos/app";
        };
        status = readJson "${output}/status.json";
        appRendered = readYaml "${output}/repos/app/devenv.local.yaml";
        depRendered = readYaml "${output}/repos/agent-scripts/devenv.local.yaml";
        bootstrapLog = builtins.filter (line: line != "") (lib.splitString "\n" (builtins.readFile "${output}/bootstrap.log"));
        filesLog = builtins.filter (line: line != "") (lib.splitString "\n" (builtins.readFile "${output}/devenv-files.log"));
      in
      status.target_name == "app"
      && status.dependency_repos == [ "agent-scripts" ]
      && stripContext appRendered.inputs.agent-scripts.url
      == stripContext "path:${output}/repos/agent-scripts"
      && stripContext depRendered.inputs.docs-shared.url
      == stripContext "path:${output}/repos/poly-docs-env"
      && bootstrapLog == [ "${output}/repos/app" ]
      && filesLog == [
        "${output}/repos/agent-scripts"
        "${output}/repos/app"
      ];
    expected = true;
  };

  localInputOverrides."test bootstrap materializes a shell export for the target repo" = {
    expr =
      let
        output = runBootstrap {
          derivationNamePrefix = "polyrepo-bootstrap-shell-export";
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
          derivationNamePrefix = "polyrepo-bootstrap-all";
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

  localInputOverrides."test bootstrap uses manifest dependency order and declared devenv files tasks" = {
    expr =
      let
        output = runBootstrap {
          derivationNamePrefix = "polyrepo-bootstrap-declared-tasks";
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
          derivationNamePrefix = "polyrepo-sync-clearer-current-repo-error";
          fixture = "recursive-polyrepo";
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
      && lib.hasInfix "available repo names:" stderr
      && lib.hasInfix "agent-scripts, app, nusurf" stderr
      && lib.hasInfix "poly-rust-env" stderr
      && lib.hasInfix "polyrepo.nuon" stderr;
    expected = true;
  };
}
