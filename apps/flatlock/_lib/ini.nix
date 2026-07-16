{ lib }:

let
  trim =
    value:
    let
      match = builtins.match "[[:space:]]*(.*[^[:space:]]|)[[:space:]]*" value;
    in
    if match == null then "" else builtins.elemAt match 0;

  parse =
    content:
    (builtins.foldl'
      (
        state: rawLine:
        let
          line = trim rawLine;
          isComment = lib.hasPrefix "#" line || lib.hasPrefix ";" line;
          isSection = !isComment && lib.hasPrefix "[" line && lib.hasSuffix "]" line;
          section = lib.removeSuffix "]" (lib.removePrefix "[" line);
          keyValue = builtins.match "^([^=]+)=(.*)$" line;
          values =
            if keyValue == null then
              [ ]
            else
              builtins.filter (value: value != "") (lib.splitString ";" (trim (builtins.elemAt keyValue 1)));
          value =
            if builtins.length values > 1 then
              values
            else if keyValue == null then
              ""
            else
              trim (builtins.elemAt keyValue 1);
        in
        if line == "" || isComment then
          state
        else if isSection then
          state // { current = section; }
        else if keyValue != null && state.current != null then
          state
          // {
            sections = state.sections // {
              ${state.current} = (state.sections.${state.current} or { }) // {
                ${trim (builtins.elemAt keyValue 0)} = value;
              };
            };
          }
        else
          state
      )
      {
        current = null;
        sections = { };
      }
      (lib.splitString "\n" content)
    ).sections;

  merge = base: overlay: lib.recursiveUpdate base overlay;

  renderValue =
    value: if builtins.isList value then lib.concatStringsSep ";" value else toString value;

  render =
    sections:
    lib.concatStringsSep "\n" (
      lib.mapAttrsToList (
        section: values:
        "[${section}]\n"
        + lib.concatStringsSep "\n" (lib.mapAttrsToList (key: value: "${key}=${renderValue value}") values)
      ) sections
    )
    + lib.optionalString (sections != { }) "\n";
in
{
  inherit merge parse render;
}
