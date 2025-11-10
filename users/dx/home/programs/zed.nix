{
  pkgs,
  ...
}:
{
  programs.zed-editor = {
    enable = true;
    userSettings = {
      features = {
        copilot = false;
      };
      telemetry = {
        metrics = false;
      };
    };
    extensions = [
      "nix"
    ];
    extraPackages = [
      pkgs.nil
    ];
  };
}
