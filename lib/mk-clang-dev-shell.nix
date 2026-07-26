{ pkgs }:
{
  clangVersion ? 22,
  extraPackages ? [ ],
  # e.g. { name = "clang-format"; package = someDerivation; }
  clangToolsOverride ? null,
  extraShellHook ? "",
}:
let
  llvmPackages = pkgs."llvmPackages_${toString clangVersion}";

  clang-tools =
    if clangToolsOverride == null then
      llvmPackages.clang-tools
    else
      pkgs.symlinkJoin {
        name = "clang-tools-${toString clangVersion}-with-${clangToolsOverride.name}-override";
        paths = [ llvmPackages.clang-tools ];
        postBuild = ''
          rm $out/bin/${clangToolsOverride.name}
          ln -s ${clangToolsOverride.package}/bin/${clangToolsOverride.name} $out/bin/${clangToolsOverride.name}
        '';
      };
in
pkgs.mkShell.override { stdenv = llvmPackages.libcxxStdenv; } {
  packages = [ clang-tools ] ++ extraPackages;

  shellHook = ''
    export NIX_CFLAGS_COMPILE="$NIX_CFLAGS_COMPILE -B${llvmPackages.libcxx}/lib"
  ''
  + builtins.readFile ./debugserver-shellhook.sh
  + extraShellHook;
}
