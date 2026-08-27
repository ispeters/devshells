# A nixpkgs overlay adding pkgs.llvmPackages_23, built from source.
#
# Usage: pass `import ./lib/llvm23-overlay.nix` (or, from another flake,
# `import "${devshells}/lib/llvm23-overlay.nix"`) in the `overlays` list of
# your own `import nixpkgs { ... }` call. It must be an overlay applied at
# pkgs-construction time -- see the note below on why a local `let` binding
# elsewhere doesn't work -- so it can't be consumed any other way (e.g. it
# is not importable as a plain function taking `pkgs` the way
# mk-clang-dev-shell.nix is).
final: prev: {
  # pkgs.llvmPackages_23 doesn't exist at nixos-26.05 (293d6abe) -- the
  # internal versions table only has a stale "23.0.0-git" dev-snapshot
  # entry, unwired to any llvmPackages_23 alias. Build 23.1.0 from source
  # via mkLLVMPackages (the same generic per-major-version builder nixpkgs
  # uses internally), pointed at the real release tag.
  #
  # This has to be an overlay, not a local `let` binding in a consuming
  # shell file: nixpkgs' cross-compilation splicing machinery
  # (generateSplicesForMkScope) requires a same-named attribute to exist in
  # pkgs.pkgsBuildBuild/pkgsBuildHost/pkgsHostHost/etc, not just in pkgs
  # itself -- even for a purely native, non-cross build. Overlays are the
  # only thing that propagates into all of those scopes uniformly.
  llvmPackages_23 =
    (
      (final.mkLLVMPackages {
        name = "23";
        version = "23.1.0";
        gitRelease = {
          rev = "llvmorg-23.1.0";
          rev-version = "23.1.0";
          sha256 = "sha256-Astfi1UDDcydyws3Q1sELqho/PxiNN/tvCtmCGj5FoE=";
        };
      }).value
    ).overrideScope (
      lFinal: lPrev: {
        # LLVM's own test suite includes tests (dsymutil/codesign.test)
        # that shell out to the real macOS `codesign`, unavailable inside
        # Nix's sandboxed Darwin build. nixpkgs' compiler-rt derivation
        # hits the identical problem and works around it by disabling the
        # codesign check outright rather than providing a working
        # substitute; common/llvm/default.nix has no equivalent exclusion
        # for this specific test yet at this pin (unsurprising, since
        # nixpkgs hasn't built LLVM 23 itself). Rather than patch out
        # individual failing tests one at a time across a 66k-test suite,
        # skip it entirely for this locally-built toolchain.
        #
        # NOTE: override libllvm, not llvm -- llvm is merely an alias
        # (`llvm = self.libllvm;` in common/default.nix) for backwards
        # compatibility with when `llvm` had the binaries. Overriding the
        # alias itself doesn't touch what libllvm's own internal
        # self-references resolve to, so doCheck stayed true.
        libllvm = lPrev.libllvm.overrideAttrs (old: { doCheck = false; });
      }
    );
}
