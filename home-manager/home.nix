{ config, pkgs, ... }:

{
    imports = [
        ../modules/shell
        ../modules/desktop
        ../modules/terminal
    ];

	home = {
		username = "teto";
		homeDirectory = "/home/teto";
        stateVersion = "24.05";
		enableNixpkgsReleaseCheck = false;
		packages = with pkgs; [
            swaybg
		];
        pointerCursor = {
			name = "Adwaita";
			package = pkgs.gnome.adwaita-icon-theme;
        };
  	};
}
