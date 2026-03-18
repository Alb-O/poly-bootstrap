## devenv-run

Run a repo's generated devenv environment without steady-state shellHook or enterShell side effects.
First use may materialize a shell export if the repo does not have one yet.
Usage: devenv-run [-C repo_root] [--shell '<command>'] [--] <command> [args...]
Example: devenv-run -C repos/nusim/nusim_app cargo build --workspace
