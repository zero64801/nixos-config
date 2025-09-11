let
  users = {
    dx = [

    ];
  };

  hosts = {
    Silverwing = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFtZZAZ198aqkOspngWCdyloRy700Uol8RLIKo6ATwgH" ];
  };
in {
  "secret6.age".publicKeys = hosts.Silverwing;
}
