# why is this a nix file?
# well writing this in .conf looks ugly so yeah .w.
{writeText}: let
  shaderFolder = ./shaders;
in
  writeText "input.conf" ''
    CTRL+1 no-osd change-list glsl-shaders set "${builtins.concatStringsSep ":" [

    ]}";

    CTRL+0 no-osd change-list glsl-shaders clr ""; show-text "GLSL shaders cleared"
  ''
