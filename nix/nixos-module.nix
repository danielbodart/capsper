# System-level setup for capsper.
#
# This module deliberately does NOT define the dictation service, and does not
# install the package. capsper is per-user -- it grabs the keyboards of a login
# session and talks to that user's PipeWire -- so both belong in home-manager
# (see homeModules.default). What has to happen at the system level is
# only the part a user cannot grant themselves: the uinput kernel module, the
# device permissions, and group membership.
#
# This replaces what dist/linux/install.sh does imperatively with `usermod -aG`
# and by writing /etc/udev/rules.d/99-uinput.rules.
{ self }:
{ config, lib, ... }:

let
  cfg = config.services.capsper;
in
{
  options.services.capsper = {
    enable = lib.mkEnableOption "system support for capsper voice dictation";

    users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "alice" ];
      description = ''
        Users to grant keyboard and text-injection access. Adds each to the
        `input` group, to read /dev/input/event* (root:input 0660), and to the
        `uinput` group, to open /dev/uinput for injecting the transcribed text.

        Group membership only takes effect on the user's next login.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Loads the uinput kernel module and installs the udev rule that makes
    # /dev/uinput group-writable by `uinput`. Without it the node is
    # root:root 0600 and capsper cannot inject anything.
    hardware.uinput.enable = true;

    users.users = lib.genAttrs cfg.users (_: {
      extraGroups = [
        "input"
        "uinput"
      ];
    });

    assertions = [
      {
        assertion = config.services.pipewire.enable;
        message = "services.capsper requires services.pipewire.enable -- capsper captures audio via PipeWire.";
      }
    ];
  };
}
