{
  description = "Capsper -- push-to-talk voice dictation for Linux";

  inputs = {
    # A default rather than a constraint: `follows` this onto your own nixpkgs
    # and it is recommended that you do. capsper's largest runtime dependency
    # is PipeWire, whose closure is ~700MB once the SPA plugins are counted,
    # and any machine that can run capsper already has it -- but that cost is
    # only shared if both resolve to the same store path. Following is safe
    # here precisely because these are source builds: the code is compiled
    # against whatever nixpkgs it is handed, rather than being a prebuilt
    # binary linked to one particular glibc.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs =
    { self, nixpkgs }:
    let
      # Linux only: macOS uses the CoreML backend, whose Accessibility and
      # Microphone permissions are keyed to the binary's hash, so a store path
      # that changes on every rebuild would need re-approving each time.
      system = "x86_64-linux";

      # Built from source, so the exact revision is the version.
      version = "0.0.0-git.${self.shortRev or self.dirtyShortRev or "dirty"}";

      pkgs = import nixpkgs {
        inherit system;
        # cudnn and the CUDA runtime libraries are unfree. Setting this on our
        # own instance keeps the flake self-contained rather than making every
        # consumer opt in globally.
        config.allowUnfree = true;
      };
    in
    {
      packages.${system} = {
        capsper-cpu = pkgs.callPackage ./nix/package.nix { inherit version; };
        capsper-cuda = pkgs.callPackage ./nix/package.nix {
          inherit version;
          cudaSupport = true;
        };

        # CPU by default: free software end to end, every dependency served
        # from cache.nixos.org, and no CPU-baseline restriction. Anyone with an
        # NVIDIA GPU wants `.#capsper-cuda` explicitly -- it adds a 240MB
        # onnxruntime fetch and the CUDA runtime on top.
        default = self.packages.${system}.capsper-cpu;
      };

      # The module's whole job is granting permissions a user cannot grant
      # themselves, and nothing but a real NixOS system can confirm it worked.
      # Boots one in a VM and checks the device nodes and group membership.
      checks.${system} = {
        nixos-module = pkgs.testers.runNixOSTest {
          name = "capsper-nixos-module";

          nodes.machine = {
            imports = [ self.nixosModules.default ];
            services.pipewire.enable = true;
            users.users.alice.isNormalUser = true;
            services.capsper = {
              enable = true;
              users = [ "alice" ];
            };
          };

          testScript = ''
            machine.wait_for_unit("multi-user.target")

            # hardware.uinput.enable should have loaded the module and applied
            # the udev rule. Without it the node is root:root 0600 and capsper
            # cannot inject text at all.
            machine.succeed("test -c /dev/uinput")
            machine.succeed("stat -c '%G %a' /dev/uinput | grep -x 'uinput 660'")

            # Reading keyboards needs `input`; opening /dev/uinput needs `uinput`.
            machine.succeed("id -nG alice | grep -w input")
            machine.succeed("id -nG alice | grep -w uinput")

            # The module must not clobber groups the user already had.
            machine.succeed("getent group input")
          '';
        };
      };
      # System-level setup: the kernel module, udev rule and group membership
      # capsper needs to read keyboards and inject text.
      nixosModules.default = import ./nix/nixos-module.nix { inherit self; };

      # The dictation service itself, which is per-user (it grabs the session's
      # keyboards and talks to that user's PipeWire).
      homeModules.default = import ./nix/home-manager-module.nix { inherit self; };

      formatter.${system} = pkgs.nixfmt-tree;
    };
}
