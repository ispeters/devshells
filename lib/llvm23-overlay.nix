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

  # ASan-instrumented variant of the same toolchain. The compiler *binaries*
  # carry AddressSanitizer; code they compile is entirely unaffected. This is
  # a diagnostic instrument for catching compiler-internal heap bugs (e.g.
  # stale reads into freed deserialization state during BMI import), not a
  # daily-driver toolchain: expect slower compiles and a from-scratch build
  # of the whole scope on first use.
  #
  # IMPORTANT: this is a *separate mkLLVMPackages instantiation*, not an
  # `llvmPackages_23.overrideScope`. overrideScope rebinds only the scope's
  # `self`, but the pieces that decide which compiler you actually get are
  # reached through `buildLlvmPackages`, which common/default.nix binds to
  # `otherSplices.selfBuildHost` -- fixed at makeScopeWithSplicing' time from
  # the splices, never from `self`. In particular
  #
  #     libcxxStdenv = overrideCC stdenv buildLlvmPackages.libcxxClang;
  #
  # so an overrideScope-based variant silently hands back the *un*instrumented
  # clang: the scope's own libclang is instrumented, but nothing the shell
  # consumes refers to it. (Symptom: the build takes hours, then
  # `ASAN_OPTIONS=help=1 clang++ --version` prints no option dump.)
  #
  # Instantiating with `name = "23_asan"` makes generateSplicesForMkScope
  # generate splices for the attribute name `llvmPackages_23_asan`, so
  # `buildLlvmPackages` resolves to *this* overlay attribute -- including the
  # overrideScope layer below, since the attribute is bound to the whole
  # expression. That closes the loop and makes the instrumentation stick.
  llvmPackages_23_asan =
    (
      (final.mkLLVMPackages {
        name = "23_asan";
        version = "23.1.0";
        gitRelease = {
          rev = "llvmorg-23.1.0";
          rev-version = "23.1.0";
          sha256 = "sha256-Astfi1UDDcydyws3Q1sELqho/PxiNN/tvCtmCGj5FoE=";
        };
      }).value
    ).overrideScope
      (
        lFinal: lPrev:
        let
          instrument =
            drv:
            drv.overrideAttrs (old: {
              cmakeFlags = (old.cmakeFlags or [ ]) ++ [ "-DLLVM_USE_SANITIZER=Address" ];
              # Fortify's *_chk interposers fight ASan's interceptors;
              # disabling all hardening is standard for sanitized builds.
              hardeningDisable = [ "all" ];
              # No test suites under ASan: slow, and interceptor-related
              # noise produces failures unrelated to what we're hunting.
              # (This also covers the sandboxed-codesign test that the
              # plain llvmPackages_23 scope disables for the same reason.)
              doCheck = false;
            });
        in
        {
          # Both libllvm and libclang are instrumented, deliberately
          # uniformly: mixing instrumented and uninstrumented dylibs that
          # pass libc++ containers across their boundary invites
          # container-annotation false positives. (Belt-and-suspenders for
          # the same issue at the libc++.dylib boundary: the stdexec-asan
          # shell exports detect_container_overflow=0 by default.)
          #
          # Benchmarks are dead weight here, and possibly harmful: the
          # bundled google/benchmark's cxx_feature_check does a CMake
          # try_run, i.e. it compiles AND EXECUTES a probe binary during
          # configure, and under LLVM_USE_SANITIZER=Address that probe is
          # itself instrumented. Nothing else in the build executes
          # instrumented code: nixpkgs runs all build-time generators
          # (LLVM_TABLEGEN, CLANG_TABLEGEN, ...) from the separate,
          # uninstrumented buildLlvmPackages.tblgen, and doCheck is off.
          libllvm = (instrument lPrev.libllvm).overrideAttrs (old: {
            cmakeFlags = old.cmakeFlags ++ [ "-DLLVM_INCLUDE_BENCHMARKS=OFF" ];
          });
          libclang = instrument lPrev.libclang;
        }
      );
}
