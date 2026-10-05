# open-vm-tools-wayland

Patches that give open-vm-tools' `vmware-user` native Wayland drag and drop
and copy/paste, with a Nix flake and NixOS module to use them.

Upstream open-vm-tools drags and copies through Xwayland on a Wayland
session, which depends on the compositor carrying drags and the clipboard
between X11 and Wayland clients. Some compositors don't do that for
`vmware-user`. Under KDE Plasma (KWin), for example, files dragged in from
the host never drop, and copying from the guest to the host does nothing.
VMware's own position is that drag and drop and copy/paste don't work on
Wayland.

With the patches, `vmware-user`'s `dndcp` plugin talks to the compositor
directly where the compositor supports it, and falls back to the existing
X11 code everywhere else.

## The patches

Applied in order to open-vm-tools' `stable-13.1.0` tag, relative to its
`open-vm-tools/` directory:

1. `0001-dndcp-add-Wayland-build-support-and-shared-helpers.patch`:
   `--with-wayland`, the Wayland protocol XML and generated code, and
   helpers both backends share. These include validation of the file names
   in the host's file lists, which are refused as a whole if any name is
   absolute, has an empty, `.` or `..` component, or contains control
   characters.
2. `0002-dndcp-add-native-Wayland-drag-and-drop.patch`: the native Wayland
   drag and drop backend.
3. `0003-dndcp-add-native-Wayland-copy-paste.patch`: the native Wayland
   copy/paste backend.

Each one builds on its own with the ones before it.

## What works

| Feature | Guest to host | Host to guest |
|---|---|---|
| Copy/paste: text, rich text, PNG images, files | yes | yes |
| Drag and drop of files | unreliable, see below | yes |

Tested with VMware Fusion on an Apple silicon Mac and a NixOS guest:

| Session | Drag and drop | Copy/paste |
|---|---|---|
| KDE Plasma 6 (KWin) | native Wayland | native Wayland (`ext-data-control`) |
| Sway (wlroots) | native Wayland | native Wayland (`ext-data-control`, and `wlr-data-control` on its own) |
| GNOME (Mutter) | X11 fallback | X11 fallback |

## Compositor requirements

Each feature picks its backend when `vmware-user` starts:

| Feature | Wayland protocols needed | Otherwise |
|---|---|---|
| Drag and drop | `zwlr_layer_shell_v1`, `wl_data_device_manager` version 3, `wp_viewporter` | X11 |
| Copy/paste | `ext_data_control_manager_v1` or `zwlr_data_control_manager_v1` | X11 |

Drag and drop also needs the uinput file descriptor that
`vmware-user-suid-wrapper` passes to `vmware-user`, and both want the
`vmblock-fuse` mount, as upstream does.

GNOME's Mutter offers neither layer-shell nor data control, so GNOME stays on
the X11 code, which works there because Mutter's Xwayland bridge handles it.

To see what a compositor offers, run `wayland-info` (from wayland-utils) in
the session:

```sh
wayland-info | grep -E 'layer_shell|data_device_manager|viewporter|data_control'
```

## Known limitation: dragging out of the guest

Dragging from the guest to the host is unreliable, with these patches and
with upstream's X11 code alike (including on GNOME). When the pointer leaves
the VM window, the host releases the guest's mouse button straight away, but
the host's "is a drag leaving?" message (`DND_CMD_QUERY_EXITING`) reaches
`vmware-user` through an RPC channel it polls, backing off to 100ms when idle.
The guest drag is usually dropped before `vmware-user` hears about it.
Copying and pasting files works in both directions instead.

## NixOS

Add this flake to your system flake and import its module next to NixOS's
own `virtualisation.vmware.guest`:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    open-vm-tools-wayland = {
      url = "github:northbymidwest/open-vm-tools-wayland";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { nixpkgs, open-vm-tools-wayland, ... }:
    {
      nixosConfigurations.my-vm = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux"; # or "x86_64-linux"
        modules = [
          ./configuration.nix
          open-vm-tools-wayland.nixosModules.default
          { virtualisation.vmware.guest.enable = true; }
        ];
      };
    };
}
```

Then rebuild, and log out and back in so `vmware-user` starts in the new
session:

```sh
sudo nixos-rebuild switch --flake .#my-vm
pgrep -af 'vmtoolsd -n vmusr'
# .../open-vm-tools-13.1.0-wayland/bin/vmtoolsd -n vmusr --blockFd 3 --uinputFd 4
```

The module, only when `virtualisation.vmware.guest.enable` is set:

- builds your nixpkgs' `open-vm-tools` with the patches, as
  `virtualisation.vmware.guest.package`;
- turns the desktop parts on (`headless = false`), which NixOS otherwise only
  does when `services.xserver` is enabled;
- starts `vmware-user` through the setuid wrapper from an XDG autostart entry,
  since NixOS otherwise only starts it from X11 session commands, which
  Wayland sessions don't run.

Each is a default, so you can still override any of them. If your
compositor only starts XDG autostart entries under UWSM (Hyprland, Sway),
pick its UWSM session.

The flake also has the package (`packages.<system>.default`) and an overlay
(`overlays.default`) replacing `open-vm-tools`, for setups that don't use
the module.

## Other distributions

Apply the patches in `patches/`, in order, to open-vm-tools'
`stable-13.1.0` tag from its `open-vm-tools/` directory, regenerate the
build system, and configure with `--with-wayland` (which needs
`wayland-client` and `wayland-scanner`):

```sh
git clone --branch stable-13.1.0 https://github.com/vmware/open-vm-tools.git
cd open-vm-tools/open-vm-tools
for p in /path/to/open-vm-tools-wayland/patches/*.patch; do patch -p1 < "$p"; done
autoreconf -i
./configure --with-wayland
make
```

Then make sure `vmware-user` is started inside the Wayland session through
`vmware-user-suid-wrapper`, for example from an XDG autostart entry.

## Overriding the backend

Set these in `vmware-user`'s environment to force a choice:

- `VMTOOLS_DND_BACKEND=x11` or `=wayland` for drag and drop
- `VMTOOLS_CP_BACKEND=x11` or `=wayland` for copy/paste

`wayland` still falls back to X11 if the compositor lacks a required
protocol. With debug logging for `vmusr` enabled in `tools.conf`, the log
says which backend was chosen (`native Wayland DnD`,
`native Wayland copy/paste`).

## Where the patches come from

The patches are commits on top of the `stable-13.1.0` tag in an
open-vm-tools checkout, exported with:

```sh
git format-patch --relative=open-vm-tools --no-signature stable-13.1.0..HEAD -o patches
```

Each patch's description is its commit message. The flake applies every
`.patch` file in `patches/`, in name order. The original development
history is on the `wayland-dnd` branch of
[northbymidwest/open-vm-tools](https://github.com/northbymidwest/open-vm-tools/tree/wayland-dnd),
now archived.

## Licensing

The packaging in this repository (the flake and the README) is 0BSD
(SPDX-License-Identifier: 0BSD). The patches change open-vm-tools and are
under the licences of the files they change: LGPL-2.1 for the `dndcp`
plugin's code, GPL-2.0 for its `Makefile.am`, and open-vm-tools' own licence
for `configure.ac`. The Wayland protocol XML files they add keep their own
MIT-style licences.

## Related

[Clipway](https://github.com/krisztianfekete/clipway) is a similar patch to
open-vm-tools' `dndcp` plugin: a Wayland clipboard backend that bridges
plain UTF-8 text through `wl-clipboard`, with a NixOS module and an AUR
package. It covers less (no rich text, images, files or drag and drop), but
had I known about it when starting this, I would probably have built on it.
