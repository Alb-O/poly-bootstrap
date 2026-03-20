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
            'eval "${"shellHook:-"}"'
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
  agentroots_script = "${generatorSource}/cli/agentroots.nu";
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
  moduleSupportOptionsModule =
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

  evalSharedModule =
    {
      root,
      pkgsForTooling ? pkgs,
    }:
    lib.evalModules {
      specialArgs = {
        pkgs = pkgsForTooling;
      };
      modules = [
        moduleSupportOptionsModule
        "${root}/repos/agentroots/module"
      ];
    };

  seedStubAgentrootsRuntime =
    {
      targetRoot,
      includeRuntimeManifest ? true,
      includeModuleAgents ? true,
      includeModuleDefault ? true,
      includeModuleDevenv ? true,
    }:
    let
      runtimeManifestLines = ''
        cli/devenv-run.nu
        lib/nu/shell_export.nu
        module/default.nix
        module/devenv.nix
        nix/package-tools.nix
      '';
    in
    ''
      mkdir -p "${targetRoot}/cli" "${targetRoot}/lib/nu" "${targetRoot}/module" "${targetRoot}/nix"
      cat > "${targetRoot}/cli/devenv-run.nu" <<'EOF'
      echo initial
      EOF
      cat > "${targetRoot}/lib/nu/shell_export.nu" <<'EOF'
      echo helper
      EOF
      cat > "${targetRoot}/nix/package-tools.nix" <<'EOF'
      { }
      EOF
      ${lib.optionalString includeModuleAgents ''
        cat > "${targetRoot}/module/AGENTS.md" <<'EOF'
        ## devenv-run
        example
        EOF
      ''}
      ${lib.optionalString includeModuleDefault ''
        cat > "${targetRoot}/module/default.nix" <<'EOF'
        { }
        EOF
      ''}
      ${lib.optionalString includeModuleDevenv ''
        cat > "${targetRoot}/module/devenv.nix" <<'EOF'
        import ./default.nix
        EOF
      ''}
      ${lib.optionalString includeRuntimeManifest ''
        cat > "${targetRoot}/nix/runtime-files.txt" <<'EOF'
        ${runtimeManifestLines}
        EOF
      ''}
    '';

  runFixture =
    {
      derivationNamePrefix,
      fixture,
      repoPath,
      extraArgs ? [ ],
      hydrateAgentroots ? true,
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
        if [ "${if hydrateAgentroots then "1" else "0"}" = "1" ] && [ -d "$out/repos/agentroots" ]; then
          rm -rf "$out/repos/agentroots"
          cp -R ${generatorSource}/. "$out/repos/agentroots"
          chmod -R u+w "$out/repos/agentroots"
        fi
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
      inherit
        derivationNamePrefix
        fixture
        repoPath
        extraArgs
        beforeRun
        ;
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
      inherit
        derivationNamePrefix
        fixture
        repoPath
        beforeRun
        ;
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
      inherit
        derivationNamePrefix
        fixture
        repoPath
        beforeRun
        ;
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
      inherit
        derivationNamePrefix
        fixture
        repoPath
        extraArgs
        beforeRun
        ;
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
      inherit
        derivationNamePrefix
        fixture
        repoPath
        extraArgs
        beforeRun
        ;
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
      inherit
        derivationNamePrefix
        fixture
        repoPath
        extraArgs
        beforeRun
        ;
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

  runBootstrapFailure =
    {
      derivationNamePrefix,
      fixture,
      repoPath,
      extraArgs ? [ ],
      hydrateAgentroots ? true,
      beforeRun ? "",
    }:
    runFixture {
      inherit
        derivationNamePrefix
        fixture
        repoPath
        extraArgs
        hydrateAgentroots
        beforeRun
        ;
      script = ''
        mkdir -p "$out/bin"
        install -Dm755 ${fakeDevenvScript} "$out/bin/devenv"
        export PATH="$out/bin:$PATH"
        export BOOTSTRAP_LOG="$out/bootstrap.log"
        export DEVENV_FILES_LOG="$out/devenv-files.log"
        export SHELL_EXPORT_LOG="$out/shell-export.log"
        set +e
        ${nu} ${agentroots_script} bootstrap "$repo_path" $argsString > "$out/stdout.txt" 2> "$out/stderr.txt"
        status="$?"
        printf '%s' "$status" > "$out/exit-code.txt"
        if [ "$status" -eq 0 ]; then
          echo "expected bootstrap to fail" >&2
          exit 1
        fi
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
      inherit
        derivationNamePrefix
        fixture
        repoPath
        extraArgs
        beforeRun
        ;
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

  runPackagedAgentroots =
    {
      derivationNamePrefix,
      sourceTree,
      agentrootsPackage,
    }:
    pkgs.runCommand derivationNamePrefix
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.nushell
        ];
      }
      ''
        mkdir -p "$out"
        cp -R ${sourceTree}/. "$out"/
        chmod -R u+w "$out"
        mkdir -p "$out/report"
        export REPORT_DIR="$out/report"
        export BOOTSTRAP_LOG="$out/bootstrap.log"
        export DEVENV_FILES_LOG="$out/devenv-files.log"
        export SHELL_EXPORT_LOG="$out/shell-export.log"
        export PATH="${agentrootsPackage}/bin:$PATH"
        type -P agentroots > "$REPORT_DIR/agentroots-path.txt"
        "${agentrootsPackage}/bin/agentroots" bootstrap "$out/repos/app" --json > "$out/status.json"
      '';
in
{
  inherit
    evalSharedModule
    fixturePath
    pkgsWithFakeDevenv
    readJson
    readYaml
    runBootstrap
    runBootstrapFailure
    runBootstrapJson
    runBootstrapJsonTwice
    runCheckJson
    runPackagedAgentroots
    runPackagedDevenvRun
    runSync
    runSyncFailure
    runSyncJson
    runtimeFixture
    seedStubAgentrootsRuntime
    staleLocalOverridesFile
    stripContext
    ;
}
