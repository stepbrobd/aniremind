{ swiftPackages }:

swiftPackages.swift.stdenv.mkDerivation (finalAttrs: {
  meta.mainProgram = "aniremind";
  pname = "aniremind";
  version = "2026.404.0";

  src = ./.;

  buildInputs = [
    swiftPackages.swift
    swiftPackages.Foundation
  ];

  installPhase = ''
    mkdir -p $out/bin
    swiftc -O -whole-module-optimization AniRemind/main.swift -o $out/bin/${finalAttrs.meta.mainProgram}
  '';
})
