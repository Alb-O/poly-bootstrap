{
  lib,
  pkgs,
  repoRoot,
}:
import ./local-input-overrides.nix {
  inherit
    lib
    pkgs
    repoRoot
    ;
}
