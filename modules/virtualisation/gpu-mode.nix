{ config, lib, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkIf mkOption types concatStringsSep concatMapStringsSep escapeShellArg;

  cfg = config.my.virtualisation.gpuMode;
  vfioCfg = config.my.virtualisation.desktop.vfio;
  lgEnabled = config.my.virtualisation.desktop.looking-glass.enable or false;

  pciPredicate = addr:
    let
      parts = lib.splitString ":" addr;
      busSlotFn = lib.drop (lib.length parts - 2) parts;
      bus = lib.elemAt busSlotFn 0;
      slotFn = lib.splitString "." (lib.elemAt busSlotFn 1);
      slot = lib.elemAt slotFn 0;
      fn = lib.elemAt slotFn 1;
    in "source/address[@bus='0x${bus}' and @slot='0x${slot}' and @function='0x${fn}']";

  modeEdits = m: lib.concatLists (
    (map (a: [ "-d" "/domain/devices/hostdev[@type='pci'][${pciPredicate a}]" ]) m.stripHostdevs)
    ++ (map (s: [ "-d" "/domain/qemu:commandline/qemu:arg[contains(@value,'${s}')]/preceding-sibling::qemu:arg[1]" ]) m.stripQemuArgs)
    ++ (map (s: [ "-d" "/domain/qemu:commandline/qemu:arg[contains(@value,'${s}')]" ]) m.stripQemuArgs)
    ++ lib.optional (m.stripQemuArgs != [ ]) [ "-d" "/domain/qemu:commandline[not(qemu:arg) and not(qemu:env)]" ]
    ++ lib.optional (m.video != null) [ "-u" "/domain/devices/video/model/@type" "-v" m.video ]
    ++ lib.optional (m.resolution != null) (
      let wh = lib.splitString "x" m.resolution; in [
        "-d" "/domain/devices/video/model/resolution"
        "-s" "/domain/devices/video/model" "-t" "elem" "-n" "resolution" "-v" ""
        "-i" "/domain/devices/video/model/resolution" "-t" "attr" "-n" "x" "-v" (lib.elemAt wh 0)
        "-i" "/domain/devices/video/model/resolution" "-t" "attr" "-n" "y" "-v" (lib.elemAt wh 1)
      ])
    ++ lib.optional (m.accel3d == true) (
      let g = "/domain/devices/graphics[@type='spice']"; in [
        "-d" "/domain/devices/video/model/acceleration"
        "-s" "/domain/devices/video/model" "-t" "elem" "-n" "acceleration" "-v" ""
        "-i" "/domain/devices/video/model/acceleration" "-t" "attr" "-n" "accel3d" "-v" "yes"
        "-d" "${g}/gl" "-d" "${g}/listen" "-d" "${g}/@autoport" "-d" "${g}/@port" "-d" "${g}/@tlsPort"
        "-s" g "-t" "elem" "-n" "listen" "-v" ""
        "-i" "${g}/listen" "-t" "attr" "-n" "type" "-v" "none"
        "-s" g "-t" "elem" "-n" "gl" "-v" ""
        "-i" "${g}/gl" "-t" "attr" "-n" "enable" "-v" "yes"
      ] ++ lib.optionals (cfg.renderNode != null) [ "-i" "${g}/gl" "-t" "attr" "-n" "rendernode" "-v" cfg.renderNode ]
    )
    ++ [ m.extraEdits ]
  );

  effectiveMode = dom: name:
    let
      base = cfg.modes.${name};
      o = (cfg.domains.${dom}.modes.${name} or { });
      pick = field: if (o.${field} or null) == null then base.${field} else o.${field};
    in {
      stripHostdevs = pick "stripHostdevs";
      stripQemuArgs = pick "stripQemuArgs";
      video = pick "video";
      resolution = pick "resolution";
      accel3d = pick "accel3d";
      extraEdits = pick "extraEdits";
    };

  modeCase = concatStringsSep "\n" (lib.concatLists (lib.mapAttrsToList (dom: _:
    lib.mapAttrsToList (name: _:
      let m = effectiveMode dom name; in ''
        ${dom}/${name}) EDITS=(${lib.escapeShellArgs (modeEdits m)}); VIDEO=${escapeShellArg (if m.video == null then "" else m.video)} ;;''
    ) cfg.modes
  ) cfg.domains));

  modePattern = concatStringsSep "|" (lib.attrNames cfg.modes);
  domainPattern = concatStringsSep "|" (lib.attrNames cfg.domains);

  vm-gpu = pkgs.writeShellApplication {
    name = "vm-gpu";
    runtimeInputs = [ config.virtualisation.libvirtd.package pkgs.xmlstarlet pkgs.coreutils pkgs.gnugrep ];
    text = ''
      export LIBVIRT_DEFAULT_URI=qemu:///system
      STATE_DIR=/var/lib/my/gpu-mode
      OVERRIDE_DIR=/run/my/gpu-mode
      DOMAINS="${concatStringsSep " " (lib.attrNames cfg.domains)}"
      MODES="${concatStringsSep " " (lib.attrNames cfg.modes)}"
      DEFAULT_MODE="${cfg.defaultMode}"
      NS=(-N qemu=http://libvirt.org/schemas/domain/qemu/1.0)
      TMPXML=""
      trap '[ -n "$TMPXML" ] && rm -f "$TMPXML"' EXIT

      usage() {
        cat <<USAGE
      usage: vm-gpu                          show each domain's mode and state
             vm-gpu <domain> <mode>          set the persistent mode
             vm-gpu <domain> <mode> --once   use <mode> for the next start only
             vm-gpu start <domain> [mode] [--paused]
                                             start the domain in its effective mode (persistent XML is never modified)
             vm-gpu xml <domain> [mode]      print the XML a start would use

      domains: $DOMAINS
      modes:   $MODES (default: $DEFAULT_MODE)
      USAGE
      }

      die() { echo "vm-gpu: $*" >&2; exit 1; }

      check_domain() { case "$1" in ${domainPattern}) ;; *) die "unknown domain '$1' (managed: $DOMAINS)" ;; esac; }
      check_mode() { case "$1" in ${modePattern}) ;; *) die "unknown mode '$1' (modes: $MODES)" ;; esac; }

      saved_mode() {
        local m=""
        [ -r "$STATE_DIR/$1" ] && m=$(cat "$STATE_DIR/$1")
        case "$m" in ${modePattern}) printf '%s' "$m" ;; *) printf '%s' "$DEFAULT_MODE" ;; esac
      }

      once_mode() {
        local m=""
        [ -r "$OVERRIDE_DIR/$1" ] && m=$(cat "$OVERRIDE_DIR/$1")
        case "$m" in ${modePattern}) printf '%s' "$m" ;; *) printf '%s' "" ;; esac
      }

      mode_vars() {
        case "$1/$2" in
        ${modeCase}
          *) die "no mode '$2' for domain '$1'" ;;
        esac
      }

      render_xml() {
        local dom="$1" mode="$2"
        mode_vars "$dom" "$mode"
        local xml
        xml=$(virsh dumpxml "$dom" --inactive --security-info)
        if [ "''${#EDITS[@]}" -eq 0 ]; then printf '%s\n' "$xml"; return; fi
        if [ -n "$VIDEO" ] && [ "$(printf '%s' "$xml" | xmlstarlet sel "''${NS[@]}" -t -v 'count(/domain/devices/video)')" = 0 ]; then
          xml=$(printf '%s' "$xml" | xmlstarlet ed "''${NS[@]}" -s /domain/devices -t elem -n video -v "" \
            -s "/domain/devices/video[last()]" -t elem -n model -v "" \
            -i "/domain/devices/video[last()]/model" -t attr -n type -v "$VIDEO")
        fi
        printf '%s' "$xml" | xmlstarlet ed "''${NS[@]}" "''${EDITS[@]}"
      }

      cmd_status() {
        printf '%-12s %-14s %s\n' DOMAIN MODE STATE
        for d in $DOMAINS; do
          local m once
          m=$(saved_mode "$d"); once=$(once_mode "$d")
          [ -n "$once" ] && m="$once (once)"
          printf '%-12s %-14s %s\n' "$d" "$m" "$(virsh domstate "$d" 2>/dev/null | head -1 || echo unknown)"
        done
      }

      cmd_set() {
        local dom="$1" mode="$2" once="''${3:-}"
        check_domain "$dom"; check_mode "$mode"
        if [ "$once" = "--once" ]; then
          printf '%s' "$mode" > "$OVERRIDE_DIR/$dom"
          echo "vm-gpu: $dom will start in '$mode' once"
        else
          [ -n "$once" ] && die "unexpected argument '$once'"
          printf '%s' "$mode" > "$STATE_DIR/$dom"
          rm -f "$OVERRIDE_DIR/$dom"
          echo "vm-gpu: $dom mode set to '$mode'"
        fi
      }

      cmd_start() {
        local dom="" mode="" paused=""
        for a in "$@"; do
          case "$a" in
            --paused) paused="--paused" ;;
            *) if [ -z "$dom" ]; then dom="$a"; elif [ -z "$mode" ]; then mode="$a"; else die "unexpected argument '$a'"; fi ;;
          esac
        done
        [ -n "$dom" ] || die "start needs a domain"
        check_domain "$dom"
        local used_once=0
        if [ -z "$mode" ]; then
          mode=$(once_mode "$dom")
          if [ -n "$mode" ]; then used_once=1; else mode=$(saved_mode "$dom"); fi
        fi
        check_mode "$mode"
        [ "$(virsh domstate "$dom" 2>/dev/null)" = "shut off" ] || die "$dom is not shut off"
        mode_vars "$dom" "$mode"
        if [ "''${#EDITS[@]}" -eq 0 ]; then
          echo "vm-gpu: starting $dom ($mode, persistent definition)"
          virsh start "$dom" ''${paused:+--paused}
        else
          TMPXML=$(mktemp)
          render_xml "$dom" "$mode" > "$TMPXML"
          echo "vm-gpu: starting $dom ($mode, transient definition; persistent XML untouched)"
          virsh create "$TMPXML" ''${paused:+--paused}
        fi
        [ "$used_once" = 1 ] && rm -f "$OVERRIDE_DIR/$dom"
      }

      cmd_xml() {
        local dom="$1" mode="''${2:-}"
        check_domain "$dom"
        [ -n "$mode" ] || { mode=$(once_mode "$dom"); [ -n "$mode" ] || mode=$(saved_mode "$dom"); }
        check_mode "$mode"
        render_xml "$dom" "$mode"
      }

      case "''${1:-}" in
        "") cmd_status ;;
        -h|--help|help) usage ;;
        start) shift; cmd_start "$@" ;;
        xml) shift; [ $# -ge 1 ] || die "xml needs a domain"; cmd_xml "$@" ;;
        *) [ $# -ge 2 ] || { usage >&2; exit 1; }; cmd_set "$@" ;;
      esac
    '';
  };

  overrideType = types.submodule {
    options = {
      stripHostdevs = mkOption { type = types.nullOr (types.listOf types.str); default = null; description = "Override the mode's stripHostdevs for this domain."; };
      stripQemuArgs = mkOption { type = types.nullOr (types.listOf types.str); default = null; description = "Override the mode's stripQemuArgs for this domain."; };
      video = mkOption { type = types.nullOr types.str; default = null; description = "Override the mode's video model for this domain (virtio, qxl, vga, bochs)."; };
      resolution = mkOption { type = types.nullOr (types.strMatching "[0-9]+x[0-9]+"); default = null; description = "Override the mode's preferred resolution for this domain (WxH)."; };
      accel3d = mkOption { type = types.nullOr types.bool; default = null; description = "Override the mode's 3D acceleration setting for this domain."; };
      extraEdits = mkOption { type = types.nullOr (types.listOf types.str); default = null; description = "Override the mode's extraEdits for this domain."; };
    };
  };

  domainType = types.submodule {
    options.modes = mkOption {
      type = types.attrsOf overrideType;
      default = { };
      description = "Per-domain overrides of the global modes, keyed by mode name.";
    };
  };

  modeType = types.submodule {
    options = {
      stripHostdevs = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "PCI addresses (01:00.0) whose <hostdev> entries are removed from the start XML.";
      };
      stripQemuArgs = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Substrings; any <qemu:arg> whose value contains one is removed together with the flag argument before it.";
      };
      video = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Video model to set on the start XML (virtio, qxl, vga, bochs). null leaves the definition's model.";
      };
      resolution = mkOption {
        type = types.nullOr (types.strMatching "[0-9]+x[0-9]+");
        default = null;
        example = "2560x1440";
        description = "Preferred EDID resolution written as <resolution x y/> on the video model. null leaves the definition.";
      };
      accel3d = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = "true adds <acceleration accel3d=\"yes\"/> to the video model and switches spice to GL on gpuMode.renderNode (listen type none, as libvirt requires). null or false leave the definition.";
      };
      extraEdits = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Extra xmlstarlet ed arguments, one argv word per element, appended to the mode's edits.";
      };
    };
  };
in
{
  options.my.virtualisation.gpuMode = {
    enable = mkEnableOption "per-start GPU mode for passthrough domains (vm-gpu)";

    domains = mkOption {
      type = types.attrsOf domainType;
      default = { };
      example = lib.literalExpression ''{ win11 = { }; win11-re.modes.virtual.video = "qxl"; }'';
      description = "Libvirt domains vm-gpu may start and switch, each with optional per-mode overrides.";
    };

    defaultMode = mkOption {
      type = types.str;
      default = "passthrough";
      description = "Mode used when a domain has no saved mode.";
    };

    renderNode = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/dev/dri/renderD128";
      description = "DRM render node spice GL renders on when a mode enables accel3d. Set it on multi-GPU hosts, libvirt otherwise picks the first node.";
    };

    modes = mkOption {
      type = types.attrsOf modeType;
      default = { };
      description = ''
        Named modes. A mode is a set of edits applied to the persistent domain XML for one start.
        A mode with no edits starts the persistent definition directly.
      '';
    };

    package = mkOption {
      type = types.package;
      readOnly = true;
      default = vm-gpu;
      description = "The vm-gpu tool, exposed for building and testing outside a switch.";
    };
  };

  config = mkIf cfg.enable {
    my.virtualisation.gpuMode.modes = {
      passthrough = { };
      virtual = {
        stripHostdevs = lib.mkDefault vfioCfg.pciAddresses;
        stripQemuArgs = lib.mkDefault (lib.optional lgEnabled "looking-glass");
        video = lib.mkDefault "virtio";
      };
    };

    assertions = [
      {
        assertion = cfg.modes ? ${cfg.defaultMode};
        message = "my.virtualisation.gpuMode.defaultMode '${cfg.defaultMode}' is not among the defined modes.";
      }
      {
        assertion = cfg.domains != { };
        message = "my.virtualisation.gpuMode.domains is empty.";
      }
    ];

    environment.systemPackages = [ vm-gpu ];

    systemd.tmpfiles.rules = [
      "d /var/lib/my 0755 root root -"
      "d /var/lib/my/gpu-mode 2775 root libvirtd -"
      "d /run/my 0755 root root -"
      "d /run/my/gpu-mode 2775 root libvirtd -"
    ];

    my.persistence.directories = [ "/var/lib/my/gpu-mode" ];
  };
}
