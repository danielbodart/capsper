# The capsper dictation service, as a home-manager user unit.
#
# capsper is inherently per-user: it grabs the keyboards of a login session,
# talks to that user's PipeWire, and injects text into that user's focused
# window. So the unit lives here rather than in the NixOS module, which
# handles only the system permissions it needs (services.capsper).
#
# Compared with the unit dist/linux/install.sh generates, this one drops the
# auto-update machinery -- ExecStartPre=capsper-apply-update.sh, the
# OnFailure=capsper-rollback.service handler, and the daily update timer.
# Under Nix that is all both redundant and inert: the store is read-only, and
# atomic switch plus rollback is what `nixos-rebuild` already does. Updates
# come from bumping this flake's input.
#
# Settings go through `settings`, which is rendered to the ZON config file
# capsper already reads, rather than through an option per command line flag.
# capsper has one settings type and the file names all of it, while the flags
# cover only the part that predates the file -- meeting capture, the voice
# activity gate and echo cancellation have no flags at all and were therefore
# unreachable from here. A freeform attribute set tracks that type without
# this module having to grow an option every time it gains a field.
{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.capsper;

  zon = import ./to-zon.nix { inherit lib; };

  rendered = pkgs.writeText "config.zon" (zon.toZON zon.enumPaths cfg.settings);

  # Rendering valid ZON is not the same as rendering settings capsper accepts:
  # an unknown field or a misspelled enum is a parse error, and finding it at
  # `nixos-rebuild` time beats finding it when the service will not start.
  # `--write-config` parses the file and exits before touching a model, a
  # device or the network, so this is cheap and runs in the sandbox.
  configFile = pkgs.runCommand "capsper-config.zon" { } ''
    ${lib.getExe cfg.package} --config ${rendered} --write-config > /dev/null
    cp ${rendered} $out
  '';

  args = [
    # Stays a flag rather than a setting because bin/capsper is a wrapper that
    # always passes --model, to move the default off the read-only store. A
    # `model` in the file would be overridden by it and silently do nothing;
    # the wrapper's arguments come first, so this one wins.
    "--model"
    cfg.modelDir
    "--config"
    configFile
  ]
  ++ cfg.extraArgs;
in
{
  options.services.capsper = {
    enable = lib.mkEnableOption "the capsper push-to-talk dictation service";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.capsper-cpu;
      defaultText = lib.literalExpression "capsper.packages.\${system}.capsper-cpu";
      description = ''
        The capsper package to run. Set this to `capsper-cuda` for NVIDIA
        GPU inference.

        On a laptop, prefer the CPU build. Holding a CUDA context keeps the
        discrete GPU out of D3cold for as long as the service runs; measured
        on an RTX 4070 Laptop that idles at ~3.5W with the model resident.
        Small in itself, but it is paid continuously, whereas the CPU build's
        cost is paid only while you are actually speaking (~1.4 cores) and
        leaves the GPU suspended at 0W the rest of the time. For push-to-talk,
        which is intermittent by definition, that favours the CPU build by a
        wide margin on battery.

        Releasing the GPU between presses is not a way out: the model lives in
        VRAM, which D3cold discards, and rebuilding the session costs ~3s
        before the first word.
      '';
    };

    modelDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.xdg.dataHome}/capsper/models/nemotron";
      defaultText = lib.literalExpression "\"\${config.xdg.dataHome}/capsper/models/nemotron\"";
      description = ''
        Directory holding the Nemotron model files. Deliberately a mutable
        path rather than a store path: the models are ~900MB and are versioned
        independently of capsper itself. See docs/nixos.md for how to fetch
        them.
      '';
    };

    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = lib.literalExpression ''
        {
          audio = {
            target = "alsa_input.usb-Focusrite_Vocaster-00.analog-stereo";
            gain = 10.0;
          };
          trigger.key = "capslock";
          meeting.enabled = true;
        }
      '';
      description = ''
        capsper's settings, rendered to the ZON config file it reads. The
        structure is capsper's `Config` type in `src/shared/config.zig`, and
        anything absent keeps capsper's own default rather than a default
        chosen here.

        Enum-valued settings are written as ordinary strings, so
        `trigger.key = "capslock"` and `audio.channel = "FR"` are what you
        want. The rendered file is parsed by capsper at build time, so a
        misspelled field or value fails the rebuild rather than the service.

        Run `capsper --audio-detect` once to find the right `audio.channel`
        and `audio.gain` for your microphone. An existing command line can be
        converted with `capsper <its flags> --write-config`, which prints the
        settings those flags mean.
      '';
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Extra arguments appended to the capsper command line. Flags are
        applied over the config file, so anything here wins over `settings`
        for that setting.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ];

    systemd.user.services.capsper = {
      Unit = {
        Description = "Capsper push-to-talk dictation";
        Documentation = "https://github.com/danielbodart/capsper";
        # capsper opens a PipeWire stream at startup, so the session's
        # PipeWire has to be up first.
        After = [ "pipewire.service" ];
        Wants = [ "pipewire.service" ];
      };

      Service = {
        Type = "simple";
        ExecStart = "${lib.getExe cfg.package} ${lib.escapeShellArgs args}";
        Restart = "always";
        RestartSec = 5;
      };

      Install.WantedBy = [ "default.target" ];
    };

    assertions = [
      {
        # capsper needs a mode: push-to-talk, always-live capture, the TCP
        # server or meeting capture. With none of them it prints its usage and
        # exits, which under `Restart=always` is a restart loop rather than an
        # error anybody sees.
        assertion =
          (cfg.settings.trigger.key or null) != null
          || (cfg.settings.audio.target or null) != null
          || (cfg.settings.tcp_server.port or null) != null
          || (cfg.settings.meeting.enabled or false);
        message = ''
          services.capsper.settings gives capsper nothing to do. Set one of
          trigger.key, audio.target, tcp_server.port or meeting.enabled.
        '';
      }
    ];
  };
}
