# Linux-Log-Monitor

A native KDE Plasma 6 widget that shows a **live, colour-coded view of the
systemd journal** — the single most complete log on a Linux box. The journal
already absorbs the kernel ring buffer (`dmesg`), every systemd unit's
stdout/stderr, and anything sent via syslog, so one stream covers essentially
every application on the system.

Built in the same style as
[Linux-Router-Monitor](https://github.com/DevL0rd/Linux-Router-Monitor): a light
resident collector keeps a ring buffer in tmpfs and the widget reads it
in-process (no process spawned per poll), so it matches the default Plasma applet
look and costs almost nothing.

## Features

- **Everything, live** — follows `journalctl -f` (kernel + all services + apps).
- **Colour-coded severity** — errors red, warnings amber, the rest neutral.
- **Severity filter** — All / Info / Warnings / Errors.
- **Live search** — instant text filter on message + application name.
- **Pause / follow** — freeze the stream to read; resume snaps back to the tail.
- **Click to copy** — click any line to copy it to the clipboard.

## How it works

```
journalctl -f -o json   ->   logmon-collect (--serve)   ->   $XDG_RUNTIME_DIR/Linux-Log-Monitor/log.json
        (systemd journal)        resident --user service              (tmpfs ring buffer)
                                                                              |
                                                                  widget reads via XHR (in-process)
```

- `bin/logmon-collect --serve` runs as a `systemd --user` service, follows the
  journal, keeps the last N records, and atomically mirrors them to a tmpfs JSON
  file. It's pinned to efficiency cores on hybrid CPUs and runs at `Nice=19`.
- The widget reads that file with `XMLHttpRequest` over `file://`, which Qt only
  permits when `QML_XHR_ALLOW_FILE_READ=1` is set for the session (the installer
  adds it to `~/.config/plasma-workspace/env`).

## Requirements

- KDE Plasma 6 / Qt 6
- `journalctl` (systemd), `python3`, `kpackagetool6`
- Journal read access: be in one of `systemd-journal`, `wheel`, or `adm`
  (systemd grants these groups full read via ACL). Add yourself if needed:
  `sudo usermod -aG systemd-journal $USER` then re-login.

## Install

Clone **with submodules** — the shared QML/JS components live in the
[Linux-Plasma-Shared](https://github.com/DevL0rd/Linux-Plasma-Shared) submodule:

```sh
git clone --recurse-submodules https://github.com/DevL0rd/Linux-Log-Monitor.git
cd Linux-Log-Monitor
# already cloned without it?  git submodule update --init --recursive
./install.sh
```

Then add it: right-click the desktop/panel → **Add Widgets** → search
**"System Log"**. If the widget is blank on first run, log out and back in once
so the `QML_XHR_ALLOW_FILE_READ` flag takes effect.

## Configuration

Right-click the widget → **Configure**:

| Option | Default | Notes |
| --- | --- | --- |
| Poll interval | 1.0 s | how often the widget re-reads the tmpfs file |
| Lines kept | 600 | display ring size |
| Default level | All | severity shown on start |
| Application column | on | show the emitting unit/app |
| Wrap long messages | off | wrap vs. elide |
| Accent colour | theme | colour of the app column |

The collector's ring size can be raised with the `LOGMON_MAX_LINES` environment
variable, and extra `journalctl` arguments can be passed via
`LOGMON_JOURNAL_ARGS` (both read by the service).

## Uninstall

```sh
./uninstall.sh
```

## License

MIT
