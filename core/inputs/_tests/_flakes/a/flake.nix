{
  outputs =
    {
      self,
      b,
      nixpkgs,
      plain,
    }:
    {
      name = "a";
      saw = {
        b = b.name;
        nixpkgs = nixpkgs.name;
        plain = builtins.readFile (plain + "/file");
        own = self.name;
        throughB = b.saw;
      };
    };
}
