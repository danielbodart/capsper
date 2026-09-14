# capsper, built from source against nixpkgs' own onnxruntime: no prebuilt
# binaries, no patchelf, and no CPU-baseline restriction (the dist build
# targets x86_64_v3; this one does not).
#
# Nothing here is patched. The executable is linked by Zig, which sets its own
# interpreter and RPATH (-Dort-lib, -Drpath).
{
  lib,
  stdenv,
  runtimeShell,
  zig_0_15,
  pkg-config,
  pipewire,
  libopus,
  onnxruntime,
  version,
}:

let
  # The headers must match the library being linked: capsper asks for
  # ORT_API_VERSION at run time, and a library older than the headers declare
  # hands back null rather than an API table. Taking both from the same
  # package is what keeps that true.
  ortInclude = "${lib.getDev onnxruntime}/include/onnxruntime";
  ortLib = "${lib.getLib onnxruntime}/lib";

  # Only what the build actually reads. Notably excludes dist/linux, whose
  # libraries are Git LFS objects that arrive as pointer files when the flake
  # is fetched from GitHub rather than checked out -- this build links
  # nixpkgs' onnxruntime and reads neither those nor the headers beside them.
  source = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../build.zig
      ../build.zig.zon
      ../src
      ../build/gen_config_docs.zig # build step: harvests the settings' descriptions
      ../test/jfk.wav # installed beside the binary as the warmup clip
      ../models # the voice activity model, installed into the models directory
    ];
  };
in
stdenv.mkDerivation {
  pname = "capsper";
  inherit version;

  src = source;

  nativeBuildInputs = [
    zig_0_15
    pkg-config
  ];

  buildInputs = [
    pipewire
    libopus
    onnxruntime
  ];

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild

    # Zig writes to a global cache; point it somewhere writable in the sandbox.
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"

    # No -Dcpu: unlike the dist build, this is not pinned to x86_64_v3.
    zig build install \
      --prefix "$out" \
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
    mv $out/bin/capsper $out/libexec/capsper
    mv $out/bin/jfk.wav $out/libexec/jfk.wav

    substitute ${./capsper-wrapper.sh} $out/bin/capsper \
      --subst-var-by shell ${runtimeShell} \
      --subst-var-by exe $out/libexec/capsper
    chmod +x $out/bin/capsper

    runHook postInstall
  '';

  meta = {
    description = "Push-to-talk voice dictation";
    homepage = "https://github.com/danielbodart/capsper";
    platforms = [ "x86_64-linux" ];
    mainProgram = "capsper";
  };
}
