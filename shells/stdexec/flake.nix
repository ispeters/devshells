{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
    nixpkgs-staging.url = "github:NixOS/nixpkgs/staging-next";
  };
  outputs =
    { nixpkgs, nixpkgs-staging, ... }:
    let
      system = "aarch64-darwin";
      pkgs = nixpkgs.legacyPackages.${system};
      pkgs-staging = import nixpkgs-staging { inherit system; };

      mkClangDevShell = import ../../lib/mk-clang-dev-shell.nix {
        inherit pkgs;
        inherit (pkgs) lib;
      };

      clang-format-21_1_5 = pkgs.stdenv.mkDerivation rec {
        pname = "clang-format";
        version = "21.1.5";

        src = pkgs.fetchFromGitHub {
          owner = "llvm";
          repo = "llvm-project";
          rev = "llvmorg-${version}";
          hash = "sha256-3OZKcYSJeecSE9RrPCDKpsF4AiLszmb4LLmw0h7Sjjs";
        };

        sourceRoot = "${src.name}/llvm";

        nativeBuildInputs = with pkgs; [
          cmake
          ninja
          python3
        ];

        cmakeFlags = [
          "-DLLVM_ENABLE_PROJECTS=clang"
          "-DLLVM_TARGETS_TO_BUILD=Native"
          "-DCMAKE_BUILD_TYPE=Release"
          # Trim optional dependencies you almost certainly don't need just to
          # get clang-format built; drop these if CMake wants them anyway.
          "-DLLVM_ENABLE_ZLIB=OFF"
          "-DLLVM_ENABLE_ZSTD=OFF"
          "-DLLVM_ENABLE_LIBXML2=OFF"
        ];

        ninjaFlags = [ "clang-format" ];

        installPhase = ''
          runHook preInstall
          mkdir -p $out/bin
          cp bin/clang-format $out/bin/
          runHook postInstall
        '';
      };
    in
    {
      devShells.${system}.default = mkClangDevShell {
        clangToolsOverride = {
          name = "clang-format";
          package = clang-format-21_1_5;
        };
        extraPackages = with pkgs; [
          pkgs-staging.cmake
          gersemi
          lldb
          ninja
        ];
      };
    };
}
