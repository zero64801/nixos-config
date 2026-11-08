{ lib, pkgs, config, ... }:

{
  users.users.dx = {
    description = "dx";
    shell = pkgs.fish;
    isNormalUser = true;

    extraGroups = [
      "wheel"
      "networkmanager"
      "tss"
      "gamemode"
      "video"
    ] ++ config.my.security.serviceAdminGroups;

    hashedPasswordFile = "/persist/local/secrets/passwd/dx";
  };

  security.pam.u2f.settings.authfile = lib.mkForce (pkgs.writeText "u2f_keys" "dx:fes0NowJ4+HgTD3hg/RZTbhAhjLwM/H386nKvYGCGFsjDB7G8RMOnvvWMU/xOo2408pWB1EEP3tAW2UdLmzDfw==,3Db+pACcUuh47PRVGSAiwWiG21xNInfNYG8fElgLCxvbqr4jiPwQW8D+6uubCsePRaOFbljI3gMjuVFDsk/G9g==,es256,+presence:rXK3bKANMFojoX38CrbX0K+xAEH9+0KJ4+90Xe3rkoMth36YT6cyZDF9MDDGK1jL1cZCryWziObYkfCG/q55Tw==,Is+tB9fFwzboMFdXULO5v2jEd7Wbs9SEAdqIbqMNzX50r7AWfyYdn4N27aQ9TrdSWVAlK5AeFgV8DleEMRlJOw==,es256,+presence");

  hm.home.packages = with pkgs; [
    vim
    wget
    curl
    fastfetch
  ];
}
