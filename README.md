# ADS-B Tracker

A self-hosted ADS-B flight tracker using an RTL-SDR dongle, dump1090, and a live web map.

## Features

- Live aircraft map with Leaflet
- Aircraft photos via Planespotters.net
- Route lookup (origin/destination) via adsbdb.com
- Altitude-coloured plane icons
- Range rings at 50/100/150/200nm
- FlightAware feeding via piaware

## Hardware

- Any RTL2838-based DVB-T USB dongle (e.g. RTL2838UHIDIR)
- A decent antenna helps — even a quarter-wave ground plane makes a big difference

## Supported Systems

| OS | Init system | Tested |
|----|-------------|--------|
| Pop!_OS / Ubuntu / Debian | systemd | ✓ |
| Alpine Linux 3.24+ | OpenRC | ✓ |
| PiOS, Debian Trixie  | systemd | ✓ |

## Installation

```sh
git clone https://github.com/benpietras/adsb-tracker-alpine-or-debian.git
cd adsb-tracker-alpine-or-debian
chmod +x install.sh

# Basic install
./install.sh

# With FlightAware feeding
./install.sh --fa-user YOUR_FLIGHTAWARE_USERNAME

# Skip piaware
./install.sh --skip-piaware
```

## Usage

Once installed, open your browser at:

```
http://localhost:8888/tracker.html
```

Or, from another computer on the same network:

```
http://ip-of-the-adsb-machine:8888/tracker.html
```

## Services

### Debian/Ubuntu
```sh
sudo systemctl status dump1090-mutability
sudo systemctl status dump1090-json-server
sudo systemctl status piaware
```

### Alpine
```sh
doas rc-service dump1090 status
doas rc-service dump1090-json-server status
doas rc-service piaware status
```

## FlightAware

piaware authenticates automatically and registers a feeder ID. Link it to your account at:

https://flightaware.com/adsb/piaware/claim

Or check your stats at:

https://flightaware.com/adsb/stats

## File layout

```
adsb-tracker/
├── install.sh                        # Main installer
├── scripts/
│   └── dump1090-json-server.py       # Python CORS server
└── tracker/
    └── tracker.html                  # Web map
```

## Notes

- The RTL-SDR dongle must be plugged in for dump1090 to start. Services will retry automatically when plugged in.
- `/run/dump1090` (Alpine) and `/run/dump1090-mutability` (Debian) are tmpfs — cleared on reboot. The installer handles copying tracker.html on each boot.
- Route data covers most commercial flights. Military/private flights may show no route.
