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
  readManifestRepoPaths =
    manifestPath:
    let
      manifestText = builtins.readFile manifestPath;
      lines = lib.splitString "\n" manifestText;
      step =
        state: line:
        if !state.inRepos then
          if builtins.match "^[[:space:]]*repos[[:space:]]*:[[:space:]]*\\[[[:space:]]*$" line != null then
            state // { inRepos = true; }
          else
            state
        else if builtins.match "^[[:space:]]*][[:space:]]*$" line != null then
          state // { inRepos = false; completed = true; }
        else if builtins.match "^[[:space:]]*$" line != null then
          state
        else
          let
            entryMatch = builtins.match "^[[:space:]]*path[[:space:]]*:[[:space:]]*\"([^\"]+)\"[[:space:]]*$" line;
          in
          if entryMatch != null then
            state // { paths = state.paths ++ [ (builtins.elemAt entryMatch 0) ]; }
          else
            state;
      result = lib.foldl' step { inRepos = false; completed = false; paths = [ ]; } lines;
    in
    if !result.completed then
      throw "polyrepo.nuon must define repos as a multiline list"
    else
      result.paths;
  findPolyrepoRoot =
    repoRoot:
    let
      go =
        candidate:
        let
          manifestPath = "${candidate}/polyrepo.nuon";
          parent = dirOf candidate;
          candidateRepoPaths =
            if builtins.pathExists manifestPath then
              map (
                repoPath:
                if lib.hasPrefix "/" repoPath then repoPath else "${candidate}/${repoPath}"
              ) (readManifestRepoPaths manifestPath)
            else
              [ ];
          matchesCandidate = builtins.elem repoRoot candidateRepoPaths;
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
  declaredRepoRoots =
    map (
      repoPath:
      let
        resolvedPath = if lib.hasPrefix "/" repoPath then repoPath else "${polyrepoRoot}/${repoPath}";
        relativePath =
          if lib.hasPrefix "/" repoDirsPath then
            if lib.hasPrefix "${repoDirsPath}/" resolvedPath then lib.removePrefix "${repoDirsPath}/" resolvedPath else null
          else if lib.hasPrefix "${repoDirsRoot}/" resolvedPath then
            lib.removePrefix "${repoDirsRoot}/" resolvedPath
          else
            null;
      in
      if relativePath == null && resolvedPath != repoDirsRoot then
        throw "polyrepo.nuon repos entries must stay under the effective repoDirsPath"
      else if !isRepoRoot resolvedPath then
        throw "polyrepo.nuon repos entries must point at repo roots"
      else
        {
          name = baseNameOf resolvedPath;
          path = resolvedPath;
        }
    ) (readManifestRepoPaths polyrepoManifestPath);
  filteredRepoRoots = lib.filter (
    repo:
    (includeRepos == [ ] || builtins.elem repo.name includeRepos)
    && !(builtins.elem repo.name excludeRepos)
  ) declaredRepoRoots;
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
  currentRepoName =
    let
      matches = lib.filter (repo: repo.path == currentRoot) filteredRepoRoots;
    in
    if matches == [ ] then
      if currentRoot == polyrepoRoot then
        null
      else
        throw "the current repo root must be present in the manifest-owned repo catalog after include/exclude filtering"
    else
      (builtins.head matches).name;
in
{
  inherit polyrepoManifestPath polyrepoRoot repoDirsPath repoDirsRoot currentRepoName repoNames repoPaths;
  polyrepoManifestText =
    if builtins.pathExists polyrepoManifestPath
    then builtins.readFile polyrepoManifestPath
    else "";
}
