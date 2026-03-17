{ config, lib }:

let
  cfg = config.composer.localInputOverrides;
  currentRoot = toString config.devenv.root;
  includeRepos = lib.unique cfg.includeRepos;
  excludeRepos = lib.unique cfg.excludeRepos;
  normalizeSegments =
    path: lib.filter (segment: segment != "" && segment != ".") (lib.splitString "/" path);
  dirnameN =
    levels: path:
    if levels <= 0 then
      path
    else
      dirnameN (levels - 1) (dirOf path);
  repoDirsSegments =
    if lib.hasPrefix "/" cfg.repoDirsPath
    then [ ]
    else normalizeSegments cfg.repoDirsPath;
  inferredPolyrepoRoot =
    if lib.hasPrefix "/" cfg.repoDirsPath then
      null
    else
      let
        repoParent = dirOf currentRoot;
        repoDirsParent = dirnameN (lib.length repoDirsSegments) repoParent;
        candidateRepoDirsRoot =
          if repoDirsSegments == [ ] then
            repoDirsParent
          else
            "${repoDirsParent}/${cfg.repoDirsPath}";
      in
      if repoParent == candidateRepoDirsRoot then repoDirsParent else null;
  polyrepoRoot =
    if cfg.polyrepoRoot != null then
      if lib.hasPrefix "/" cfg.polyrepoRoot then cfg.polyrepoRoot else "${currentRoot}/${cfg.polyrepoRoot}"
    else if inferredPolyrepoRoot != null then
      inferredPolyrepoRoot
    else
      throw "composer.localInputOverrides.polyrepoRoot must be set when the current repo is not nested under composer.localInputOverrides.repoDirsPath";
  repoDirsRoot =
    if lib.hasPrefix "/" cfg.repoDirsPath
    then cfg.repoDirsPath
    else if repoDirsSegments == [ ]
    then polyrepoRoot
    else "${polyrepoRoot}/${cfg.repoDirsPath}";
  globalInputsPath = "${polyrepoRoot}/.devenv-global-inputs.yaml";
  sourcePath =
    if lib.hasPrefix "/" cfg.sourcePath
    then cfg.sourcePath
    else "${config.devenv.root}/${cfg.sourcePath}";
  # Discover repos at eval time; the builder cannot reliably probe host paths.
  repoEntries =
    if builtins.pathExists repoDirsRoot
    then builtins.readDir repoDirsRoot
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
              "${repoDirsRoot}/${repoName}/${sourceRelativePath}";
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
  inherit globalInputsPath polyrepoRoot repoDirsRoot repoNames repoSources sourcePath;
  globalInputsText =
    if builtins.pathExists globalInputsPath
    then builtins.readFile globalInputsPath
    else "";
}
