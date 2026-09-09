# The libraries capsper's CUDA build loads at run time.
#
# In its own file because two places need exactly the same list and must not
# drift: nix/package.nix bakes it into the packaged wrapper's LD_LIBRARY_PATH,
# and the flake's devShell exports it so the binary `./run build` produces can
# start on NixOS. Outside Nix neither is necessary -- these sit in /usr/lib
# and the distro's own CUDA directory, and the loader finds them unaided.
#
# Ordinary store paths, with one deliberate exception: /run/opengl-driver/lib
# is the host's NVIDIA driver, which is installed by the running system and so
# cannot come from a derivation at all.
#
# The ONNX Runtime libraries are NOT here, because the two builds get them
# from different places: the packaged one from the store, and the dev one from
# dist/linux/lib via an $ORIGIN-relative RPATH. Each caller adds its own.
{
  lib,
  stdenv,
  cudaPackages,
}:

map (pkg: "${lib.getLib pkg}/lib") [
  stdenv.cc.cc # libstdc++, the ONNX Runtime C++ runtime
  cudaPackages.libcublas
  cudaPackages.libcurand
  cudaPackages.libcufft
  cudaPackages.cuda_cudart
  cudaPackages.cudnn
]
++ [ "/run/opengl-driver/lib" ]
