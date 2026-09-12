# Rendering a Nix value as ZON, so the module can hand capsper a config file
# instead of a command line.
#
# There is no `pkgs.formats.zon`, and ZON is not JSON: containers are `.{ ... }`
# rather than `{ ... }` or `[ ... ]`, struct fields are `.name = value`, and an
# enum is the bare literal `.capslock` rather than a quoted string.
#
# That last one is the only part with no Nix equivalent, because Nix has no
# enums. Two ways round it, and both are here:
#
#   * `enumPaths` names the settings whose values are enums, so an ordinary Nix
#     string renders as a ZON enum literal. This is what keeps a user's
#     `trigger.key = "capslock"` reading like every other setting.
#   * `tag "capslock"` says so at the point of use, for a field `enumPaths` has
#     not been told about -- a new enum in capsper against an older module.
#
# `enumPaths` does duplicate a little of capsper's schema, which is worth being
# uneasy about. What makes it safe is that the module validates the rendered
# file by running capsper against it at build time: drift shows up as a failed
# `nixos-rebuild` naming the field, not as a service that will not start.
{ lib }:

let
  # A ZON enum literal, for a field `enumPaths` does not cover.
  tag = name: { __zonTag = name; };

  isTag = v: builtins.isAttrs v && v ? __zonTag;

  indent = depth: lib.concatStrings (lib.genList (_: "    ") depth);

  # ZON string literals escape as Zig's do. Only the characters that can
  # plausibly reach here are handled; a node name or a path has no business
  # carrying a control character, and one that did would fail capsper's own
  # parse rather than being silently mangled.
  escapeString =
    s:
    ''"''
    + lib.replaceStrings [ "\\" "\"" "\n" "\r" "\t" ] [ "\\\\" "\\\"" "\\n" "\\r" "\\t" ] s
    + ''"'';

  # `path` is the dotted name of the value being rendered, which is how
  # `enumPaths` is matched. The top level has no name, so it starts empty.
  render =
    enumPaths: depth: path: value:
    let
      isEnum = builtins.elem path enumPaths;
      pad = indent depth;
      inner = indent (depth + 1);
    in
    if isTag value then
      ".${value.__zonTag}"
    else if value == null then
      "null"
    else if builtins.isBool value then
      (if value then "true" else "false")
    else if builtins.isInt value || builtins.isFloat value then
      builtins.toString value
    else if builtins.isString value then
      (if isEnum then ".${value}" else escapeString value)
    else if builtins.isList value then
      (
        if value == [ ] then
          ".{}"
        else
          ".{\n"
          + lib.concatMapStrings (v: "${inner}${render enumPaths (depth + 1) path v},\n") value
          + "${pad}}"
      )
    else if builtins.isAttrs value then
      (
        let
          # Sorted, so the same settings always render to the same bytes and a
          # rebuild that changed nothing produces no new store path.
          names = builtins.attrNames value;
          field =
            name:
            let
              child = if path == "" then name else "${path}.${name}";
            in
            "${inner}.${name} = ${render enumPaths (depth + 1) child value.${name}},\n";
        in
        if names == [ ] then ".{}" else ".{\n" + lib.concatMapStrings field names + "${pad}}"
      )
    else
      throw "toZON: cannot render ${builtins.typeOf value} at '${path}'";

in
{
  inherit tag;

  # The settings whose values capsper declares as enums. Kept here rather than
  # in the module because it belongs with the renderer that uses it.
  enumPaths = [
    "audio.channel"
    "audio.on_device_lost"
    "trigger.key"
    "debug_recording.audio_format"
    "debug_recording.detail"
    "meeting.audio_format"
    "meeting.detail"
  ];

  toZON = enumPaths: value: render enumPaths 0 "" value + "\n";
}
