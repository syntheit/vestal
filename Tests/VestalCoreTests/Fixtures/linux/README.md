# Linux captures

Real `/proc` and `/sys` contents from two NixOS machines, for `LinuxStatsTests`:

- `harbor-*.txt`: an Intel server (coretemp, three NVMe drives, ZFS pools, mergerfs, zram, Docker with ~70 veths and bridges, libvirt, WireGuard, Tailscale). Kernel 6.18.
- `mantle-*.txt`: an AMD desktop (k10temp, btrfs on LUKS, zram, a Logitech mouse's battery, WireGuard, Tailscale).

Each `<host>-1.txt` is every file `LinuxSystemStats` reads, as a `== <path>` line followed by the file's contents. `<host>-2.txt` has `/proc/stat`, `/proc/net/dev` and `/proc/uptime` again, about two seconds later, for the CPU and network rates. The mouse's serial number is zeroed; nothing else was edited.

Captured with this read-only script (`ssh <host> bash -s < capture.sh > <host>-1.txt`); the second file uses only the first three paths:

```sh
dump() { for f in "$@"; do [ -r "$f" ] || continue; echo "== $f"; cat "$f"; done; }
dump /proc/stat /proc/meminfo /proc/net/dev /proc/uptime /proc/self/mounts \
  /sys/class/hwmon/hwmon*/name /sys/class/hwmon/hwmon*/temp*_label /sys/class/hwmon/hwmon*/temp*_input \
  /sys/class/thermal/thermal_zone*/type /sys/class/thermal/thermal_zone*/temp \
  /sys/class/power_supply/*/uevent /sys/devices/virtual/net/*/type /sys/block/zram*/mm_stat
```

`<host>-3.txt` (v0.4, for the `system` source) was captured later the same way with this list, so it pairs with `-1` for a long-interval interface rate. Neither `-1` file has `/proc/pressure/memory` or `/proc/loadavg`, so on their own they stand for a kernel without PSI:

```sh
dump /proc/loadavg /proc/pressure/memory /proc/net/dev /proc/uptime /sys/devices/virtual/net/*/type
```

Neither machine has a laptop battery, and neither runs PipeWire or an MPRIS player where it could be captured, so the tests write those inputs (a `BAT0` uevent, `wpctl` and `playerctl` output) from the kernel's and the tools' documented formats.
