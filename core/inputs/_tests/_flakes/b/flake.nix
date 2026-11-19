{
  outputs =
    { self, nixpkgs }:
    {
      name = "b";
      saw = nixpkgs.name;
    };
}
