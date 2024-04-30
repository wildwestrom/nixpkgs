# GNOME Sushi daemon.

{ config, lib, pkgs, ... }:

with lib;

{

  meta = {
    maintainers = teams.gnome.members;
  };

  ###### interface

  options = {

    services.gnome.sushi = {

      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to enable Sushi, a quick previewer for nautilus.
        '';
      };

    };

  };


  ###### implementation

  config = mkIf config.services.gnome.sushi.enable {

    environment.systemPackages = [ pkgs.gnome.sushi ];

    services.dbus.packages = [ pkgs.gnome.sushi ];

  };

}
