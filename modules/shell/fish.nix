{ config, pkgs, ... }: {
	programs.fish = {
		enable = true;
   		interactiveShellInit = ''
      			set fish_greeting # Disable greeting
    	 	'';
		plugins = [
			{ name = "tide"; src = pkgs.fishPlugins.tide.src; }	
		];
                shellAliases =
                let
                        flakePath = "~/nix";
                in {
                        rebuild = "sudo nixos-rebuild switch --flake ${flakePath}";
                        hms = "home-manager switch --flake ${flakePath}";
                        v = "vim";
                };
	};
}
