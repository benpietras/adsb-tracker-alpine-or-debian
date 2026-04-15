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

if grep -qi raspberry /proc/cpuinfo 2>/dev/null || grep -qi raspberry /etc/os-release 2>/dev/null; then
    info "Detected Raspberry Pi"
    IS_PI=1
fi

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
install_dump1090_from_source() {
    info "Building dump1090-fa from source"
    $SUDO $PKG_INSTALL git build-essential debhelper librtlsdr-dev pkg-config \
        libncurses-dev
    [ -d "$HOME/git/dump1090" ] || git clone https://github.com/flightaware/dump1090.git "$HOME/git/dump1090"
    cd "$HOME/git/dump1090"
    make BLADERF=no HACKRF=no LIMESDR=no
    $SUDO install -m 0755 dump1090 /usr/bin/dump1090
    info "dump1090 built and installed from source"
    cd -
}

install_dump1090_debian() {
    pkg_available() {
        apt-cache policy "$1" 2>/dev/null | grep -q "Candidate:" && \
        ! apt-cache policy "$1" 2>/dev/null | grep -q "Candidate: (none)"
    }

    if pkg_available dump1090-fa; then
        info "Installing dump1090-fa from apt"
        $SUDO $PKG_INSTALL dump1090-fa
    elif pkg_available dump1090-mutability; then
        info "Installing dump1090-mutability from apt"
        $SUDO $PKG_INSTALL dump1090-mutability
    else
        info "No dump1090 in apt — adding FlightAware repo"
        CODENAME=$(grep VERSION_CODENAME /etc/os-release | cut -d= -f2)
        ARCH=$(dpkg --print-architecture)
        info "Detected: $CODENAME / $ARCH"
        FA_REPO_URL="https://www.flightaware.com/adsb/piaware/files/packages/pool/piaware/p/piaware-support/piaware-repository_10.0_all.deb"
        curl -L -o /tmp/piaware-repo.deb "$FA_REPO_URL"
        if dpkg-deb -I /tmp/piaware-repo.deb >/dev/null 2>&1; then
            $SUDO dpkg -i /tmp/piaware-repo.deb
            $SUDO $PKG_UPDATE
            if pkg_available dump1090-fa; then
                $SUDO $PKG_INSTALL dump1090-fa
            else
                warn "FlightAware repo doesn't support $CODENAME/$ARCH — building from source"
                install_dump1090_from_source
            fi
        else
            warn "FlightAware repo deb invalid — building from source"
            install_dump1090_from_source
        fi
    fi
}

install_packages_debian() {
    section "Installing packages (Debian)"
    $SUDO $PKG_UPDATE
    $SUDO $PKG_INSTALL rtl-sdr python3 curl

    install_dump1090_debian

    # Configure dump1090 if mutability config exists
    if [ -f /etc/default/dump1090-mutability ]; then
        USER_NAME=$(whoami)
        $SUDO sed -i "s/DUMP1090_USER=\"dump1090\"/DUMP1090_USER=\"$USER_NAME\"/" /etc/default/dump1090-mutability
        $SUDO sed -i 's|JSON_DIR=.*|JSON_DIR="/run/dump1090-mutability"|' /etc/default/dump1090-mutability
        $SUDO sed -i 's|EXTRA_ARGS=""|EXTRA_ARGS="--net-http-port 8889"|' /etc/default/dump1090-mutability 2>/dev/null || true
        $SUDO sed -i 's|LAT=""|LAT="53.4331"|' /etc/default/dump1090-mutability
        $SUDO sed -i 's|LON=""|LON="-2.1559"|' /etc/default/dump1090-mutability
        JSON_DIR="/run/dump1090-mutability"
    fi
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

    # Determine which dump1090 service to use
    if systemctl list-unit-files 2>/dev/null | grep -q "dump1090-mutability"; then
        DUMP1090_SERVICE="dump1090-mutability"
    elif systemctl list-unit-files 2>/dev/null | grep -q "dump1090-fa"; then
        DUMP1090_SERVICE="dump1090-fa"
    else
        # No package-installed service — create one
        info "Creating dump1090 systemd service"
        $SUDO tee /etc/systemd/system/dump1090.service > /dev/null << EOF
[Unit]
Description=dump1090 ADS-B receiver
After=network.target

[Service]
ExecStart=/usr/bin/dump1090 --net --write-json /run/dump1090 --write-json-every 1 --quiet --lat 53.4331 --lon -2.1559
Restart=always
User=$(whoami)
RuntimeDirectory=dump1090

[Install]
WantedBy=multi-user.target
EOF
        $SUDO systemctl daemon-reload
        JSON_DIR="/run/dump1090"
        DUMP1090_SERVICE="dump1090"
    fi

    $SUDO tee /etc/systemd/system/dump1090-json-server.service > /dev/null << EOF
[Unit]
Description=dump1090 JSON CORS server
After=${DUMP1090_SERVICE}.service
Requires=${DUMP1090_SERVICE}.service

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/dump1090-json-server.py
Restart=always
User=$(whoami)

[Install]
WantedBy=multi-user.target
EOF

    $SUDO systemctl daemon-reload
    $SUDO systemctl enable "$DUMP1090_SERVICE"
    $SUDO systemctl enable dump1090-json-server
    $SUDO systemctl restart "$DUMP1090_SERVICE"
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

    $SUDO $PKG_INSTALL git tcl tcl-dev tclx tcllib openssl \
        libboost-system-dev libboost-program-options-dev \
        libboost-regex-dev libboost-filesystem-dev \
        autoconf make g++ coreutils

    # Build tcllauncher
    if [ ! -d "$HOME/git/tcllauncher" ]; then
        git clone https://github.com/flightaware/tcllauncher.git "$HOME/git/tcllauncher"
    fi
    cd "$HOME/git/tcllauncher"
    autoconf 2>/dev/null || true
    TCL_LIB=$(find /usr/lib -name tclConfig.sh 2>/dev/null | head -1 | xargs dirname)
    ./configure --with-tcl="$TCL_LIB"
    make
    $SUDO make install
    cd -

    # Build piaware
    if [ ! -d "$HOME/git/piaware" ]; then
        git clone https://github.com/flightaware/piaware.git "$HOME/git/piaware"
    fi
    cd "$HOME/git/piaware"
    TCLSH=$(which tclsh)
    $SUDO make install TCLSH="$TCLSH"
    cd -

    info "piaware installed from source"
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
  --lat			Set latitude of receiver
  --long		Set longitude of receiver
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
	--lat=*)  LAT="${arg#*=}" ;;
	--lon=*)  LON="${arg#*=}" ;;
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

    # Get location
	if [ -z "$LAT" ] || [ -z "$LON" ]; then
    		printf "\nEnter your location for accurate position decoding:\n"
    		printf "Latitude (e.g. 53.4331): "
    		read LAT
    		printf "Longitude (e.g. -2.1559): "
    		read LON
	fi
    info "Using location: $LAT, $LO"

    [ "$SKIP_BLACKLIST" -eq 0 ] && blacklist_dvb
    install_udev_rules

    case $OS in
        debian) install_packages_debian ;;
        alpine) install_packages_alpine ;;
    esac

    install_json_server

    # Update JSON_DIR in python server for debian
    if [ "$OS" = "debian" ]; then
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
