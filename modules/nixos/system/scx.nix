{
  config,
  pkgs,
  lib,
  ...
}:

let
  scx-env =
    if lib.isDerivation pkgs.scx then
      pkgs.scx
    else
      pkgs.symlinkJoin {
        name = "scx-all-schedulers";
        paths = lib.attrValues (lib.filterAttrs (n: v: lib.isDerivation v) pkgs.scx);
      };

  scx-switch = pkgs.writeShellScriptBin "scx-switch" ''
    if [ "$EUID" -ne 0 ]; then
      echo "Root required"
      exit 1
    fi

    CMD="$1"
    SCHEDULER="$2"
    FLAGS="$3"

    case "$CMD" in
      disable)
        systemctl stop scx 2>/dev/null || true
        systemctl stop scx-manual 2>/dev/null || true
        echo "Schedulers disabled"
        ;;
      apply)
        systemctl stop scx 2>/dev/null || true
        systemctl stop scx-manual 2>/dev/null || true

        # Handle full path or just name
        if [[ "$SCHEDULER" == /* ]]; then
            BINARY="$SCHEDULER"
        else
            BINARY="${scx-env}/bin/$SCHEDULER"
        fi

        if [ ! -f "$BINARY" ]; then
          echo "Scheduler binary not found: $BINARY"
          exit 1
        fi

        systemd-run --unit=scx-manual \
                    --description="SCX Manager: $SCHEDULER" \
                    --service-type=simple \
                    $BINARY $FLAGS
        ;;
      *)
        echo "Usage: scx-switch [apply|disable] <scheduler> [flags]"
        exit 1
        ;;
    esac
  '';

  iconPath = "${pkgs.nixos-icons}/share/icons/hicolor/scalable/apps/nix-snowflake.svg";

  scx-gui =
    pkgs.writers.writePython3Bin "scx-manager"
      {
        libraries = with pkgs.python3Packages; [ pyqt6 ];
        # Added extra ignores (F401, E302, E701, E305) to allow the original code to build
        flakeIgnore = [ "E501" "F401" "E302" "E701" "E305" ];
      }
      ''
        import sys
        import os
        import subprocess
        from PyQt6.QtWidgets import (QApplication, QMainWindow, QWidget, QVBoxLayout,
                                     QHBoxLayout, QGridLayout, QLabel, QComboBox,
                                     QLineEdit, QPushButton, QSpacerItem, QSizePolicy)
        from PyQt6.QtCore import QTimer, Qt
        from PyQt6.QtGui import QIcon

        SCX_SWITCH = "${scx-switch}/bin/scx-switch"
        SCX_BIN_PATH = "${scx-env}/bin"
        ICON_PATH = "${iconPath}"


        class SchedExtWindow(QMainWindow):
            def __init__(self):
                super().__init__()
                self.setWindowTitle("NixOS Configure sched-ext")
                self.setWindowIcon(QIcon(ICON_PATH))
                self.resize(600, 400)

                central_widget = QWidget()
                self.setCentralWidget(central_widget)
                main_layout = QVBoxLayout(central_widget)

                main_layout.addSpacerItem(QSpacerItem(20, 20, QSizePolicy.Policy.Minimum, QSizePolicy.Policy.Fixed))

                title_label = QLabel("Configure sched-ext scheduler:")
                title_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
                font = title_label.font()
                font.setPointSize(12)
                title_label.setFont(font)
                main_layout.addWidget(title_label)

                main_layout.addSpacerItem(QSpacerItem(20, 20, QSizePolicy.Policy.Minimum, QSizePolicy.Policy.Fixed))

                grid = QGridLayout()
                grid.setColumnStretch(0, 1)
                grid.setColumnStretch(4, 1)

                self.lbl_running = QLabel("Running sched-ext scheduler:")
                self.val_running = QLabel("unknown")
                grid.addWidget(self.lbl_running, 0, 1)
                grid.addWidget(self.val_running, 0, 3)

                self.lbl_select = QLabel("Select sched-ext scheduler:")
                self.combo_sched = QComboBox()
                self.populate_schedulers()
                self.combo_sched.currentTextChanged.connect(self.on_sched_changed)
                grid.addWidget(self.lbl_select, 1, 1)
                grid.addWidget(self.combo_sched, 1, 3)

                self.lbl_profile = QLabel("Select scheduler profile:")
                self.combo_profile = QComboBox()
                self.combo_profile.addItems(["Auto", "Gaming", "PowerSave", "LowLatency", "Server"])
                self.combo_profile.currentTextChanged.connect(self.update_flags_from_profile)
                grid.addWidget(self.lbl_profile, 2, 1)
                grid.addWidget(self.combo_profile, 2, 3)

                self.lbl_flags = QLabel("Set sched-ext extra scheduler flags:")
                self.edit_flags = QLineEdit()
                grid.addWidget(self.lbl_flags, 3, 1)
                grid.addWidget(self.edit_flags, 3, 3)

                main_layout.addLayout(grid)
                main_layout.addSpacerItem(QSpacerItem(20, 40, QSizePolicy.Policy.Minimum, QSizePolicy.Policy.Expanding))

                btn_layout = QHBoxLayout()
                btn_layout.addSpacerItem(QSpacerItem(40, 20, QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Minimum))

                self.btn_disable = QPushButton("Disable")
                self.btn_disable.clicked.connect(self.on_disable)
                btn_layout.addWidget(self.btn_disable)

                self.btn_apply = QPushButton("Apply")
                self.btn_apply.clicked.connect(self.on_apply)
                btn_layout.addWidget(self.btn_apply)

                main_layout.addLayout(btn_layout)

                self.timer = QTimer()
                self.timer.timeout.connect(self.update_status)
                self.timer.start(1000)
                self.update_status()

            def populate_schedulers(self):
                try:
                    files = os.listdir(SCX_BIN_PATH)
                    scheds = [f for f in files if f.startswith("scx_")]
                    scheds.sort()
                    self.combo_sched.addItems(scheds)

                    current_ops = ""
                    try:
                        with open("/sys/kernel/sched_ext/root/ops", "r") as f:
                            current_ops = f.read().strip()
                    except Exception:
                        pass

                    target_index = -1

                    if current_ops:
                        for i in range(self.combo_sched.count()):
                            item_text = self.combo_sched.itemText(i)
                            core_name = item_text.replace("scx_", "")
                            if current_ops.startswith(core_name):
                                target_index = i
                                break

                    if target_index >= 0:
                        self.combo_sched.setCurrentIndex(target_index)
                    else:
                        rusty_index = self.combo_sched.findText("scx_rusty")
                        if rusty_index >= 0:
                            self.combo_sched.setCurrentIndex(rusty_index)

                except Exception:
                    self.combo_sched.addItem("Error finding schedulers")

            def update_status(self):
                try:
                    with open("/sys/kernel/sched_ext/root/ops", "r") as f:
                        current = f.read().strip()
                        self.val_running.setText(current if current else "None (Standard Kernel)")
                except FileNotFoundError:
                    self.val_running.setText("None (Standard Kernel)")
                except Exception:
                    self.val_running.setText("Error reading status")

            def on_sched_changed(self, text):
                self.update_flags_from_profile(self.combo_profile.currentText())

            def update_flags_from_profile(self, profile):
                flags = ""
                sched = self.combo_sched.currentText()

                if profile == "Gaming":
                    if "lavd" in sched:
                        flags = "--performance"
                elif profile == "LowLatency":
                    if "lavd" in sched:
                        flags = "--nopreempt"
                elif profile == "PowerSave":
                    if "lavd" in sched:
                        flags = "--powersave"

                self.edit_flags.setText(flags)

            def on_apply(self):
                sched = self.combo_sched.currentText()
                flags = self.edit_flags.text()

                cmd = ["pkexec", SCX_SWITCH, "apply", sched, flags]
                subprocess.Popen(cmd)

                QTimer.singleShot(500, self.update_status)

            def on_disable(self):
                cmd = ["pkexec", SCX_SWITCH, "disable", "", ""]
                subprocess.Popen(cmd)
                QTimer.singleShot(500, self.update_status)


        if __name__ == "__main__":
            app = QApplication(sys.argv)
            window = SchedExtWindow()
            window.show()
            sys.exit(app.exec())
      '';

  scx-desktop-item = pkgs.makeDesktopItem {
    name = "scx-manager";
    desktopName = "SCX Manager";
    genericName = "Scheduler Ext Manager";
    comment = "Manage sched-ext schedulers on NixOS";
    exec = "scx-manager";
    icon = "nix-snowflake";
    categories = [ "System" "Settings" ];
  };

in
{
  environment.systemPackages = [
    scx-env
    scx-switch
    scx-gui
    scx-desktop-item
    pkgs.qt6.qtwayland
    pkgs.adwaita-qt6
    pkgs.nixos-icons
  ];

  services.scx.enable = false;

  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
      if (action.id == "org.freedesktop.policykit.exec" &&
          action.lookup("command_line") &&
          action.lookup("command_line").indexOf("${scx-switch}/bin/scx-switch") === 0 &&
          subject.isInGroup("wheel")) {
        return polkit.Result.YES;
      }
    });
  '';

  programs.gamemode = {
    enable = true;
    settings = {
      custom = {
        # Using /run/wrappers/bin/pkexec to fix the "attribute missing" error
        start = "/run/wrappers/bin/pkexec ${scx-switch}/bin/scx-switch apply scx_lavd --performance";
        end = "/run/wrappers/bin/pkexec ${scx-switch}/bin/scx-switch disable";
      };
    };
  };
}
