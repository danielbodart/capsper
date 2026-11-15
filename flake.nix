{
  description = "Capsper -- push-to-talk voice dictation for Linux";

  inputs = {
    # A default rather than a constraint: `follows` this onto your own nixpkgs
    # and it is recommended that you do. capsper's largest runtime dependency
    # is PipeWire, whose closure is ~700MB once the SPA plugins are counted,
    # and any machine that can run capsper already has it -- but that cost is
    # only shared if both resolve to the same store path. Following is safe:
    # the release binary is patched against whatever nixpkgs it is handed
    # (nix/package.nix), and asks of its glibc and PipeWire no more than any
    # distribution's.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs =
    { self, nixpkgs }:
    let
      # Linux only: macOS uses the CoreML backend, whose Accessibility and
      # Microphone permissions are keyed to the binary's hash, so a store path
      # that changes on every rebuild would need re-approving each time.
      system = "x86_64-linux";

      # THE PACKAGE IS THE RELEASE TARBALL, not a build from source (Dan,
      # 2026-11-15): the tarball is built once, by mise's Zig in CI's linux
      # job, tested and released, and building capsper again here only made
      # a second binary that was not the one released. So a release's tag is
      # a commit of its own, a child of the released trunk commit, that adds
      # nix/release.json: the version, and the tarball's URL and hash
      # (scripts/release-json.sh writes it; ci.yml's release job commits and
      # tags it). A flake fetched as github:danielbodart/capsper/v<V> cannot
      # see its tag, only its commit, which is why the version is in the file.
      #
      # On trunk there is no such file and no package: pin a release tag.
      # Absent rather than an error, so `nix flake check` and the dev shell
      # still work on trunk.
      releaseFile = ./nix/release.json;
      release = if builtins.pathExists releaseFile then nixpkgs.lib.importJSON releaseFile else null;
      asset = if release == null then null else release.assets.${system} or null;

      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      packages.${system} = nixpkgs.lib.optionalAttrs (asset != null) {
        capsper = pkgs.callPackage ./nix/package.nix {
          inherit (release) version;
          inherit (asset) url hash;
        };
        default = self.packages.${system}.capsper;
      };

      # What `./run` installs with apt everywhere else. On NixOS there is no
      # apt to call, so this supplies it instead: direnv loads this shell on
      # entering the directory (.envrc), and `./run` re-runs itself inside it
      # when something non-interactive did not.
      #
      # Deliberately not the toolchain: zig, bun and shellcheck still come
      # from mise, pinned in mise.toml, so a local build uses the identical
      # versions CI does rather than whatever nixpkgs happens to carry. This
      # supplies only the system half -- the same packages `ensureDeps` in
      # run.ts installs with apt, plus the two binaries `dist` shells out to,
      # plus the C++ runtime below.
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

        # The binary `./run build` produces links the onnxruntime in
        # vendor/onnxruntime/lib, which it finds through dist/linux/lib and
        # an $ORIGIN-relative RPATH that build.zig sets -- but that library is a C++ one built elsewhere, and
        # nothing gives it a path to a libstdc++. The package needs no
        # equivalent: autoPatchelfHook gives it one (nix/package.nix).
        LD_LIBRARY_PATH = "${pkgs.lib.getLib pkgs.stdenv.cc.cc}/lib";
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
              tcp.port = 43007;
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
                  .tcp = .{
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
            ${pkgs.lib.optionalString (self.packages.${system} ? capsper) ''
              # Only where there is a package to run: on a release tag,
              # and in CI's nix job, which makes the tarball its own run
              # built the release (scripts/nix-local-release.sh).
              ${pkgs.lib.getExe self.packages.${system}.capsper} \
                --config ${pkgs.writeText "rendered.zon" rendered} --write-config > /dev/null
            ''}
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
