{ config, lib, pkgs, ... }:

with lib;

let

  udev = config.systemd.package;

  cfg = config.services.udev;

  extraUdevRules = pkgs.writeTextFile {
    name = "extra-udev-rules";
    text = cfg.extraRules;
    destination = "/etc/udev/rules.d/99-local.rules";
  };

  extraHwdbFile = pkgs.writeTextFile {
    name = "extra-hwdb-file";
    text = cfg.extraHwdb;
    destination = "/etc/udev/hwdb.d/99-local.hwdb";
  };

  nixosRules = ''
    # Miscellaneous devices.
    KERNEL=="kvm",                  MODE="0666"
    KERNEL=="kqemu",                MODE="0666"

    # Needed for gpm.
    SUBSYSTEM=="input", KERNEL=="mice", TAG+="systemd"
  '';

  # Perform substitutions in all udev rules files.
  udevRulesFor = { name, udevPackages, udevPath, udev, systemd, binPackages, initrdBin ? null }: pkgs.runCommand name
    { preferLocalBuild = true;
      allowSubstitutes = false;
      packages = unique (map toString udevPackages);
    }
    ''
      mkdir -p $out
      shopt -s nullglob
      set +o pipefail

      # Set a reasonable $PATH for programs called by udev rules.
      echo 'ENV{PATH}="${udevPath}/bin:${udevPath}/sbin"' > $out/00-path.rules

      # Add the udev rules from other packages.
      for i in $packages; do
        echo "Adding rules for package $i"
        for j in $i/{etc,lib}/udev/rules.d/*; do
          echo "Copying $j to $out/$(basename $j)"
          cat $j > $out/$(basename $j)
        done
      done

      # Fix some paths in the standard udev rules.  Hacky.
      for i in $out/*.rules; do
        substituteInPlace $i \
          --replace \"/sbin/modprobe \"${pkgs.kmod}/bin/modprobe \
          --replace \"/sbin/mdadm \"${pkgs.mdadm}/sbin/mdadm \
          --replace \"/sbin/blkid \"${pkgs.util-linux}/sbin/blkid \
          --replace \"/bin/mount \"${pkgs.util-linux}/bin/mount \
          --replace /usr/bin/readlink ${pkgs.coreutils}/bin/readlink \
          --replace /usr/bin/basename ${pkgs.coreutils}/bin/basename
      ${optionalString (initrdBin != null) ''
        substituteInPlace $i --replace '/run/current-system/systemd' "${removeSuffix "/bin" initrdBin}"
      ''}
      done

      echo -n "Checking that all programs called by relative paths in udev rules exist in ${udev}/lib/udev... "
      import_progs=$(grep 'IMPORT{program}="[^/$]' $out/* |
        sed -e 's/.*IMPORT{program}="\([^ "]*\)[ "].*/\1/' | uniq)
      run_progs=$(grep -v '^[[:space:]]*#' $out/* | grep 'RUN+="[^/$]' |
        sed -e 's/.*RUN+="\([^ "]*\)[ "].*/\1/' | uniq)
      for i in $import_progs $run_progs; do
        if [[ ! -x ${udev}/lib/udev/$i && ! $i =~ socket:.* ]]; then
          echo "FAIL"
          echo "$i is called in udev rules but not installed by udev"
          exit 1
        fi
      done
      echo "OK"

      echo -n "Checking that all programs called by absolute paths in udev rules exist... "
      import_progs=$(grep 'IMPORT{program}="\/' $out/* |
        sed -e 's/.*IMPORT{program}="\([^ "]*\)[ "].*/\1/' | uniq)
      run_progs=$(grep -v '^[[:space:]]*#' $out/* | grep 'RUN+="/' |
        sed -e 's/.*RUN+="\([^ "]*\)[ "].*/\1/' | uniq)
      for i in $import_progs $run_progs; do
        # if the path refers to /run/current-system/systemd, replace with config.systemd.package
        if [[ $i == /run/current-system/systemd* ]]; then
          i="${systemd}/''${i#/run/current-system/systemd/}"
        fi

        if [[ ! -x $i ]]; then
          echo "FAIL"
          echo "$i is called in udev rules but is not executable or does not exist"
          exit 1
        fi
      done
      echo "OK"

      filesToFixup="$(for i in "$out"/*; do
        grep -l '\B\(/usr\)\?/s\?bin' "$i" || :
      done)"

      if [ -n "$filesToFixup" ]; then
        echo "Consider fixing the following udev rules:"
        echo "$filesToFixup" | while read localFile; do
          remoteFile="origin unknown"
          for i in ${toString binPackages}; do
            for j in "$i"/*/udev/rules.d/*; do
              [ -e "$out/$(basename "$j")" ] || continue
              [ "$(basename "$j")" = "$(basename "$localFile")" ] || continue
              remoteFile="originally from $j"
              break 2
            done
          done
          refs="$(
            grep -o '\B\(/usr\)\?/s\?bin/[^ "]\+' "$localFile" \
              | sed -e ':r;N;''${s/\n/ and /;br};s/\n/, /g;br'
          )"
          echo "$localFile ($remoteFile) contains references to $refs."
        done
        exit 1
      fi

      # If auto-configuration is disabled, then remove
      # udev's 80-drivers.rules file, which contains rules for
      # automatically calling modprobe.
      ${optionalString (!config.boot.hardwareScan) ''
        ln -s /dev/null $out/80-drivers.rules
      ''}
    '';

  hwdbBin = pkgs.runCommand "hwdb.bin"
    { preferLocalBuild = true;
      allowSubstitutes = false;
      packages = unique (map toString ([udev] ++ cfg.packages));
    }
    ''
      mkdir -p etc/udev/hwdb.d
      for i in $packages; do
        echo "Adding hwdb files for package $i"
        for j in $i/{etc,lib}/udev/hwdb.d/*; do
          ln -s $j etc/udev/hwdb.d/$(basename $j)
        done
      done

      echo "Generating hwdb database..."
      # hwdb --update doesn't return error code even on errors!
      res="$(${pkgs.buildPackages.udev}/bin/udevadm hwdb --update --root=$(pwd) 2>&1)"
      echo "$res"
      [ -z "$(echo "$res" | egrep '^Error')" ]
      mv etc/udev/hwdb.bin $out
    '';

  # Udev has a 512-character limit for ENV{PATH}, so create a symlink
  # tree to work around this.
  udevPath = pkgs.buildEnv {
    name = "udev-path";
    paths = cfg.path;
    pathsToLink = [ "/bin" "/sbin" ];
    ignoreCollisions = true;
  };

in

{

  ###### interface

  options = {

    boot.hardwareScan = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether to try to load kernel modules for all detected hardware.
        Usually this does a good job of providing you with the modules
        you need, but sometimes it can crash the system or cause other
        nasty effects.
      '';
    };

    services.udev = {

      packages = mkOption {
        type = types.listOf types.path;
        default = [];
        description = ''
          List of packages containing <command>udev</command> rules.
          All files found in
          <filename><replaceable>pkg</replaceable>/etc/udev/rules.d</filename> and
          <filename><replaceable>pkg</replaceable>/lib/udev/rules.d</filename>
          will be included.
        '';
        apply = map getBin;
      };

      path = mkOption {
        type = types.listOf types.path;
        default = [];
        description = ''
          Packages added to the <envar>PATH</envar> environment variable when
          executing programs from Udev rules.
        '';
      };

      extraRules = mkOption {
        default = "";
        example = ''
          ENV{ID_VENDOR_ID}=="046d", ENV{ID_MODEL_ID}=="0825", ENV{PULSE_IGNORE}="1"
        '';
        type = types.lines;
        description = ''
          Additional <command>udev</command> rules. They'll be written
          into file <filename>99-local.rules</filename>. Thus they are
          read and applied after all other rules.
        '';
      };

      extraHwdb = mkOption {
        default = "";
        example = ''
          evdev:input:b0003v05AFp8277*
            KEYBOARD_KEY_70039=leftalt
            KEYBOARD_KEY_700e2=leftctrl
        '';
        type = types.lines;
        description = ''
          Additional <command>hwdb</command> files. They'll be written
          into file <filename>99-local.hwdb</filename>. Thus they are
          read after all other files.
        '';
      };

    };

    hardware.firmware = mkOption {
      type = types.listOf types.package;
      default = [];
      description = ''
        List of packages containing firmware files.  Such files
        will be loaded automatically if the kernel asks for them
        (i.e., when it has detected specific hardware that requires
        firmware to function).  If multiple packages contain firmware
        files with the same name, the first package in the list takes
        precedence.  Note that you must rebuild your system if you add
        files to any of these directories.
      '';
      apply = list: pkgs.buildEnv {
        name = "firmware";
        paths = list;
        pathsToLink = [ "/lib/firmware" ];
        ignoreCollisions = true;
      };
    };

    networking.usePredictableInterfaceNames = mkOption {
      default = true;
      type = types.bool;
      description = ''
        Whether to assign <link
        xlink:href='http://www.freedesktop.org/wiki/Software/systemd/PredictableNetworkInterfaceNames'>predictable
        names to network interfaces</link>.  If enabled, interfaces
        are assigned names that contain topology information
        (e.g. <literal>wlp3s0</literal>) and thus should be stable
        across reboots.  If disabled, names depend on the order in
        which interfaces are discovered by the kernel, which may
        change randomly across reboots; for instance, you may find
        <literal>eth0</literal> and <literal>eth1</literal> flipping
        unpredictably.
      '';
    };

    boot.initrd.services.udev = {

      packages = mkOption {
        type = types.listOf types.path;
        default = [];
        visible = false;
        description = ''
          <emphasis>This will only be used when systemd is used in stage 1.</emphasis>

          List of packages containing <command>udev</command> rules that will be copied to stage 1.
          All files found in
          <filename><replaceable>pkg</replaceable>/etc/udev/rules.d</filename> and
          <filename><replaceable>pkg</replaceable>/lib/udev/rules.d</filename>
          will be included.
        '';
      };

      binPackages = mkOption {
        type = types.listOf types.path;
        default = [];
        visible = false;
        description = ''
          <emphasis>This will only be used when systemd is used in stage 1.</emphasis>

          Packages to search for binaries that are referenced by the udev rules in stage 1.
          This list always contains /bin of the initrd.
        '';
        apply = map getBin;
      };

      rules = mkOption {
        default = "";
        example = ''
          SUBSYSTEM=="net", ACTION=="add", DRIVERS=="?*", ATTR{address}=="00:1D:60:B9:6D:4F", KERNEL=="eth*", NAME="my_fast_network_card"
        '';
        type = types.lines;
        description = ''
          <command>udev</command> rules to include in the initrd
          <emphasis>only</emphasis>. They'll be written into file
          <filename>99-local.rules</filename>. Thus they are read and applied
          after the essential initrd rules.
        '';
      };

    };

  };


  ###### implementation

  config = mkIf (!config.boot.isContainer) {

    services.udev.extraRules = nixosRules;

    services.udev.packages = [ extraUdevRules extraHwdbFile ];

    services.udev.path = [ pkgs.coreutils pkgs.gnused pkgs.gnugrep pkgs.util-linux udev ];

    boot.kernelParams = mkIf (!config.networking.usePredictableInterfaceNames) [ "net.ifnames=0" ];

    boot.initrd.extraUdevRulesCommands = optionalString (!config.boot.initrd.systemd.enable && config.boot.initrd.services.udev.rules != "")
      ''
        cat <<'EOF' > $out/99-local.rules
        ${config.boot.initrd.services.udev.rules}
        EOF
      '';

    boot.initrd.systemd.additionalUpstreamUnits = [
      # TODO: "initrd-udevadm-cleanup-db.service" is commented out because of https://github.com/systemd/systemd/issues/12953
      "systemd-udevd-control.socket"
      "systemd-udevd-kernel.socket"
      "systemd-udevd.service"
      "systemd-udev-settle.service"
      "systemd-udev-trigger.service"
    ];
    boot.initrd.systemd.storePaths = [
      "${config.boot.initrd.systemd.package}/lib/systemd/systemd-udevd"
      "${config.boot.initrd.systemd.package}/lib/udev"
    ] ++ map (x: "${x}/bin") config.boot.initrd.services.udev.binPackages;

    # Generate the udev rules for the initrd
    boot.initrd.systemd.contents = {
      "/etc/udev/rules.d".source = udevRulesFor {
        name = "initrd-udev-rules";
        initrdBin = config.boot.initrd.systemd.contents."/bin".source;
        udevPackages = config.boot.initrd.services.udev.packages;
        udevPath = config.boot.initrd.systemd.contents."/bin".source;
        udev = config.boot.initrd.systemd.package;
        systemd = config.boot.initrd.systemd.package;
        binPackages = config.boot.initrd.services.udev.binPackages ++ [ config.boot.initrd.systemd.contents."/bin".source ];
      };
    };
    # Insert custom rules
    boot.initrd.services.udev.packages = mkIf (config.boot.initrd.services.udev.rules != "") (pkgs.writeTextFile {
      name = "initrd-udev-rules";
      destination = "/etc/udev/rules.d/99-local.rules";
      text = config.boot.initrd.services.udev.rules;
    });

    environment.etc =
      {
        "udev/rules.d".source = udevRulesFor {
          name = "udev-rules";
          udevPackages = cfg.packages;
          systemd = config.systemd.package;
          binPackages = cfg.packages;
          inherit udevPath udev;
        };
        "udev/hwdb.bin".source = hwdbBin;
      };

    system.requiredKernelConfig = with config.lib.kernelConfig; [
      (isEnabled "UNIX")
      (isYes "INOTIFY_USER")
      (isYes "NET")
    ];

    # We don't place this into `extraModprobeConfig` so that stage-1 ramdisk doesn't bloat.
    environment.etc."modprobe.d/firmware.conf".text = "options firmware_class path=${config.hardware.firmware}/lib/firmware";

    system.activationScripts.udevd =
      ''
        # The deprecated hotplug uevent helper is not used anymore
        if [ -e /proc/sys/kernel/hotplug ]; then
          echo "" > /proc/sys/kernel/hotplug
        fi

        # Allow the kernel to find our firmware.
        if [ -e /sys/module/firmware_class/parameters/path ]; then
          echo -n "${config.hardware.firmware}/lib/firmware" > /sys/module/firmware_class/parameters/path
        fi
      '';

    systemd.services.systemd-udevd =
      { restartTriggers = cfg.packages;
      };

  };

  imports = [
    (mkRenamedOptionModule [ "services" "udev" "initrdRules" ] [ "boot" "initrd" "services" "udev" "rules" ])
  ];
}
