{ config, lib }:

let
  cfg = config.composer.localInputOverrides;
  currentRoot = toString config.devenv.root;
  includeRepos = lib.unique cfg.includeRepos;
  excludeRepos = lib.unique cfg.excludeRepos;
  readManifestRepoDirsPath =
    manifestPath:
    let
      manifestText = builtins.readFile manifestPath;
      lines = lib.splitString "\n" manifestText;
      matches = lib.filter (match: match != null) (
        map (line: builtins.match "^[[:space:]]*repoDirsPath[[:space:]]*:[[:space:]]*\"([^\"]+)\"[[:space:]]*$" line) lines
      );
    in
    if matches == [ ] then
      throw "polyrepo.nuon must define repoDirsPath as a single-line string field"
    else
      builtins.elemAt (builtins.head matches) 0;
  findPolyrepoRoot =
    repoRoot:
    let
      go =
        candidate:
        let
          manifestPath = "${candidate}/polyrepo.nuon";
          parent = dirOf candidate;
          repoDirsPath = if builtins.pathExists manifestPath then readManifestRepoDirsPath manifestPath else null;
          candidateRepoDirsRoot =
            if repoDirsPath == null || lib.hasPrefix "/" repoDirsPath then
              null
            else
              "${candidate}/${repoDirsPath}";
          repoParent = dirOf repoRoot;
          repoGrandparent = dirOf repoParent;
          matchesCandidate =
            candidateRepoDirsRoot != null
            && (
              repoParent == candidateRepoDirsRoot
              || repoGrandparent == candidateRepoDirsRoot
            );
        in
        if builtins.pathExists manifestPath && matchesCandidate then
          candidate
        else if parent == candidate then
          null
        else
          go parent;
    in
    go repoRoot;
  normalizeSegments =
    path: lib.filter (segment: segment != "" && segment != ".") (lib.splitString "/" path);
  dirnameN =
    levels: path:
    if levels <= 0 then
      path
    else
      dirnameN (levels - 1) (dirOf path);
  isRepoRoot =
    path:
    builtins.pathExists "${path}/.git"
    || builtins.pathExists "${path}/devenv.yaml";
  manifestPolyrepoRoot =
    if cfg.polyrepoRoot == null then findPolyrepoRoot currentRoot else null;
  polyrepoRoot =
    if cfg.polyrepoRoot != null then
      if lib.hasPrefix "/" cfg.polyrepoRoot then cfg.polyrepoRoot else "${currentRoot}/${cfg.polyrepoRoot}"
    else if manifestPolyrepoRoot != null then
      manifestPolyrepoRoot
    else
      throw "composer.localInputOverrides.polyrepoRoot must be set when the current repo is not nested under a polyrepo.nuon root";
  repoDirsRoot =
    let
      effectiveRepoDirsPath =
        if cfg.repoDirsPath != null then
          cfg.repoDirsPath
        else
          readManifestRepoDirsPath "${polyrepoRoot}/polyrepo.nuon";
    in
    if lib.hasPrefix "/" effectiveRepoDirsPath
    then effectiveRepoDirsPath
    else if repoDirsSegments == [ ]
    then polyrepoRoot
    else "${polyrepoRoot}/${effectiveRepoDirsPath}";
  repoDirsPath =
    if cfg.repoDirsPath != null then
      cfg.repoDirsPath
    else
      readManifestRepoDirsPath "${polyrepoRoot}/polyrepo.nuon";
  repoDirsSegments =
    if lib.hasPrefix "/" repoDirsPath
    then [ ]
    else normalizeSegments repoDirsPath;
  polyrepoManifestPath = "${polyrepoRoot}/polyrepo.nuon";
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
      throw "multiple local repos share the same basename under the effective repoDirsPath: ${lib.concatStringsSep ", " duplicateRepoNames}";
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
  inherit polyrepoManifestPath polyrepoRoot repoDirsPath repoDirsRoot repoNames repoPaths repoSources sourcePath;
  polyrepoManifestText =
    if builtins.pathExists polyrepoManifestPath
    then builtins.readFile polyrepoManifestPath
    else "";
}
