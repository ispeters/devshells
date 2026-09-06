# A nixpkgs overlay adding pkgs.llvmPackages_24_trunk_assert: an
# assertions-enabled Clang built from a pinned llvm-project main commit,
# carrying only the ICS uninitialized-read assertion.
#
# Why a separate file from llvm23-overlay.nix: everything in there is pinned
# to the llvmorg-23.1.0 *release tag* and shares one sha256. This is a moving
# snapshot with its own update ritual (see "Bumping the pin" below), and
# keeping it apart means bumping it can't disturb the release-pinned scopes
# that the reduction work depends on.
#
# Usage: add `(import ./lib/llvm-trunk-overlay.nix)` to the `overlays` list in
# flake.nix, alongside the llvm23 one. It must be an overlay for the same
# splicing reason documented at the top of llvm23-overlay.nix.
final: prev: {
  llvmPackages_24_trunk_assert =
    (
      (final.mkLLVMPackages {
        name = "24_trunk_assert";
        # LLVM main reports 24.0.0 (cmake/Modules/LLVMVersion.cmake) since the
        # 23.x branch was cut. nixpkgs' convention for a non-release snapshot
        # is <next-version>-unstable-<date>.
        version = "24.0.0-unstable-2026-09-05";
        gitRelease = {
          # Pinned llvm-project main. Verified on this commit: the ICS
          # trailing-argument code is unchanged from 23.1.0 --
          # CreateDeserialized still runs an EmptyShell constructor that sets
          # only NumTemplateArgs, setTemplateArguments is still a bare
          # uninitialized_copy with no flag, and getTemplateArguments has no
          # guard. So the defect is present on main, not only on the release
          # branch, and 0001 below applies with offsets only.
          rev = "72417eb739e5d66fd345c3cc9e2265b8a7949fe1";
          rev-version = "24.0.0-git";
          # PLACEHOLDER. Nix cannot be run where this file was written, so the
          # hash is unknown. First `nix develop` will fail with
          #   error: hash mismatch in fixed-output derivation
          #     specified: sha256-AAAA...
          #     got:       sha256-<the real one>
          # Paste the "got" value here and rerun. See "Bumping the pin".
          sha256 = "sha256-usFZiOG0UpFHJRkgmuitwcsH+MLbSfSVB/2crHRfGB8=";
        };
      }).value
    ).overrideScope
      (
        lFinal: lPrev:
        let
          # Same uniformity requirement as the 23.1.0 assert scopes: assertions
          # flip LLVM_ENABLE_ABI_BREAKING_CHECKS, which changes data structure
          # layouts, so libllvm and libclang must agree.
          withAssertions =
            drv:
            drv.overrideAttrs (old: {
              cmakeFlags = (old.cmakeFlags or [ ]) ++ [ "-DLLVM_ENABLE_ASSERTIONS=ON" ];
              hardeningDisable = (old.hardeningDisable or [ ]) ++ [ "libcxxhardeningfast" ];
              doCheck = false;
            });
        in
        {
          libllvm = (withAssertions lPrev.libllvm).overrideAttrs (old: {
            cmakeFlags = old.cmakeFlags ++ [ "-DLLVM_INCLUDE_BENCHMARKS=OFF" ];
          });

          libclang = (withAssertions lPrev.libclang).overrideAttrs (old: {
            patches = (old.patches or [ ]) ++ [
              # The one diagnostic patch: a bitfield recording whether
              # setTemplateArguments() has run, and an assert in
              # getTemplateArguments(). Nothing else -- this scope exists to
              # confirm the defect reproduces on main and to hand a Clang
              # developer a build they can reason about.
              ./patches/0001-assert-ics-args-written-before-read.patch

              # NOT included, deliberately:
              #
              # 0001-fix-typetraitexpr-value-dependent-serialization-assert
              #   Needed on the 23.1.0 assert scopes to get past serializing a
              #   value-dependent TypeTraitExpr into a BMI, which the reduced
              #   reproducer does contain (`concept constructible_from =
              #   __is_constructible(_As...)`). Believed already fixed
              #   upstream, hence absent here. If the module precompile aborts
              #   in ASTWriterStmt.cpp on this scope, that belief is wrong:
              #   add the patch back and say so in the bug report, because
              #   "reproducing needs an unrelated serialization fix" is
              #   information a maintainer wants.
              #
              # 0002..0007  The measurement instruments (cache reserve,
              #   value-init knockout, creation census, in-window probe, byte
              #   classification, concept naming). They did their job on the
              #   23.1.0 scope; carrying them here would only make this build
              #   harder for someone else to trust.
            ];
          });
        }
      );
}
