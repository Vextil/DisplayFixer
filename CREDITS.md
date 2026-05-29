# Credits

DisplayFixer's adapter-reset step stands on prior reverse-engineering work, with thanks:

## VMM7100 reset

- **djrobx — [USBResetter](https://github.com/djrobx/USBResetter)**
  Reverse-engineered the Synaptics VMM7100 "Reset board" command by capturing the USB traffic
  from Synaptics' Windows **VMMHIDTool**. No explicit license is attached to that repository;
  the reset is a functional hardware command (HID `SET_REPORT` byte sequences), reproduced here
  with attribution.

- **waydabber (István Tóth) — [vmm7100reset](https://github.com/waydabber/vmm7100reset)** — MIT
  A Swift port of the above, shipped inside BetterDisplay. The three HID packets and the USB
  control-transfer parameters DisplayFixer uses are taken from this work. See that repository
  for its MIT license.

## Apple Silicon display techniques

- **[m1ddc](https://github.com/waydabber/m1ddc)** and
  **[MonitorControl](https://github.com/MonitorControl/MonitorControl)** — established the
  patterns for reaching the DCP `IOAVService` / `DCPAVServiceProxy` on Apple Silicon without root.

## Protocol origin

- **Synaptics VMMHIDTool** — the Windows utility whose "Reset board" function the reset sequence
  was originally derived from.

## Original work

DisplayFixer's own code is original and MIT-licensed: the Objective-C implementation, the
**device-level** reset path (which works on macOS 26 where the interface-level open fails), the
DSC/degraded detection via `SLSDisplaySupportsHDRMode`, the HDR-toggle color-set step, and the
menu-bar app.
