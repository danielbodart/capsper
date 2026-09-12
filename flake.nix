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

      # The same list nix/package.nix bakes into the packaged wrapper. Bound
      # here so the devShell below exports exactly what the packaged build
      # loads.
      runtimeLibs = import ./nix/runtime-libs.nix { inherit (pkgs) lib stdenv cudaPackages; };
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

      # What `./run` installs with apt everywhere else. bootstrap.sh enters
      # this shell automatically on NixOS, where there is no apt to call, so
      # the same `./run dev` works on both.
      #
      # Deliberately not the toolchain: zig, bun and shellcheck still come
      # from mise, pinned in .mise.toml, so a local build uses the identical
      # versions CI does rather than whatever nixpkgs happens to carry. This
      # supplies only the system half -- the packages the Ubuntu job installs
      # in .github/workflows/ci.yml, plus the two binaries `dist` shells out
      # to.
      devShells.${system}.default = pkgs.mkShell {
        nativeBuildInputs = with pkgs; [
          pkg-config
          file # dist: checks the ORT libs really are ELF
          binutils # dist: objdump, for the AVX-512 scan
        ];

        # buildInputs rather than nativeBuildInputs so pkg-config's setup hook
        # puts libpipewire-0.3.pc on PKG_CONFIG_PATH -- build.zig finds
        # PipeWire that way and no other.
        buildInputs = [ pkgs.pipewire ];

        # `./run build` symlinks bin/capsper to the CUDA variant and the
        # integration tests start that, so the dev binary needs the same
        # libraries the packaged one gets from its wrapper. Both read the
        # single list in nix/runtime-libs.nix, which is the point of that
        # file: these two cannot drift apart.
        #
        # No ORT entry here. This binary finds it in dist/linux/lib through an
        # $ORIGIN-relative RPATH that build.zig sets.
        LD_LIBRARY_PATH = pkgs.lib.concatStringsSep ":" runtimeLibs;
      };

      checks.${system} = {
        # The home-manager module renders `settings` to ZON, and a renderer
        # that emits the wrong shape produces a service that will not start.
        # Checked two ways: against the exact text, because the enum literals
        # and the container syntax are where this goes wrong, and by handing
        # the result to capsper, because being valid ZON is not the same as
        # being settings capsper accepts.
        zon-renderer =
          let
            zon = import ./nix/to-zon.nix { inherit (pkgs) lib; };
            rendered = zon.toZON zon.enumPaths {
              model = "~/models/nemotron";
              audio = {
                target = "vocaster_hostmic";
                channel = "FR";
                gain = 10.0;
                auto_gain = false;
              };
              trigger.key = "capslock";
              tcp_server.port = 43007;
              meeting = {
                enabled = true;
                output = null;
                vad.onset = 0.45;
                detail = zon.tag "debug";
              };
            };
            expected = ''
              .{
                  .audio = .{
                      .auto_gain = false,
                      .channel = .FR,
                      .gain = 10.000000,
                      .target = "vocaster_hostmic",
                  },
                  .meeting = .{
                      .detail = .debug,
                      .enabled = true,
                      .output = null,
                      .vad = .{
                          .onset = 0.450000,
                      },
                  },
                  .model = "~/models/nemotron",
                  .tcp_server = .{
                      .port = 43007,
                  },
                  .trigger = .{
                      .key = .capslock,
                  },
              }
            '';
          in
          pkgs.runCommand "capsper-zon-renderer" { } ''
            diff -u ${pkgs.writeText "expected.zon" expected} \
                    ${pkgs.writeText "rendered.zon" rendered}
            ${pkgs.lib.getExe self.packages.${system}.capsper-cpu} \
              --config ${pkgs.writeText "rendered.zon" rendered} --write-config > /dev/null
            touch $out
          '';

        # The module's whole job is granting permissions a user cannot grant
        # themselves, and nothing but a real NixOS system can confirm it
        # worked. Boots one in a VM and checks the device nodes and group
        # membership.
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

      # Exposed for `tag`, which says "this string is a ZON enum literal" for a
      # setting the renderer's own list does not cover yet.
      lib.zon = import ./nix/to-zon.nix { inherit (pkgs) lib; };

      formatter.${system} = pkgs.nixfmt-tree;
    };
}
