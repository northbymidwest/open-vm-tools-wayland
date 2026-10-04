# SPDX-License-Identifier: 0BSD
# Copyright (C) 2026 Michael Bryniarski
#
# The packaging in this repository is 0BSD. The patches in
# patches/ change open-vm-tools and are LGPL-2.1, like the code they change.
{
  description = "Native Wayland drag and drop and copy/paste for open-vm-tools";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # The patches in patches/, applied in name order. They are made against
      # open-vm-tools' stable-13.1.0 tag, relative to its open-vm-tools/
      # directory, which is where nixpkgs' package applies its patches.
      patches = map (name: ./patches + "/${name}") (
        builtins.sort builtins.lessThan (
          builtins.filter (nixpkgs.lib.hasSuffix ".patch") (
            builtins.attrNames (builtins.readDir ./patches)
          )
        )
      );

      # The caller's nixpkgs open-vm-tools with the patches and the Wayland
      # backends enabled, so it matches the rest of their system.
      mkOpenVmTools =
        pkgs:
        pkgs.open-vm-tools.overrideAttrs (old: {
          # Marks the patched build; the source is still nixpkgs'.
          version = "${old.version}-wayland";
          __intentionallyOverridingVersion = true;
          patches = (old.patches or [ ]) ++ patches;
          nativeBuildInputs = old.nativeBuildInputs ++ [ pkgs.wayland-scanner ];
          buildInputs = old.buildInputs ++ [ pkgs.wayland ];
          configureFlags = old.configureFlags ++ [ "--with-wayland" ];
        });
    in
    {
      packages = forAllSystems (pkgs: rec {
        open-vm-tools = mkOpenVmTools pkgs;
        default = open-vm-tools;
      });

      overlays.default = final: prev: { open-vm-tools = mkOpenVmTools prev; };

      # Use together with virtualisation.vmware.guest.enable = true. Everything
      # here is a default, so it can still be overridden.
      nixosModules.default =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        {
          config = lib.mkIf config.virtualisation.vmware.guest.enable {
            virtualisation.vmware.guest = {
              package = lib.mkDefault (mkOpenVmTools pkgs);
              # headless defaults to !services.xserver.enable, which is false
              # on Wayland-only desktops; drag and drop and copy/paste need the
              # non-headless parts (vmblock-fuse, vmware-user-suid-wrapper).
              headless = lib.mkDefault false;
            };

            # NixOS only starts vmware-user from X11 session commands, which
            # Wayland sessions don't run. XDG autostart works in Plasma, GNOME
            # and UWSM-managed compositors.
            environment.etc."xdg/autostart/vmware-user.desktop".text = lib.mkDefault ''
              [Desktop Entry]
              Type=Application
              Name=VMware User Agent
              Exec=/run/wrappers/bin/vmware-user-suid-wrapper
              NoDisplay=true
            '';
          };
        };
    };
}
