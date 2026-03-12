{ config, lib }:

let
  cfg = config.composer.localInputOverrides;
  currentRoot = toString config.devenv.root;
  includeRepos = lib.unique cfg.includeRepos;
  excludeRepos = lib.unique cfg.excludeRepos;
  reposRoot =
    if cfg.reposRoot != null
    then cfg.reposRoot
    else dirOf config.devenv.root;
  sourcePath =
    if lib.hasPrefix "/" cfg.sourcePath
    then cfg.sourcePath
    else "${config.devenv.root}/${cfg.sourcePath}";
  # Discover repos at eval time; the builder cannot reliably probe host paths.
  repoEntries =
    if builtins.pathExists reposRoot
    then builtins.readDir reposRoot
    else { };
  allRepoNames = lib.filter (
    repoName: builtins.getAttr repoName repoEntries == "directory"
  ) (builtins.attrNames repoEntries);
  repoNames = lib.filter (
    repoName:
    (includeRepos == [ ] || builtins.elem repoName includeRepos)
    && !(builtins.elem repoName excludeRepos)
  ) allRepoNames;
  # Keep recursive scans repo-relative; unrelated absolute paths stay disabled.
  sourceRelativePath =
    if lib.hasPrefix "${currentRoot}/" sourcePath then
      lib.removePrefix "${currentRoot}/" sourcePath
    else if lib.hasPrefix "/" sourcePath then
      null
    else
      sourcePath;
  repoSources = builtins.listToAttrs (
    lib.filter (entry: entry != null) (
      map (
        repoName:
        let
          repoSourcePath =
            if sourceRelativePath == null then
              null
            else
              "${reposRoot}/${repoName}/${sourceRelativePath}";
        in
        if repoSourcePath != null && builtins.pathExists repoSourcePath then
          {
            name = repoName;
            value = builtins.readFile repoSourcePath;
          }
        else
          null
      ) repoNames
    )
  );
in
{
  inherit repoNames repoSources reposRoot sourcePath;
}
