
{
  lib,
  config,
  ...
}: {
  # Define the options that users can configure
  options.nyx.services.openssh = {
    enable = lib.mkEnableOption "openssh service";

    settings = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      description = "Additional settings for the OpenSSH daemon.";
      example = lib.literalExpression ''
        {
          PasswordAuthentication = true;
          PermitRootLogin = "yes";
        }
      '';
    };
  };

  # Apply the configuration if the service is enabled
  config = lib.mkIf (config.nyx.services.openssh.enable && config.nyx.services.enable) {
    services.openssh = {
      enable = true;
      openFirewall = true;
      startWhenNeeded = true;

      # Merge the default settings with the user's custom settings
      settings =
        # Default settings defined in the module
        {
          PasswordAuthentication = false;
          PermitRootLogin = "no";
          AllowUsers = config.nyx.data.users;
        }
        # User-provided settings will override the defaults
        // config.nyx.services.openssh.settings;

      knownHosts = {
        # You can also make this configurable if needed
      };
    };
  };
}
