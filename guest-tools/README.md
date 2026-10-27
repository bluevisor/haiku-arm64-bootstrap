# Haiku guest tools for UTM (arm64)

Clipboard sharing and resize-to-window for the Haiku arm64 VM in UTM (QEMU
backend, SPICE display), the way spice-vdagent does it for Linux guests.

| Piece | What it does |
|---|---|
| `virtio_console/virtio_console.cpp` | New kernel driver: virtio-serial (multiport console). Publishes each host port as `/dev/ports/virtio/<name>` and `/dev/ports/virtio/vport<n>`. |
| `virtio_console/virtio_console_attach.cpp` | Small legacy driver, `/dev/misc/virtio_console_attach`. Opening it attaches virtio_pci to the console PCI function (see "Why the attach driver"). |
| `../patches/haiku-hrev60295/0015-virtio_gpu-report-host-display-changes.patch` | virtio_gpu: handles the display-change config interrupt and adds `VIRTIO_GPU_3D_WAIT_DISPLAY` on `/dev/misc/virtio_gpu/<n>`. Applies on top of 0009. |
| `vdagent/` | `vdagent` daemon: SPICE agent protocol on `com.redhat.spice.0`. Text (UTF-8) and images (PNG ↔ `image/bitmap`) go both ways. It waits on the GPU ioctl and calls `BScreen::SetMode` to follow the window size. |

## UTM settings

- **Sharing → Clipboard Sharing: on.** This adds the `com.redhat.spice.0` port.
- **Display → Resize display to window size automatically: on.**
- **QEMU → Arguments:** `-global virtio-serial-pci.disable-legacy=on -spice agent-mouse=off`
  - `disable-legacy`: the default transitional device (PCI ID 0x1003) goes through the legacy I/O BAR, which reads as zeros on Haiku arm64 (no features, so no multiport). Modern-only (0x1043) works.
  - `agent-mouse=off`: once an agent is connected, spice-server otherwise sends client-mode mouse positions to the agent instead of the usb-tablet. Haiku has no agent mouse injection, so the pointer would only work in capture mode.

UTM caches VM configs in memory, so a `plutil` edit of `config.plist` only takes effect after UTM restarts. To change settings live (VM stopped), use AppleScript: `configuration of vm` → `qemu additional arguments` → `update configuration`. AppleScript can't set clipboard sharing.

## Build and install

```sh
guest-tools/build.sh [ssh-host]   # default haiku-dbg; then reboot the guest
```

Builds natively on the guest with its gcc. `kbuild.sh` compiles kernel add-ons against the Haiku private headers at the VM's hrev.

Install locations:

- `/boot/system/non-packaged/add-ons/kernel/drivers/ports/virtio_console`
- `~/config/non-packaged/add-ons/kernel/drivers/{bin,dev/misc}/virtio_console_attach`
- `~/config/non-packaged/add-ons/kernel/drivers/graphics/virtio_gpu`
- `~/config/non-packaged/bin/vdagent`, started from `UserBootscript`

Logs go to syslog (`grep vdagent /var/log/syslog`). Run `vdagent -v` for per-message tracing.

## How the resize works

The `MONITORS_CONFIG` message never reaches the agent. QEMU's virtio-gpu says it supports client monitor configs, so spice-server hands the window size to QEMU. QEMU turns it into `VIRTIO_GPU_EVENT_DISPLAY`. The agent still has to announce `VD_AGENT_CAP_MONITORS_CONFIG`, or the client sends no size at all. The patched virtio_gpu releases a semaphore on the config interrupt. `vdagent` blocks in `VIRTIO_GPU_3D_WAIT_DISPLAY`, waits 250 ms for a window drag to settle, and sets the mode. app_server accepts any mode ≥ 320×200, and the driver's framebuffer fits up to 3840×2160.

## Why the attach driver

The virtio device node has no `B_FIND_CHILD_ON_DEMAND`. Its PCI parent does, and `device_node::Probe()` only matches on-demand PCI devices for a fixed set of classes (disk, net, graphics, audio, video, input, power). A virtio console is class 7 (simple communications), so virtio_pci is never attached to it. The real fix is a kernel patch (match `ports` to `PCI_simple_communications` in `Probe()` and `_GetNextDriverPath()`). Until then, `virtio_console_attach` calls `virtio_pci`'s `register_device()` on the PCI node. That runs the normal chain: virtio bus → virtio device → `virtio_console`.

## Gotchas

- Link kernel add-ons with `-z max-page-size=0x1000`. With ld's arm64 default (64 KiB) the kernel loader says "Bad data".
- Don't use `-mgeneral-regs-only`: `supports_device()` returns a float.
- The device manager calls `uninit_driver` right after registration unless the node has `B_KEEP_DRIVER_LOADED`. Hardware state set up in `register_child_devices` would otherwise be torn down.
- Only 8 virtqueues per virtio device (`VIRTIO_VIRTQUEUES_MAX_COUNT`), so serial ports 0–2 only. UTM puts the guest agent on port 1 and vdagent on port 2.
