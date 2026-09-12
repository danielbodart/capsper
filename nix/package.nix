# capsper, built from source.
#
# The CPU variant is built entirely from source against nixpkgs' own
# onnxruntime: no prebuilt binaries, no patchelf, and no CPU-baseline
# restriction (the dist build targets x86_64_v3; this one does not).
#
# The CUDA variant is the same source build, but linked against the
# onnxruntime that capsper's CI publishes rather than nixpkgs'. That is not
# laziness: nixpkgs' onnxruntime with `cudaSupport` is in no binary cache --
# not cache.nixos.org, not cuda-maintainers.cachix.org, not
# nix-community.cachix.org -- so building it means a multi-hour compile on
# every nixpkgs bump, to arrive at a different ORT build from the one
# capsper's regression thresholds were tuned against. The published one is a
# fetchurl, so it is a fixed-output derivation and immune to nixpkgs bumps.
#
# Neither variant uses patchelf. The executable is linked by Zig, which sets
# its own interpreter and RPATH (-Dort-lib, -Drpath). The CUDA variant's
# prebuilt ORT libraries are left untouched and located at runtime via
# LD_LIBRARY_PATH from the wrapper -- a shared library has no ELF interpreter,
# so nothing about them has to be rewritten.
{
  lib,
  stdenv,
  fetchurl,
  runtimeShell,
  zig_0_15,
  pkg-config,
  pipewire,
  libopus,
  onnxruntime,
  cudaPackages,
  version,
  cudaSupport ? false,
}:

let
  # onnxruntime 1.23.2 plus the CUDA execution provider, as published by
  # capsper's CI. Unpacked as-is: no patching of any kind.
  ortCuda = stdenv.mkDerivation {
    pname = "capsper-onnxruntime-cuda";
    version = "1.23.2";
    src = fetchurl {
      url = "https://github.com/danielbodart/capsper/releases/download/v0.336.228/capsper-linux-x86_64-deps.tar.gz";
      hash = "sha256-vY2b10DGP6/oM4LdApSfwtFj4BkJ7x8vESBYrqwWNmk=";
    };
    sourceRoot = ".";
    dontConfigure = true;
    dontBuild = true;
    dontFixup = true; # leave the RUNPATHs exactly as upstream built them
    installPhase = "mkdir -p $out && cp -r lib $out/";
  };

  # Shared with the flake's devShell so the packaged binary and the one
  # `./run build` produces load the same libraries. See ./runtime-libs.nix.
  runtimeLibs = import ./runtime-libs.nix { inherit lib stdenv cudaPackages; };

  # The ORT headers must match the ORT being linked: capsper asks for
  # ORT_API_VERSION at runtime, and a 1.23.2 library returns null if handed
  # the 24 that nixpkgs' 1.24.4 headers declare.
  ortInclude =
    if cudaSupport then
      "$NIX_BUILD_TOP/source/dist/linux/include/onnxruntime"
    else
      "${lib.getDev onnxruntime}/include/onnxruntime";
  ortLib = if cudaSupport then "${ortCuda}/lib" else "${lib.getLib onnxruntime}/lib";

  # Only what the build actually reads. Notably excludes dist/linux/lib, whose
  # contents are Git LFS objects that arrive as pointer files when the flake is
  # fetched from GitHub rather than checked out.
  source = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../build.zig
      ../build.zig.zon
      ../src
      ../test/jfk.wav # installed beside the binary as the warmup clip
      ../models # the voice activity model, installed into the models directory
      ../dist/linux/include # ORT headers, plain text (not LFS)
    ];
  };
in
stdenv.mkDerivation {
  pname = if cudaSupport then "capsper-cuda" else "capsper-cpu";
  inherit version;

  src = source;

  nativeBuildInputs = [
    zig_0_15
    pkg-config
  ];

  buildInputs = [
    pipewire
    libopus
  ]
  ++ lib.optionals (!cudaSupport) [ onnxruntime ];

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild

    # Zig writes to a global cache; point it somewhere writable in the sandbox.
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"

    # No -Dcpu: unlike the dist build, this is not pinned to x86_64_v3.
    zig build install \
      --prefix "$out" \
      -Dbackend=${if cudaSupport then "ort_cuda" else "ort_cpu"} \
      -Doptimize=ReleaseSafe \
      -Dversion=${version} \
      -Dprop-tests=false \
      -Dsystem-opus=true \
      -Dort-include=${ortInclude} \
      -Dort-lib=${ortLib} \
      -Drpath=${ortLib} \
      -Drpath=${lib.getLib pipewire}/lib

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    # zig build already installed into $out/bin. Move the real binary aside so
    # $out/bin/capsper can be the wrapper -- jfk.wav has to follow it, because
    # capsper resolves the warmup clip relative to its own executable.
    mkdir -p $out/libexec
    mv $out/bin/${if cudaSupport then "capsper-cuda" else "capsper-cpu"} $out/libexec/capsper
    mv $out/bin/jfk.wav $out/libexec/jfk.wav

    substitute ${./capsper-wrapper.sh} $out/bin/capsper \
      --subst-var-by shell ${runtimeShell} \
      --subst-var-by exe $out/libexec/capsper \
      --subst-var-by libpath ${
        lib.escapeShellArg (
          if cudaSupport then
            # This build's ORT comes from the store; the rest is the shared
            # list. The CPU build needs no LD_LIBRARY_PATH at all -- Zig gave
            # it an RPATH covering nixpkgs' onnxruntime.
            lib.concatStringsSep ":" ([ "${ortCuda}/lib" ] ++ runtimeLibs)
          else
            ""
        )
      }
    chmod +x $out/bin/capsper

    runHook postInstall
  '';

  meta = {
    description = "Push-to-talk voice dictation${lib.optionalString cudaSupport " (CUDA)"}";
    homepage = "https://github.com/danielbodart/capsper";
    platforms = [ "x86_64-linux" ];
    mainProgram = "capsper";
  };
}
