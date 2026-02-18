# Getting Started with Galactica Linux

Galactica is a minimal Linux distribution built around three core components:
- **AirRide** — init system (PID 1) and service manager
- **Dreamland** — package manager (Arch binaries + source packages)
- **Poyo** — getty/login

Default credentials: `root` / `galactica`

---

## Table of Contents

1. [First Boot](#first-boot)
2. [User Management](#user-management)
3. [Package Management (Dreamland)](#package-management-dreamland)
4. [Service Management (AirRide)](#service-management-airride)
5. [Writing Services](#writing-services)
6. [Networking](#networking)
7. [Installing a Desktop Environment](#installing-a-desktop-environment)
8. [Directory Structure](#directory-structure)

---

## First Boot

On first boot, AirRide starts the following automatically:

- Sets hostname (`galactica`)
- Fixes input device permissions
- Configures networking via DHCP
- Starts network watchdog
- Spawns login prompts on `tty1` and `ttyS0`

Run the bootstrap wizard to do initial setup:

```sh
/bootstrap.sh
```

This walks you through hostname, timezone, user creation, and initial package sync.

---

## User Management

### Create a user

```sh
makeuser
```

Or pass a username directly:

```sh
makeuser alice
```

This creates the user, sets a password, adds them to the standard groups (`wheel`, `video`, `audio`, `input`, `tty`), creates a home directory, and configures sudo access.

### Manual password change

```sh
# Change root password
passwd root

# Change another user's password (as root)
passwd alice
```

### Groups

| Group   | Purpose                        |
|---------|--------------------------------|
| `wheel` | sudo access                    |
| `video` | GPU / framebuffer access       |
| `audio` | Sound devices                  |
| `input` | Keyboard / mouse (needed for X11) |
| `tty`   | Terminal devices               |

---

## Package Management (Dreamland)

Dreamland can install both pre-built Arch Linux binaries and Galactica source packages.

### Sync the package database

Always sync first before installing anything:

```sh
dreamland sync
```

Or using the short alias:

```sh
dl sync
```

### Search for packages

```sh
dl search firefox
dl search text editor
```

### Install a package

```sh
dl install vim
dl install firefox
dl install xorg-server
```

Dreamland resolves and installs dependencies automatically. It will show you the full install plan and ask for confirmation before proceeding.

### List installed packages

```sh
dl list
```

### Uninstall a package

```sh
dl uninstall vim
```

### Package sources

Dreamland pulls from two sources:

- **Galactica Repository** — source-based packages at `github.com/LinkNavi/GalacticaRepository`. These are built from source on your machine.
- **Arch Linux** — pre-built binaries from the `core` and `extra` repos. These install instantly without compilation.

Arch binary packages take priority when both are available.

---

## Service Management (AirRide)

### List all services

```sh
airridectl list
```

### Start / stop / restart a service

```sh
airridectl start sshd
airridectl stop sshd
airridectl restart sshd
```

### Check service status

```sh
airridectl status network
```

### Services that start automatically on boot

Any service with `autostart = true` in its definition starts at boot. To see which ones are running:

```sh
airridectl list
```

Services marked `[auto]` in the list were configured to autostart.

---

## Writing Services

Service files live in `/etc/airride/services/` and use a simple INI format with a `.service` extension.

### Minimal service

```ini
[Service]
name = myapp
description = My Application
exec_start = /usr/bin/myapp

[Dependencies]
```

### Full example — a background daemon

```ini
[Service]
name = myapp
description = My Application Daemon
type = simple
exec_start = /usr/bin/myapp --config /etc/myapp/config.toml
autostart = true
parallel = true
restart = on-failure
restart_delay = 5

[Dependencies]
after = network
```

### Full example — a one-shot setup script

```ini
[Service]
name = myapp-setup
description = Initialize myapp data directory
type = oneshot
exec_start = /usr/bin/myapp-init
autostart = true

[Dependencies]
after = network
```

### Full example — a login prompt on a TTY

```ini
[Service]
name = tty2
description = Virtual Console 2 Login
type = simple
exec_start = /sbin/poyo /dev/tty2
tty = /dev/tty2
autostart = true
restart = always
restart_delay = 2

[Dependencies]
after = network
```

### Service fields reference

| Field | Values | Description |
|-------|--------|-------------|
| `name` | string | Unique service name |
| `description` | string | Human-readable description |
| `type` | `simple`, `forking`, `oneshot` | How AirRide tracks the process |
| `exec_start` | path + args | Command to run |
| `exec_stop` | path + args | Optional stop command |
| `tty` | `/dev/ttyN` | Attach service to a specific TTY |
| `autostart` | `true` / `false` | Start on boot |
| `parallel` | `true` / `false` | Start without waiting for prior services |
| `restart` | `on-failure`, `always` | Auto-restart policy |
| `restart_delay` | integer (seconds) | Wait before restarting |
| `foreground` | `true` / `false` | Attach to console instead of logging to file |

### Dependency fields (under `[Dependencies]`)

| Field | Description |
|-------|-------------|
| `requires` | Services that must start successfully before this one |
| `after` | Services that must be started (not necessarily successful) before this one |

Multiple dependencies are space-separated:

```ini
[Dependencies]
requires = network
after = network myapp-setup
```

### Service logs

Background services (without a `tty`) log to:

```
/var/log/airride/<name>.log
```

### Applying a new service

Just create the file — no reload needed. AirRide reads service files at startup. To start a new service without rebooting:

```sh
airridectl start myapp
```

---

## Networking

### Check current network status

```sh
ip addr
ip route
```

### Reconfigure networking

```sh
network-setup
```

This re-runs DHCP on the wired interface and reconnects WiFi if configured.

### Connect to WiFi

```sh
wifi-connect MyNetworkName MyPassword
```

For open networks:

```sh
wifi-connect MyOpenNetwork
```

WiFi credentials are saved to `/etc/wpa_supplicant/wpa_supplicant.conf` and reconnected automatically on boot if the file exists.

### Static IP

```sh
ip addr add 192.168.1.100/24 dev eth0
ip route add default via 192.168.1.1
echo "nameserver 8.8.8.8" > /etc/resolv.conf
```

To make it persistent, write a service:

```ini
[Service]
name = static-ip
description = Configure static IP
type = oneshot
exec_start = /sbin/static-ip-setup
autostart = true

[Dependencies]
after = hostname
```

---

## Installing a Desktop Environment

### 1. Sync packages

```sh
dl sync
```

### 2. Install X11 and a greeter

```sh
dl install xorg-server xorg-xinit
dl install ly          # or lightdm, greetd, etc.
```

### 3. Install a WM or DE

```sh
# Lightweight options
dl install i3
dl install openbox
dl install sway         # Wayland

# Full DEs
dl install xfce4
dl install kde-plasma
dl install gnome
```

### 4. Run the X11 setup helper

```sh
setup-xorg
```

This installs required packages, creates the X11 config, and sets up device permissions.

### 5. Create an AirRide service for the greeter

Example for `ly`:

```ini
[Service]
name = ly
description = Ly Display Manager
type = simple
exec_start = /usr/bin/ly
tty = /dev/tty1
autostart = true
restart = always
restart_delay = 2

[Dependencies]
after = network input-perms
```

Save to `/etc/airride/services/ly.service`, then:

```sh
airridectl start ly
```

From this point, the greeter handles launching X11 sessions — no manual `startgui` needed.

### Manual X11 start (no greeter)

```sh
startgui
```

This runs `startx` using `~/.xinitrc`. Edit `~/.xinitrc` to launch your WM:

```sh
#!/bin/sh
exec i3
```

---

## Directory Structure

| Path | Purpose |
|------|---------|
| `/etc/airride/services/` | Service definitions |
| `/var/log/airride/` | Service logs |
| `/etc/hostname` | System hostname |
| `/etc/hosts` | Host resolution |
| `/etc/resolv.conf` | DNS configuration |
| `/etc/wpa_supplicant/wpa_supplicant.conf` | WiFi credentials |
| `/etc/X11/xorg.conf` | X11 configuration |
| `/etc/shadow` | Password hashes (root-only) |
| `/etc/passwd` | User accounts |
| `/etc/group` | Group definitions |
| `/etc/sudoers` | Sudo rules |
| `/home/<user>/` | User home directories |
| `/usr/bin/dreamland` | Package manager binary |
| `/sbin/airride` | Init system binary |
| `/sbin/poyo` | Login/getty binary |
| `/usr/share/dreamland/` | Dreamland cache and state |
