# capsper as the release ships it: the Linux tarball CI's linux job built
# with mise's Zig, fetched by the hash nix/release.json names, and patched to
# run on NixOS. Not a build from source (Dan, 2026-11-15): the tarball is
# built once, tested and released, and building it again here only made a
# second binary that was not the one released.
#
# The tarball is made for an FHS distribution, so two things change, and
# only those: the ELF interpreter (/lib64/ld-linux-x86-64.so.2 there) and
# the RUNPATHs, which autoPatchelfHook points at the store. The binary
# needs libpipewire-0.3 and the onnxruntime the tarball carries in lib/,
# which capsper finds through $ORIGIN/../lib; that onnxruntime is a C++
# library built elsewhere, and needs libstdc++ and libgcc_s, from
# stdenv.cc.cc.lib. glibc is stdenv's. Opus is compiled in. Nothing is
# stripped (dontStrip), so the code is the release's byte for byte.
#
# PipeWire's SPA plugins are not linked: libpipewire loads them at run time
# from the paths its own build names, so the package's pipewire brings them.
#
# Like the tarball, it targets x86_64_v3 (run.ts builds with
# -Dcpu=x86_64_v3).
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  runtimeShell,
  pipewire,
  version,
  url,
  hash,
}:

stdenv.mkDerivation {
  pname = "capsper";
  inherit version;

  src = fetchurl { inherit url hash; };

  # The tarball's root is ".", holding bin/, lib/, models/ and the scripts.
  sourceRoot = ".";

  nativeBuildInputs = [ autoPatchelfHook ];

  buildInputs = [
    pipewire
    stdenv.cc.cc.lib
  ];

  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall

    # The layout capsper resolves against its own executable: jfk.wav (the
    # warm-up clip) beside it, the voice activity model at ../models, and
    # onnxruntime at ../lib. $out/bin/capsper is the wrapper, so the binary
    # lives in libexec.
    install -Dm0755 bin/capsper $out/libexec/capsper
    install -Dm0644 bin/jfk.wav $out/libexec/jfk.wav
    install -Dm0644 models/silero_vad.onnx $out/models/silero_vad.onnx
    mkdir -p $out/lib
    cp -P lib/libonnxruntime.so* $out/lib/

    mkdir -p $out/bin
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
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
