## committer

No git add/commit workflow (git add -N for nix evals ok)
Always use committer, helper on path atomically stages+commits only listed
Usage (confident): committer [-C <repo-path>] $'commit message' <file-or-glob> [more files/globs...]
Deleted pathspec valid (renames: specify both paths to detect)
If `-C` is omitted, `committer` targets the current working directory.
One string msg (ANSI-C quoting), conventional, header+detailed body
```bash
command -v committer; git diff --shortstat -U1
committer $'feat(domain): add selected files\n\n- include docs\n- include test fixture' test.txt "weird name.txt" "dir/*.md"
```

## run

Run a repo's generated devenv environment without steady-state shellHook or enterShell side effects.
First use may materialize a shell export if the repo does not have one yet.
Usage: run [-C repo_root] [--shell '<command>'] [--] <command> [args...]
Example: run -C repos/nusim/nusim_app cargo build --workspace
