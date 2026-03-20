{
  pkgs,
  lib,
}:

let
  repoRoot = ../.;
  runtimeFiles = builtins.filter (line: line != "" && !(lib.hasPrefix "#" line)) (
    map lib.strings.trim (lib.splitString "\n" (builtins.readFile ./runtime-files.txt))
  );
  runtimeFileAssertions = map (
    relPath:
    if builtins.pathExists "${toString repoRoot}/${relPath}" then
      null
    else
      throw "agentroots runtime manifest references a missing file: ${relPath}"
  ) runtimeFiles;
  runtimeFileList = lib.concatStringsSep "\n" runtimeFiles;
  runtimeSource = builtins.deepSeq runtimeFileAssertions (
    pkgs.runCommand "agentroots_runtime_source"
      {
        passAsFile = [ "runtimeFileList" ];
        inherit runtimeFileList;
      }
      ''
        mkdir -p "$out"

        while IFS= read -r rel_path; do
          [ -n "$rel_path" ] || continue
          mkdir -p "$out/$(dirname "$rel_path")"
          cp "${repoRoot}/$rel_path" "$out/$rel_path"
        done < "$runtimeFileListPath"
      ''
  );
  makeNuCli =
    {
      name,
      entrypoint,
      runtimeInputs ? [ ],
    }:
    pkgs.writers.writeNuBin name
      {
        makeWrapperArgs = [
          "--prefix"
          "PATH"
          ":"
          (lib.makeBinPath ((lib.unique runtimeInputs) ++ [ pkgs.nushell ]))
        ];
      }
      ''
        def --wrapped main [...rest: string] {
          ^${lib.getExe pkgs.nushell} ${runtimeSource}/${entrypoint} ...$rest
        }
      '';
in
{
  inherit
    makeNuCli
    runtimeFiles
    runtimeSource
    ;
}
