## `committer`

- No git add/commit workflow (git add -N for nix evals ok)
- Always use committer, helper on path atomically stages+commits only listed
- Usage (confident): committer [-C <repo-path>] $'commit message' <file-or-glob> [more files/globs...]
- These all commit cleanly in one pass:
	- Fully deleted tracked globs
	- Renames (specify both paths to detect)
	- Mixed glob with one modified file and one deleted file
	- Pure untracked glob

### Example

```sh
git status --short; git diff --shortstat -U1
committer -C repos/app $'feat(domain): add selected files\n\nPara 1\nPara 2' test.txt "weird name.txt" "dir/*.md"
```

### Path relativity

- <file-or-glob> is relative to -C <repo-path>
- Relative to pwd if -C omitted
- Absolute paths stay absolute

### Commit msg

- Style: One string msg (ANSI-C quoting), conventional header
- Despite being 1-liner, body should be sufficiently detailed (multi-paragraph)
- Include 'why'-oriented detail, substantive (not shopping checklist)

### Auto tasks

- Auto runs pre-commit (prek) hooks (treefmt, typos)
- Code formatted by prek hook is auto re-staged and committed in same single commit pass

## `run`

- Run a repo's generated devenv environment without steady-state shellHook or enterShell side effects.
- First use may materialize a shell export if repo doesn't have one yet.
- Usage: run [-C <repo-path>] [--shell '<command>'] [--] <command> [args...]
- Example: run -C repos/app cargo build --workspace
