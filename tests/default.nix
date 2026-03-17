{
  lib,
  pkgs,
  repoRoot,
}:
import ./local-overrides.nix {
  inherit
    lib
    pkgs
    repoRoot
    ;
}
