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
  isRepoRoot =
    path:
    builtins.pathExists "${path}/.git"
    || builtins.pathExists "${path}/devenv.yaml";
  inferredPolyrepoRoot =
    if lib.hasPrefix "/" cfg.repoDirsPath then
      null
    else
      let
        repoParent = dirOf currentRoot;
        repoGrandparent = dirOf repoParent;
        directPolyrepoRoot = dirnameN ((lib.length repoDirsSegments) + 1) currentRoot;
        groupedPolyrepoRoot = dirnameN ((lib.length repoDirsSegments) + 2) currentRoot;
        directCandidateRepoDirsRoot =
          if repoDirsSegments == [ ] then
            directPolyrepoRoot
          else
            "${directPolyrepoRoot}/${cfg.repoDirsPath}";
        groupedCandidateRepoDirsRoot =
          if repoDirsSegments == [ ] then
            groupedPolyrepoRoot
          else
            "${groupedPolyrepoRoot}/${cfg.repoDirsPath}";
      in
      if repoParent == directCandidateRepoDirsRoot then
        directPolyrepoRoot
      else if repoGrandparent == groupedCandidateRepoDirsRoot then
        groupedPolyrepoRoot
      else
        null;
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
  discoveredRepoRoots =
    lib.concatMap (
      entryName:
      let
        entryType = builtins.getAttr entryName repoEntries;
        entryPath = "${repoDirsRoot}/${entryName}";
      in
      if entryType != "directory" then
        [ ]
      else if isRepoRoot entryPath then
        [ { name = entryName; path = entryPath; } ]
      else
        let
          nestedEntries =
            if builtins.pathExists entryPath
            then builtins.readDir entryPath
            else { };
        in
        lib.concatMap (
          nestedName:
          let
            nestedType = builtins.getAttr nestedName nestedEntries;
            nestedPath = "${entryPath}/${nestedName}";
          in
          if nestedType == "directory" && isRepoRoot nestedPath then
            [ { name = nestedName; path = nestedPath; } ]
          else
            [ ]
        ) (builtins.attrNames nestedEntries)
    ) (builtins.attrNames repoEntries);
  filteredRepoRoots = lib.filter (
    repo:
    (includeRepos == [ ] || builtins.elem repo.name includeRepos)
    && !(builtins.elem repo.name excludeRepos)
  ) discoveredRepoRoots;
  duplicateRepoNames =
    lib.filter (repoName: (lib.length (lib.filter (repo: repo.name == repoName) filteredRepoRoots)) > 1)
      (lib.unique (map (repo: repo.name) filteredRepoRoots));
  _checkDuplicateRepoNames =
    if duplicateRepoNames == [ ] then
      null
    else
      throw "multiple local repos share the same basename under composer.localInputOverrides.repoDirsPath: ${lib.concatStringsSep ", " duplicateRepoNames}";
  repoPathPairs =
    let
      _ = _checkDuplicateRepoNames;
    in
    map (repo: lib.nameValuePair repo.name repo.path) filteredRepoRoots;
  repoPaths = builtins.listToAttrs repoPathPairs;
  repoNames = lib.sort builtins.lessThan (builtins.attrNames repoPaths);
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
              "${builtins.getAttr repoName repoPaths}/${sourceRelativePath}";
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
  inherit globalInputsPath polyrepoRoot repoDirsRoot repoNames repoPaths repoSources sourcePath;
  globalInputsText =
    if builtins.pathExists globalInputsPath
    then builtins.readFile globalInputsPath
    else "";
}
