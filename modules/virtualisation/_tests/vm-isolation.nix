# nix build --impure --no-link -L --expr 'import ./modules/virtualisation/_tests/vm-isolation.nix { }'
{
  flake ? builtins.getFlake (toString ../../..),
}:

let
  inherit (flake.inputs.nixpkgs) lib;

  # These check the rules a host ends up with, so every host that isolates its guests gets them, whatever it is called.
  isolating = lib.filterAttrs (
    _: system:
    let
      v = system.config.my.virtualisation;
    in
    v.base.enable && v.base.networkIsolation.enable && v.nixvirt.enable && v.nixvirt.qemuUsers.enable
  ) flake.nixosConfigurations;

  check =
    host: system:
    let
      inherit (system) pkgs config;

      isolation = config.my.virtualisation.base.networkIsolation;
      bridge = isolation.bridge;
      nixvirt = config.my.virtualisation.nixvirt;

      # Ports any module opened globally. The firewall applies those to every interface, so each one a guest must not reach has to be dropped by the isolation table.
      globalTcp = config.networking.firewall.allowedTCPPorts;
      globalUdp = config.networking.firewall.allowedUDPPorts;

      allowedTcp = [ 53 ] ++ isolation.allowedHostTCPPorts;
      allowedUdp = [ 53 67 ] ++ isolation.allowedHostUDPPorts;

      mustDropTcp = lib.subtractLists allowedTcp globalTcp;
      mustDropUdp = lib.subtractLists allowedUdp globalUdp;

      # The module passes the built ruleset to nft in the unit, it is not exposed as an option. The command line keeps the dependency, so the ruleset gets built.
      rulesetOf = sys: lib.concatStringsSep " " (lib.toList sys.config.systemd.services.nftables.serviceConfig.ExecStart);

      domainXml = map (d: d.definition) config.virtualisation.libvirt.connections."qemu:///system".domains;
      vmUsers = lib.filterAttrs (n: _: lib.hasPrefix "vm-" n) config.users.users;
      vmUids = lib.mapAttrsToList (_: u: u.uid) vmUsers;
      guests = map (lib.removePrefix "vm-") (lib.attrNames vmUsers);

      # A variant with grants of its own proves the rules a grant produces. Telling one guest's grant from another's takes two guests.
      grants = lib.length guests >= 2;
      first = lib.elemAt guests 0;
      second = lib.elemAt guests 1;
      granted = system.extendModules {
        modules = [
          {
            my.virtualisation.nixvirt.hostAccess = lib.mkForce {
              ${first}.tcp = [ 3000 ];
              ${second}.udp = [ 5353 ];
            };
          }
        ];
      };
    in
    pkgs.runCommand "vm-isolation-test-${host}"
      {
        nativeBuildInputs = [
          pkgs.nftables
          pkgs.libredirect
          pkgs.lklWithFirewall.lib
          pkgs.gnugrep
          pkgs.gawk
          pkgs.libvirt
        ];
        ruleset = rulesetOf system;
        grantedRuleset = lib.optionalString grants (rulesetOf granted);
      }
      ''
        set -euo pipefail
        fail() { echo "vm-isolation: $1" >&2; exit 1; }

        # nft parses and validates against a real kernel through lkl, the same hijack nixpkgs' own ruleset check uses.
        export NIX_REDIRECTS="/etc/protocols=${pkgs.iana-etc}/etc/protocols:/etc/services=${pkgs.iana-etc}/etc/services"
        check() {
          local rules
          rules=$(grep -o '/nix/store/[a-z0-9]*-nftables-rules' <<< "$1" | head -1)
          [ -n "$rules" ] || fail "no ruleset in the nftables unit"
          sed 's|include "/run/nftables/deletions.nft"||' "$rules" > "$2"
          LD_PRELOAD="${pkgs.libredirect}/lib/libredirect.so ${pkgs.lklWithFirewall.lib}/lib/liblkl-hijack.so" \
            nft --check --file "$2" || fail "the ruleset $2 was rejected by the kernel"
        }
        check "$ruleset" ruleset.conf
        ${lib.optionalString grants ''check "$grantedRuleset" granted.conf''}

        # The generated file indents inconsistently, so a table runs to the next table rather than to a brace.
        tableOf() { awk -v want="$2" '/^table /{inside = ($3 == want)} inside' "$1"; }
        chainOf() { sed -n "/chain $2 {/,/^[[:space:]]*}/p" <<< "$1"; }

        chain=$(chainOf "$(tableOf ruleset.conf vm-isolation)" input)
        [ -n "$chain" ] || fail "the isolation table has no input chain"
        cat <<< "$chain"

        grep -q 'hook input priority -100' <<< "$chain" \
          || fail "the input chain does not run before the firewall's own chain"
        # Anything after a drop is unreachable, so the last rule decides what a guest may not reach.
        [ "$(grep -cE '^[[:space:]]*drop$' <<< "$chain")" -eq 1 ] \
          || fail "expected exactly one unconditional drop"
        [ "$(grep -vE '^[[:space:]]*(chain|type|\}|$)' <<< "$chain" | tail -1 | tr -d '[:space:]')" = drop ] \
          || fail "the drop is not the last rule, so later accepts are dead"

        grep -q "iifname != \"${bridge}\" accept" <<< "$chain" \
          || fail "traffic from other interfaces is not let through to the firewall"
        grep -q 'ct state established,related accept' <<< "$chain" \
          || fail "replies to host-initiated connections are dropped"

        accepted() {
          # Guests reach a port only through an accept naming it, since the chain ends in drop.
          grep -E "^[[:space:]]*$1 dport \{[^}]*\b$2\b" <<< "$chain" > /dev/null
        }

        ${lib.concatMapStrings (p: ''
          accepted tcp ${toString p} || fail "guests cannot reach host tcp/${toString p}, which this host allows them"
        '') allowedTcp}
        ${lib.concatMapStrings (p: ''
          accepted udp ${toString p} || fail "guests cannot reach host udp/${toString p}, which this host allows them"
        '') allowedUdp}

        ${lib.concatMapStrings (p: ''
          accepted tcp ${toString p} && fail "tcp/${toString p} is open to the LAN and reachable from guests"
        '') mustDropTcp}
        ${lib.concatMapStrings (p: ''
          accepted udp ${toString p} && fail "udp/${toString p} is open to the LAN and reachable from guests"
        '') mustDropUdp}

        echo "ok   guests reach only tcp ${toString allowedTcp} / udp ${toString allowedUdp} on the host"
        echo "ok   host ports closed to guests: tcp ${toString mustDropTcp} / udp ${toString mustDropUdp}"

        net=${config.virtualisation.libvirt.connections."qemu:///system".networks |> lib.head |> (n: n.definition)}
        grep -q '<port isolated="yes"/>' "$net" || fail "the default network does not isolate guest ports"
        virt-xml-validate "$net" network > /dev/null || fail "the network definition is not valid libvirt XML"
        echo "ok   the default network isolates guests from each other"

        for xml in ${lib.escapeShellArgs domainXml}; do
          name=$(sed -n 's|.*<name>\(.*\)</name>.*|\1|p' "$xml" | head -1)
          grep -q "<label>vm-$name:vm-$name</label>" "$xml" || fail "$name does not run QEMU as its own user"
          grep -q 'model="dac" relabel="yes"' "$xml" || fail "$name would not get its files relabelled for that user"
          grep -q "<target dev=\"vm-$name\"/>" "$xml" || fail "$name has no fixed tap name for hostAccess to match"
        done
        echo "ok   every domain runs QEMU as vm-<name> with tap vm-<name>"

        egress=$(chainOf "$(tableOf ruleset.conf vm-qemu)" output)
        for uid in ${toString config.users.users.qemu-libvirtd.uid} ${toString vmUids}; do
          grep -E "meta skuid \{[^}]*\b$uid\b[^}]*\} ct state new drop" <<< "$egress" > /dev/null \
            || fail "QEMU user $uid may still open network connections"
        done
        echo "ok   no QEMU user can open a network connection"

        ${lib.optionalString grants ''
          ports=$(chainOf "$(tableOf granted.conf vm-ports)" input)
          grant=$(chainOf "$(tableOf granted.conf vm-isolation)" input)
          mark_of() { sed -n "s/.*iifname \"$1\" meta mark set \(0x[0-9A-Fa-f]*\).*/\1/p" <<< "$ports"; }
          w=$(mark_of vm-${first}); r=$(mark_of vm-${second})
          [ -n "$w" ] && [ -n "$r" ] || fail "a granted domain's tap is not marked"
          [ "$w" != "$r" ] || fail "two domains share a mark, so one would get the other's access"
          grep -q 'hook input priority' <<< "$ports" || fail "the marks are not set on the bridge input hook"
          before_drop=$(sed '/^[[:space:]]*drop$/q' <<< "$grant")
          grep -q "meta mark $w tcp dport { 3000 } accept" <<< "$before_drop" || fail "the grant of ${first} is missing or after the drop"
          grep -q "meta mark $r udp dport { 5353 } accept" <<< "$before_drop" || fail "the grant of ${second} is missing or after the drop"
          grep -q "meta mark $r tcp" <<< "$grant" && fail "${second} got a tcp grant it was never given"
          echo "ok   a grant reaches only the domain it names, matched by its tap"
        ''}

        touch $out
      '';
in
flake.inputs.nixpkgs.legacyPackages.${builtins.currentSystem}.linkFarm "vm-isolation-test" (
  lib.mapAttrs check isolating
)
