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
# It also means the configuration lives here rather than being parsed back out
# of the generated ExecStart line, which is what install.sh's
# extract_service_config has to do on every upgrade.
{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.capsper;

  args = [
    "--model"
    cfg.modelDir
  ]
  ++ lib.optionals (cfg.trigger != null) [
    "--trigger"
    cfg.trigger
  ]
  ++ lib.optionals (cfg.audioTarget != null) [
    "--audio-target"
    cfg.audioTarget
  ]
  ++ [
    "--audio-channel"
    cfg.audioChannel
  ]
  ++ lib.optionals (cfg.audioGain != null) [
    "--audio-gain"
    (toString cfg.audioGain)
  ]
  ++ lib.optionals (cfg.dropTerms != null) [
    "--drop-terms"
    (toString cfg.dropTerms)
  ]
  ++ lib.optionals (cfg.recordDir != null) [
    "--record-dir"
    cfg.recordDir
  ]
  ++ lib.optional cfg.lowLatency "--low-latency"
  ++ lib.optionals (cfg.port != null) [
    "--port"
    (toString cfg.port)
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

        On a laptop using PRIME offload with finegrained power management,
        note that capsper as an always-on service holds a CUDA context, which
        keeps the discrete GPU awake permanently -- the opposite of what
        offload is for. The CPU build may be the better trade on battery.
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

    trigger = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "capslock";
      description = ''
        Push-to-talk key. Set to null for always-live capture, which requires
        `audioTarget` to be set.
      '';
    };

    audioTarget = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "alsa_input.pci-0000_00_1f.3.analog-stereo";
      description = ''
        PipeWire node to capture from. Leave null to use the default source.
        `capsper --audio-detect` lists candidates.
      '';
    };

    audioChannel = lib.mkOption {
      type = lib.types.str;
      default = "FL";
      description = "Channel to capture. `capsper --audio-detect` recommends one.";
    };

    audioGain = lib.mkOption {
      type = lib.types.nullOr lib.types.float;
      default = null;
      example = 2.5;
      description = "Input gain multiplier. `capsper --audio-detect` recommends one.";
    };

    dropTerms = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "File of filler phrases to suppress, one per line.";
    };

    recordDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Save audio snippets and transcription logs here, for troubleshooting.";
    };

    lowLatency = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Keep the microphone stream open between presses, saving ~300ms on
        first-emit latency. The desktop microphone indicator then stays
        visible at all times, not just while speaking.
      '';
    };

    port = lib.mkOption {
      type = lib.types.nullOr lib.types.port;
      default = null;
      example = 43007;
      description = "Listen for remote transcription clients on this TCP port.";
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra arguments appended to the capsper command line.";
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
        assertion = cfg.trigger != null || cfg.audioTarget != null;
        message = "services.capsper: with no trigger (always-live capture), audioTarget must be set.";
      }
    ];
  };
}
