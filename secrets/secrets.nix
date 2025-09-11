let
  users = {
    dx = [

    ];
  };

  hosts = {
    Silverwing = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMqqwJt+u7iBq9x0hZtnSfc80gi6h+q+xvmN3jwUTtE3 root@Silverwing" ];
  };
in {
  "secret6.age".publicKeys = hosts.Silverwing;
}
