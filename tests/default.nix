{
  lib,
  pkgs,
  repoRoot,
}:
lib.foldl' lib.recursiveUpdate { } [
  (import ./contracts/sync.nix {
    inherit
      lib
      pkgs
      repoRoot
      ;
  })
  (import ./contracts/check.nix {
    inherit
      lib
      pkgs
      repoRoot
      ;
  })
  (import ./contracts/bootstrap.nix {
    inherit
      lib
      pkgs
      repoRoot
      ;
  })
  (import ./contracts/module.nix {
    inherit
      lib
      pkgs
      repoRoot
      ;
  })
  (import ./contracts/run.nix {
    inherit
      lib
      pkgs
      repoRoot
      ;
  })
]
