#!/bin/sh
# ADS-B Tracker Installer
# Supports: Debian/Ubuntu/Pop!_OS and Alpine Linux
# https://github.com/yourusername/adsb-tracker

set -e

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
TRACKER_HTML="$REPO_DIR/tracker/tracker.html"
JSON_SERVER_PY="$REPO_DIR/scripts/dump1090-json-server.py"
JSON_DIR="/run/dump1090"
SERVE_PORT=8888
FA_USER=""

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { printf "${GREEN}[+]${NC} %s\n" "$*"; }
warn()    { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
error()   { printf "${RED}[x]${NC} %s\n" "$*"; exit 1; }
section() { printf "\n${YELLOW}━━━ %s ━━━${NC}\n" "$*"; }

# ── Detect OS ────────────────────────────────────────────────────────────────
detect_os() {
    if [ -f /etc/alpine-release ]; then
        OS="alpine"
        SUDO="doas"
        PKG_INSTALL="apk add"
        PKG_UPDATE="apk update"
        INIT="openrc"
        SERVICE_START="rc-service"
        SERVICE_ENABLE="rc-update add"
        info "Detected Alpine Linux $(cat /etc/alpine-release)"
    elif [ -f /etc/debian_version ] || grep -qi debian /etc/os-release 2>/dev/null; then
        OS="debian"
        SUDO="sudo"
        PKG_INSTALL="apt-get install -y"
        PKG_UPDATE="apt-get update"
        INIT="systemd"
        SERVICE_START="systemctl start"
        SERVICE_ENABLE="systemctl enable"
        info "Detected Debian/Ubuntu based OS"
    else
        error "Unsupported OS. This installer supports Debian/Ubuntu and Alpine Linux."
    fi
    ARCH=$(uname -m)
    info "Architecture: $ARCH"
}

# ── Check for RTL-SDR dongle ─────────────────────────────────────────────────
check_dongle() {
    section "Checking for RTL-SDR dongle"
    if lsusb 2>/dev/null | grep -q "0bda:2838"; then
        info "RTL2838 dongle found"
    else
        warn "RTL2838 dongle not detected. Continuing anyway (may not be plugged in)."
    fi
}

# ── Blacklist DVB drivers ────────────────────────────────────────────────────
blacklist_dvb() {
    section "Blacklisting DVB kernel modules"
    $SUDO tee /etc/modprobe.d/rtl-sdr-blacklist.conf > /dev/null << 'EOF'
blacklist dvb_usb_rtl28xxu
blacklist rtl2832_sdr
blacklist rtl2832
blacklist dvb_usb_v2
EOF
    modprobe -r dvb_usb_rtl28xxu rtl2832_sdr rtl2832 dvb_usb_v2 2>/dev/null || true
    info "DVB modules blacklisted"
}

# ── Install packages ─────────────────────────────────────────────────────────
install_packages_debian() {
    section "Installing packages (Debian)"
    $SUDO $PKG_UPDATE
    $SUDO $PKG_INSTALL rtl-sdr dump1090-mutability python3 curl

    # Ensure dump1090 runs as current user and has HTTP port set
    USER_NAME=$(whoami)
    $SUDO sed -i "s/DUMP1090_USER=\"dump1090\"/DUMP1090_USER=\"$USER_NAME\"/" /etc/default/dump1090-mutability
    # Set JSON dir and extra args
    $SUDO sed -i 's|JSON_DIR=.*|JSON_DIR="/run/dump1090-mutability"|' /etc/default/dump1090-mutability
    $SUDO sed -i 's|EXTRA_ARGS=""|EXTRA_ARGS="--net-http-port 8889"|' /etc/default/dump1090-mutability 2>/dev/null || true
    # Set location
    $SUDO sed -i 's|LAT=""|LAT="53.4331"|' /etc/default/dump1090-mutability
    $SUDO sed -i 's|LON=""|LON="-2.1559"|' /etc/default/dump1090-mutability
    JSON_DIR="/run/dump1090-mutability"
}

install_packages_alpine() {
    section "Installing packages (Alpine)"
    $SUDO $PKG_UPDATE
    $SUDO $PKG_INSTALL rtl-sdr dump1090 python3 curl coreutils udev-init-scripts
}

# ── udev rules ───────────────────────────────────────────────────────────────
install_udev_rules() {
    section "Installing udev rules for RTL-SDR"
    $SUDO tee /etc/udev/rules.d/rtl-sdr.rules > /dev/null << 'EOF'
SUBSYSTEM=="usb", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="2838", GROUP="plugdev", MODE="0664", SYMLINK+="rtl_sdr"
EOF
    $SUDO udevadm control --reload-rules 2>/dev/null || true
    $SUDO udevadm trigger 2>/dev/null || true
    # Add current user to plugdev
    $SUDO usermod -aG plugdev "$(whoami)" 2>/dev/null || true
    info "udev rules installed"
}

# ── Python CORS server ───────────────────────────────────────────────────────
install_json_server() {
    section "Installing JSON CORS server"
    $SUDO cp "$JSON_SERVER_PY" /usr/local/bin/dump1090-json-server.py
    $SUDO chmod +x /usr/local/bin/dump1090-json-server.py
    $SUDO cp "$TRACKER_HTML" /usr/local/share/tracker.html
    info "JSON server script installed"
}

# ── systemd services (Debian) ────────────────────────────────────────────────
install_services_debian() {
    section "Installing systemd services"

    $SUDO tee /etc/systemd/system/dump1090-json-server.service > /dev/null << EOF
[Unit]
Description=dump1090 JSON CORS server
After=dump1090-mutability.service
Requires=dump1090-mutability.service

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/dump1090-json-server.py
Restart=always
User=$(whoami)

[Install]
WantedBy=multi-user.target
EOF

    $SUDO systemctl daemon-reload
    $SUDO systemctl enable dump1090-mutability
    $SUDO systemctl enable dump1090-json-server
    $SUDO systemctl restart dump1090-mutability
    sleep 3
    $SUDO systemctl restart dump1090-json-server
    info "systemd services installed and started"
}

# ── OpenRC services (Alpine) ─────────────────────────────────────────────────
install_services_alpine() {
    section "Installing OpenRC services"

    $SUDO tee /etc/init.d/dump1090 > /dev/null << 'EOF'
#!/sbin/openrc-run
description="dump1090 ADS-B receiver"
command="/usr/bin/dump1090"
command_args="--net --write-json /run/dump1090 --write-json-every 1 --quiet"
command_background=true
pidfile="/run/dump1090.pid"
command_user="root"
output_log="/var/log/dump1090.log"
error_log="/var/log/dump1090.log"
start_pre() {
    mkdir -p /run/dump1090
}
EOF
    $SUDO chmod +x /etc/init.d/dump1090

    $SUDO tee /etc/init.d/dump1090-json-server > /dev/null << 'EOF'
#!/sbin/openrc-run
description="dump1090 JSON CORS server"
depend() {
    need dump1090
    need net
}
command="/usr/bin/python3"
command_args="/usr/local/bin/dump1090-json-server.py"
command_background=true
pidfile="/run/dump1090-json-server.pid"
command_user="root"
output_log="/var/log/dump1090-json-server.log"
error_log="/var/log/dump1090-json-server.log"
EOF
    $SUDO chmod +x /etc/init.d/dump1090-json-server

    $SUDO rc-update add dump1090 default
    $SUDO rc-update add dump1090-json-server default
    $SUDO rc-service dump1090 restart
    sleep 3
    $SUDO rc-service dump1090-json-server restart
    info "OpenRC services installed and started"
}

# ── Install piaware ──────────────────────────────────────────────────────────
install_piaware_debian() {
    section "Installing piaware (Debian)"
    # Build dependencies
    $SUDO $PKG_INSTALL git build-essential debhelper tcl8.6-dev autoconf \
        python3-dev python3-venv libz-dev openssl \
        libboost-system-dev libboost-program-options-dev \
        libboost-regex-dev libboost-filesystem-dev patchelf \
        tclx tcllib

    if [ ! -d "$HOME/git/piaware_builder" ]; then
        git clone https://github.com/flightaware/piaware_builder.git "$HOME/git/piaware_builder"
    fi
    cd "$HOME/git/piaware_builder"
    chown -R "$(whoami):$(whoami)" .
    ./sensible-build.sh bookworm
    cd package-bookworm
    dpkg-buildpackage -b
    cd ..
    $SUDO dpkg -i piaware_*.deb || $SUDO apt-get install -f -y
}

install_piaware_alpine() {
    section "Installing piaware (Alpine)"
    $SUDO $PKG_INSTALL git tcl tcl-dev tclx tcl-lib tcl-tls autoconf make g++ coreutils

    # tcllauncher
    if [ ! -d "$HOME/git/tcllauncher" ]; then
        git clone https://github.com/flightaware/tcllauncher.git "$HOME/git/tcllauncher"
    fi
    cd "$HOME/git/tcllauncher"
    autoconf 2>/dev/null || true
    ./configure --with-tcl=/usr/lib
    make
    $SUDO make install

    # piaware
    if [ ! -d "$HOME/git/piaware" ]; then
        git clone https://github.com/flightaware/piaware.git "$HOME/git/piaware"
    fi
    cd "$HOME/git/piaware"
    $SUDO make install TCLSH=/usr/bin/tclsh
}

install_piaware_service_alpine() {
    $SUDO tee /etc/init.d/piaware > /dev/null << 'EOF'
#!/sbin/openrc-run
description="FlightAware piaware ADS-B uploader"
depend() {
    need dump1090
    need net
}
command="/usr/bin/piaware"
command_args="-plainlog"
command_background=true
pidfile="/run/piaware.pid"
command_user="root"
output_log="/var/log/piaware.log"
error_log="/var/log/piaware.log"
EOF
    $SUDO chmod +x /etc/init.d/piaware
    $SUDO rc-update add piaware default
    $SUDO rc-service piaware restart
}

install_piaware_service_debian() {
    $SUDO systemctl enable piaware
    $SUDO systemctl restart piaware
}

configure_piaware() {
    if [ -n "$FA_USER" ]; then
        section "Configuring piaware for user: $FA_USER"
        $SUDO tee /etc/piaware.conf > /dev/null << EOF
flightaware-user $FA_USER
EOF
        info "piaware configured for $FA_USER"
    else
        warn "No FlightAware username provided. piaware will connect as guest."
        warn "Run: echo 'flightaware-user YOUR_USERNAME' | sudo tee /etc/piaware.conf"
        warn "Then restart piaware to link to your account."
    fi
}

# ── Verify ───────────────────────────────────────────────────────────────────
verify() {
    section "Verifying installation"
    sleep 3
    if curl -s --max-time 5 "http://localhost:$SERVE_PORT/aircraft.json" | grep -q "aircraft"; then
        info "JSON feed working at http://localhost:$SERVE_PORT/aircraft.json"
        info "Tracker available at http://localhost:$SERVE_PORT/tracker.html"
    else
        warn "JSON feed not yet available — services may still be starting."
        warn "Try: curl http://localhost:$SERVE_PORT/aircraft.json"
    fi
}

# ── Usage ────────────────────────────────────────────────────────────────────
usage() {
    cat << EOF
Usage: $0 [options]

Options:
  --fa-user USERNAME    FlightAware username to configure piaware
  --skip-piaware        Skip piaware installation
  --skip-blacklist      Skip DVB module blacklisting
  --help                Show this help

Example:
  $0 --fa-user benaki
EOF
    exit 0
}

# ── Parse args ───────────────────────────────────────────────────────────────
SKIP_PIAWARE=0
SKIP_BLACKLIST=0

for arg in "$@"; do
    case $arg in
        --fa-user) FA_USER="$2"; shift 2 ;;
        --fa-user=*) FA_USER="${arg#*=}" ;;
        --skip-piaware) SKIP_PIAWARE=1 ;;
        --skip-blacklist) SKIP_BLACKLIST=1 ;;
        --help) usage ;;
    esac
done

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
    printf "\n${GREEN}╔══════════════════════════════════════╗${NC}\n"
    printf "${GREEN}║      ADS-B Tracker Installer         ║${NC}\n"
    printf "${GREEN}╚══════════════════════════════════════╝${NC}\n\n"

    detect_os
    check_dongle

    [ "$SKIP_BLACKLIST" -eq 0 ] && blacklist_dvb
    install_udev_rules

    case $OS in
        debian) install_packages_debian ;;
        alpine) install_packages_alpine ;;
    esac

    install_json_server

    # Update JSON_DIR in python server for debian
    if [ "$OS" = "debian" ]; then
        $SUDO sed -i "s|/run/dump1090|/run/dump1090-mutability|g" /usr/local/bin/dump1090-json-server.py
        $SUDO sed -i "s|/run/dump1090|/run/dump1090-mutability|g" /etc/systemd/system/dump1090-json-server.service 2>/dev/null || true
    fi

    case $OS in
        debian) install_services_debian ;;
        alpine) install_services_alpine ;;
    esac

    if [ "$SKIP_PIAWARE" -eq 0 ]; then
        case $OS in
            debian) install_piaware_debian ;;
            alpine) install_piaware_alpine ;;
        esac
        configure_piaware
        case $OS in
            debian) install_piaware_service_debian ;;
            alpine) install_piaware_service_alpine ;;
        esac
    fi

    verify

    printf "\n${GREEN}╔══════════════════════════════════════╗${NC}\n"
    printf "${GREEN}║         Installation complete!       ║${NC}\n"
    printf "${GREEN}╚══════════════════════════════════════╝${NC}\n\n"
    info "Tracker: http://localhost:$SERVE_PORT/tracker.html"
    info "JSON feed: http://localhost:$SERVE_PORT/aircraft.json"
    if [ -z "$FA_USER" ]; then
        warn "To link to FlightAware, run:"
        warn "  echo 'flightaware-user YOUR_USERNAME' | sudo tee /etc/piaware.conf"
        case $OS in
            debian) warn "  sudo systemctl restart piaware" ;;
            alpine) warn "  doas rc-service piaware restart" ;;
        esac
    fi
}

main "$@"
