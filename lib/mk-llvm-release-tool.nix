{ pkgs }:
{
  tool,
  version,
  hash,
  extraCmakeFlags ? [ ],
}:
pkgs.stdenv.mkDerivation rec {
  pname = tool;
  inherit version;

  src = pkgs.fetchFromGitHub {
    owner = "llvm";
    repo = "llvm-project";
    rev = "llvmorg-${version}";
    inherit hash;
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
    "-DLLVM_ENABLE_ZLIB=OFF"
    "-DLLVM_ENABLE_ZSTD=OFF"
    "-DLLVM_ENABLE_LIBXML2=OFF"
  ]
  ++ extraCmakeFlags;

  ninjaFlags = [ tool ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp bin/${tool} $out/bin/
    runHook postInstall
  '';
}
