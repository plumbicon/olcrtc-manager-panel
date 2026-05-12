#!/usr/bin/env bash
set -Eeuo pipefail

PANEL_REPO="${PANEL_REPO:-plumbicon/olcrtc-manager-panel}"
PANEL_REF="${PANEL_REF:-main}"
OLCRTC_REPO="${OLCRTC_REPO:-openlibrecommunity/olcrtc}"
OLCRTC_REF="${OLCRTC_REF:-master}"

BIN_DIR="${BIN_DIR:-/usr/local/bin}"
CONFIG_DIR="${CONFIG_DIR:-/etc/olcrtc-manager}"
CONFIG_PATH="${CONFIG_PATH:-$CONFIG_DIR/config.json}"
SERVICE_NAME="${SERVICE_NAME:-olcrtc-manager}"
SERVICE_PATH="${SERVICE_PATH:-/etc/systemd/system/$SERVICE_NAME.service}"
TOOL_DIR="${TOOL_DIR:-/usr/local/lib/olcrtc-manager/tools}"

LISTEN_ADDR="${LISTEN_ADDR:-127.0.0.1}"
PORT="${PORT:-8888}"
PANEL_NAME="${PANEL_NAME:-OlcRTC VPS}"
CLIENT_ID="${CLIENT_ID:-default}"
LOCATION_NAME="${LOCATION_NAME:-Current VPS}"
CARRIER="${CARRIER:-wbstream}"
TRANSPORT="${TRANSPORT:-datachannel}"
LINK="${LINK:-direct}"
DATA_MODE="${DATA_MODE:-data}"
DNS_SERVER="${DNS_SERVER:-1.1.1.1:53}"
SPEED_MBPS="${SPEED_MBPS:-0}"
TRAFFIC_GB="${TRAFFIC_GB:-0}"
EXPIRES_AT="${EXPIRES_AT:-}"
ROOM_ID="${ROOM_ID:-}"
ENDPOINT_KEY="${ENDPOINT_KEY:-}"

PANEL_BINARY_URL="${PANEL_BINARY_URL:-}"
OLCRTC_BINARY_URL="${OLCRTC_BINARY_URL:-}"
GO_BOOTSTRAP_VERSION="${GO_BOOTSTRAP_VERSION:-1.25.0}"
NODE_BOOTSTRAP_VERSION="${NODE_BOOTSTRAP_VERSION:-v22.11.0}"
FORCE_CONFIG=0
SKIP_START=0
AUTO_INSTALL_DEPS="${AUTO_INSTALL_DEPS:-1}"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/olcrtc-manager-install.XXXXXX")"
cleanup() {
	[ -n "${TMP_ROOT:-}" ] && [ -d "$TMP_ROOT" ] && rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT

red=''
green=''
yellow=''
blue=''
reset=''
if [ -t 1 ]; then
	red="$(printf '\033[31m')"
	green="$(printf '\033[32m')"
	yellow="$(printf '\033[33m')"
	blue="$(printf '\033[34m')"
	reset="$(printf '\033[0m')"
fi

log() {
	printf '%s\n' "$*" >&2
}

step() {
	printf '\n%s==>%s %s\n' "$blue" "$reset" "$*" >&2
}

ok() {
	printf '%sOK%s %s\n' "$green" "$reset" "$*" >&2
}

warn() {
	printf '%sWARN%s %s\n' "$yellow" "$reset" "$*" >&2
}

die() {
	printf '%sERROR%s %s\n' "$red" "$reset" "$*" >&2
	exit 1
}

usage() {
	cat <<EOF
OlcRTC Manager installer

Usage:
  curl -fsSL https://raw.githubusercontent.com/$PANEL_REPO/$PANEL_REF/install.sh | sudo bash
  bash install.sh [options]

Options:
  --port PORT              Panel port, default: $PORT
  --addr ADDR              Listen address, default: $LISTEN_ADDR
  --panel-ref REF          olcrtc-manager ref to build from, default: $PANEL_REF
  --olcrtc-ref REF         olcrtc ref to build from, default: $OLCRTC_REF
  --panel-url URL          Direct olcrtc-manager binary/archive URL
  --olcrtc-url URL         Direct olcrtc binary/archive URL
  --config PATH            Config path, default: $CONFIG_PATH
  --force-config           Replace existing config.json, keeping a timestamped backup
  --skip-start             Install files but do not start/restart systemd service
  -h, --help               Show this help

Environment:
  PANEL_REPO, PANEL_REF, OLCRTC_REPO, OLCRTC_REF
  BIN_DIR, CONFIG_DIR, LISTEN_ADDR, PORT
  CLIENT_ID, LOCATION_NAME, CARRIER, TRANSPORT, DNS_SERVER
  ROOM_ID, ENDPOINT_KEY, SPEED_MBPS, TRAFFIC_GB, EXPIRES_AT
  PANEL_BINARY_URL, OLCRTC_BINARY_URL
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--port)
			PORT="${2:-}"
			shift 2
			;;
		--addr)
			LISTEN_ADDR="${2:-}"
			shift 2
			;;
		--panel-ref)
			PANEL_REF="${2:-}"
			shift 2
			;;
		--olcrtc-ref)
			OLCRTC_REF="${2:-}"
			shift 2
			;;
		--panel-url)
			PANEL_BINARY_URL="${2:-}"
			shift 2
			;;
		--olcrtc-url)
			OLCRTC_BINARY_URL="${2:-}"
			shift 2
			;;
		--config)
			CONFIG_PATH="${2:-}"
			CONFIG_DIR="$(dirname "$CONFIG_PATH")"
			shift 2
			;;
		--force-config)
			FORCE_CONFIG=1
			shift
			;;
		--skip-start)
			SKIP_START=1
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			die "unknown option: $1"
			;;
	esac
done

if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
	die "PORT must be a number between 1 and 65535"
fi

if [ "$(uname -s)" != "Linux" ]; then
	die "this installer supports Linux only"
fi

if ! command -v systemctl >/dev/null 2>&1; then
	die "systemctl is required; install on a systemd-based Linux server"
fi

if [ ! -d /run/systemd/system ]; then
	die "systemd is not running on this system"
fi

SUDO=''
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
	if command -v sudo >/dev/null 2>&1; then
		SUDO='sudo'
	else
		die "run as root or install sudo"
	fi
fi

as_root() {
	if [ -n "$SUDO" ]; then
		"$SUDO" "$@"
	else
		"$@"
	fi
}

download() {
	local url="$1"
	local output="$2"
	if command -v curl >/dev/null 2>&1; then
		curl -fL --retry 3 --connect-timeout 15 -o "$output" "$url"
	elif command -v wget >/dev/null 2>&1; then
		wget -q -O "$output" "$url"
	else
		die "curl or wget is required"
	fi
}

download_stdout() {
	local url="$1"
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --retry 3 --connect-timeout 15 "$url"
	elif command -v wget >/dev/null 2>&1; then
		wget -qO- "$url"
	else
		die "curl or wget is required"
	fi
}

install_packages() {
	[ "$AUTO_INSTALL_DEPS" = "1" ] || return 0

	local missing_runtime=''
	local runtime_cmd
	for runtime_cmd in curl tar gzip xz openssl ip iptables tc; do
		if ! command -v "$runtime_cmd" >/dev/null 2>&1; then
			missing_runtime="$missing_runtime $runtime_cmd"
		fi
	done
	if [ -z "$missing_runtime" ]; then
		ok "runtime tools found"
		return 0
	fi

	step "Installing missing runtime tools:$missing_runtime"

	local packages_debian='ca-certificates curl wget tar gzip xz-utils unzip openssl iproute2 iptables'
	local packages_rhel='ca-certificates curl wget tar gzip xz unzip openssl iproute iptables'
	local packages_arch='ca-certificates curl wget tar gzip xz unzip openssl iproute2 iptables'

	if command -v apt-get >/dev/null 2>&1; then
		if ! as_root apt-get update; then
			warn "apt-get update failed; continuing with existing package lists"
			warn "if installation still fails, fix disabled/unsigned apt sources and rerun"
		fi
		if ! as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y $packages_debian; then
			warn "apt-get install failed; continuing to final command checks"
		fi
	elif command -v dnf >/dev/null 2>&1; then
		if ! as_root dnf install -y $packages_rhel; then
			warn "dnf install failed; continuing to final command checks"
		fi
	elif command -v yum >/dev/null 2>&1; then
		if ! as_root yum install -y $packages_rhel; then
			warn "yum install failed; continuing to final command checks"
		fi
	elif command -v pacman >/dev/null 2>&1; then
		if ! as_root pacman -Sy --needed --noconfirm $packages_arch; then
			warn "pacman install failed; continuing to final command checks"
		fi
	else
		warn "unknown package manager; assuming base tools are already installed"
	fi
}

need_commands() {
	local missing=''
	local cmd
	for cmd in "$@"; do
		if ! command -v "$cmd" >/dev/null 2>&1; then
			missing="$missing $cmd"
		fi
	done
	if [ -n "$missing" ]; then
		die "missing required commands:$missing"
	fi
}

detect_arch() {
	case "$(uname -m)" in
		x86_64|amd64)
			GOARCH='amd64'
			NODE_ARCH='x64'
			ASSET_ARCH_REGEX='amd64|x86_64|x64'
			;;
		aarch64|arm64)
			GOARCH='arm64'
			NODE_ARCH='arm64'
			ASSET_ARCH_REGEX='arm64|aarch64'
			;;
		*)
			die "unsupported CPU architecture: $(uname -m)"
			;;
	esac
}

version_ge() {
	local have="$1"
	local need="$2"
	[ "$(printf '%s\n%s\n' "$need" "$have" | sort -V | head -n1)" = "$need" ]
}

command_version_go() {
	go version 2>/dev/null | awk '{print $3}' | sed 's/^go//; s/[^0-9.].*$//'
}

command_version_node() {
	node --version 2>/dev/null | sed 's/^v//; s/[^0-9.].*$//'
}

ensure_go() {
	local min_version='1.25.0'
	local have=''
	if command -v go >/dev/null 2>&1; then
		have="$(command_version_go)"
	fi
	if [ -n "$have" ] && version_ge "$have" "$min_version"; then
		ok "Go $have found"
		return 0
	fi

	step "Installing local Go $GO_BOOTSTRAP_VERSION"
	local archive="$TMP_ROOT/go.tar.gz"
	local go_dir="$TOOL_DIR/go-$GO_BOOTSTRAP_VERSION"
	if [ -x "$go_dir/bin/go" ]; then
		export PATH="$go_dir/bin:$PATH"
		have="$(command_version_go)"
		if [ -n "$have" ] && version_ge "$have" "$min_version"; then
			ok "Go $have ready"
			return 0
		fi
	fi
	download "https://go.dev/dl/go$GO_BOOTSTRAP_VERSION.linux-$GOARCH.tar.gz" "$archive"
	as_root mkdir -p "$go_dir"
	as_root tar -xzf "$archive" -C "$go_dir" --strip-components=1
	export PATH="$go_dir/bin:$PATH"

	have="$(command_version_go)"
	if [ -z "$have" ] || ! version_ge "$have" "$min_version"; then
		die "failed to install Go >= $min_version"
	fi
	ok "Go $have ready"
}

ensure_node() {
	local min_version='18.0.0'
	local have=''
	if command -v node >/dev/null 2>&1; then
		have="$(command_version_node)"
	fi
	if [ -n "$have" ] && version_ge "$have" "$min_version"; then
		ok "Node.js $have found"
		return 0
	fi

	step "Installing local Node.js $NODE_BOOTSTRAP_VERSION"
	local archive="$TMP_ROOT/node.tar.xz"
	local node_dir="$TOOL_DIR/node-$NODE_BOOTSTRAP_VERSION-linux-$NODE_ARCH"
	if [ -x "$node_dir/bin/node" ]; then
		export PATH="$node_dir/bin:$PATH"
		have="$(command_version_node)"
		if [ -n "$have" ] && version_ge "$have" "$min_version"; then
			ok "Node.js $have ready"
			return 0
		fi
	fi
	download "https://nodejs.org/dist/$NODE_BOOTSTRAP_VERSION/node-$NODE_BOOTSTRAP_VERSION-linux-$NODE_ARCH.tar.xz" "$archive"
	as_root mkdir -p "$node_dir"
	as_root tar -xJf "$archive" -C "$node_dir" --strip-components=1
	export PATH="$node_dir/bin:$PATH"

	have="$(command_version_node)"
	if [ -z "$have" ] || ! version_ge "$have" "$min_version"; then
		die "failed to install Node.js >= $min_version"
	fi
	ok "Node.js $have ready"
}

github_latest_asset_url() {
	local repo="$1"
	local binary_name="$2"
	local metadata=''
	local pattern
	metadata="$(download_stdout "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null || true)"
	[ -n "$metadata" ] || return 1

	pattern="$binary_name.*linux.*($ASSET_ARCH_REGEX)|$binary_name-linux-($ASSET_ARCH_REGEX)"
	printf '%s\n' "$metadata" \
		| sed -n 's/.*"browser_download_url": *"\([^"]*\)".*/\1/p' \
		| grep -Eiv 'sha256|checksums|signature|sig$|asc$' \
		| grep -Ei "$pattern" \
		| head -n1
}

extract_archive() {
	local archive="$1"
	local dest="$2"
	mkdir -p "$dest"
	case "$archive" in
		*.tar.gz|*.tgz)
			tar -xzf "$archive" -C "$dest"
			;;
		*.tar.xz|*.txz)
			tar -xJf "$archive" -C "$dest"
			;;
		*.zip)
			need_commands unzip
			unzip -q "$archive" -d "$dest"
			;;
		*)
			return 1
			;;
	esac
}

asset_to_binary() {
	local url="$1"
	local binary_name="$2"
	local out="$3"
	local file="$TMP_ROOT/$(basename "${url%%\?*}")"
	local extracted="$TMP_ROOT/extract-$binary_name-$(date +%s%N)"
	local candidate=''

	step "Downloading $binary_name binary"
	download "$url" "$file"

	if extract_archive "$file" "$extracted"; then
		candidate="$(find "$extracted" -type f \
			\( -name "$binary_name" -o -name "$binary_name-linux-$GOARCH" -o -name "$binary_name-linux-$(uname -m)" \) \
			| head -n1)"
		if [ -z "$candidate" ]; then
			candidate="$(find "$extracted" -type f -name "$binary_name*" | head -n1)"
		fi
		[ -n "$candidate" ] || die "archive does not contain $binary_name"
		cp "$candidate" "$out"
	else
		cp "$file" "$out"
	fi

	chmod 0755 "$out"
	"$out" --help >/dev/null 2>&1 || true
	ok "$binary_name downloaded"
}

download_source() {
	local repo="$1"
	local ref="$2"
	local name="$3"
	local archive="$TMP_ROOT/$name-source.tar.gz"
	local dest="$TMP_ROOT/$name-source"
	local src=''

	step "Downloading $repo@$ref source"
	download "https://github.com/$repo/archive/$ref.tar.gz" "$archive"
	mkdir -p "$dest"
	tar -xzf "$archive" -C "$dest"
	src="$(find "$dest" -mindepth 1 -maxdepth 1 -type d | head -n1)"
	[ -n "$src" ] || die "failed to unpack $repo@$ref"
	printf '%s\n' "$src"
}

find_bundled_binary() {
	local src="$1"
	local binary_name="$2"
	find "$src" -type f \
		\( -path "*/packaging/bin/$binary_name" \
		-o -path "*/packaging/bin/$binary_name-linux-$GOARCH" \
		-o -path "*/packaging/bin/$binary_name-linux-$(uname -m)" \
		-o -path "*/dist/$binary_name-linux-$GOARCH" \
		-o -path "*/dist/$binary_name" \) \
		| head -n1
}

build_panel() {
	local out="$1"
	local src="$2"
	local bundled=''

	bundled="$(find_bundled_binary "$src" "olcrtc-manager")"
	if [ -n "$bundled" ]; then
		cp "$bundled" "$out"
		chmod 0755 "$out"
		ok "using bundled olcrtc-manager binary"
		return 0
	fi

	ensure_go
	ensure_node

	step "Building olcrtc-manager"
	(
		cd "$src"
		if command -v pnpm >/dev/null 2>&1; then
			pnpm install --frozen-lockfile || pnpm install
			pnpm build
		else
			if command -v corepack >/dev/null 2>&1; then
				corepack enable >/dev/null 2>&1 || true
				corepack prepare pnpm@9.15.4 --activate >/dev/null 2>&1 || true
			fi
			if command -v pnpm >/dev/null 2>&1; then
				pnpm install --frozen-lockfile || pnpm install
				pnpm build
			else
				npm install
				npm run build
			fi
		fi
		CGO_ENABLED=0 GOOS=linux GOARCH="$GOARCH" go build -trimpath -ldflags "-s -w" -o "$out" ./cmd/olcrtc-manager
	)
	chmod 0755 "$out"
	ok "olcrtc-manager built"
}

build_olcrtc() {
	local out="$1"
	local src="$2"
	local bundled=''

	bundled="$(find_bundled_binary "$src" "olcrtc")"
	if [ -n "$bundled" ]; then
		cp "$bundled" "$out"
		chmod 0755 "$out"
		ok "using bundled olcrtc binary"
		return 0
	fi

	ensure_go

	step "Building olcrtc"
	(
		cd "$src"
		CGO_ENABLED=0 GOOS=linux GOARCH="$GOARCH" go build -trimpath -ldflags "-s -w" -o "$out" ./cmd/olcrtc
	)
	chmod 0755 "$out"
	ok "olcrtc built"
}

obtain_binary() {
	local binary_name="$1"
	local direct_url="$2"
	local repo="$3"
	local ref="$4"
	local out="$5"
	local src_var="$6"
	local release_url=''
	local src=''

	if [ -n "$direct_url" ]; then
		asset_to_binary "$direct_url" "$binary_name" "$out"
		return 0
	fi

	release_url="$(github_latest_asset_url "$repo" "$binary_name" || true)"
	if [ -n "$release_url" ]; then
		asset_to_binary "$release_url" "$binary_name" "$out"
		return 0
	fi

	src="$(download_source "$repo" "$ref" "$binary_name")"
	printf -v "$src_var" '%s' "$src"
	if [ "$binary_name" = "olcrtc-manager" ]; then
		build_panel "$out" "$src"
	else
		build_olcrtc "$out" "$src"
	fi
}

json_escape() {
	printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g'
}

random_hex() {
	if command -v openssl >/dev/null 2>&1; then
		openssl rand -hex 32
	else
		dd if=/dev/urandom bs=32 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n'
		printf '\n'
	fi
}

generate_room_id() {
	local olcrtc_bin="$1"
	"$olcrtc_bin" -mode gen -carrier "$CARRIER" -dns "$DNS_SERVER" -amount 1 \
		| awk 'NF {print; exit}'
}

write_config() {
	local olcrtc_bin="$1"
	local tmp_config="$TMP_ROOT/config.json"
	local room="$ROOM_ID"
	local key="$ENDPOINT_KEY"

	as_root install -d -m 0755 "$CONFIG_DIR"
	if [ -f "$CONFIG_PATH" ] && [ "$FORCE_CONFIG" -eq 0 ]; then
		ok "keeping existing config: $CONFIG_PATH"
		return 0
	fi

	if [ -z "$room" ]; then
		step "Generating initial Room ID"
		room="$(generate_room_id "$olcrtc_bin" || true)"
		[ -n "$room" ] || die "olcrtc did not generate a Room ID; set ROOM_ID manually and rerun"
	fi
	if [ -z "$key" ]; then
		key="$(random_hex)"
	fi

	cat >"$tmp_config" <<EOF
{
  "version": 1,
  "name": "$(json_escape "$PANEL_NAME")",
  "port": $PORT,
  "clients": [
    {
      "client-id": "$(json_escape "$CLIENT_ID")",
      "quota": {
        "speed_mbps": $SPEED_MBPS,
        "traffic_gb": $TRAFFIC_GB,
        "expires_at": "$(json_escape "$EXPIRES_AT")"
      },
      "locations": [
        {
          "name": "$(json_escape "$LOCATION_NAME")",
          "endpoint": {
            "room_id": "$(json_escape "$room")",
            "key": "$(json_escape "$key")"
          },
          "carrier": "$(json_escape "$CARRIER")",
          "transport": {
            "type": "$(json_escape "$TRANSPORT")"
          },
          "link": "$(json_escape "$LINK")",
          "data": "$(json_escape "$DATA_MODE")",
          "dns": "$(json_escape "$DNS_SERVER")"
        }
      ]
    }
  ]
}
EOF

	if [ -f "$CONFIG_PATH" ]; then
		as_root cp "$CONFIG_PATH" "$CONFIG_PATH.bak.$(date +%Y%m%d%H%M%S)"
	fi
	as_root install -m 0600 "$tmp_config" "$CONFIG_PATH"
	ok "config installed: $CONFIG_PATH"
}

write_service() {
	local tmp_service="$TMP_ROOT/$SERVICE_NAME.service"
	cat >"$tmp_service" <<EOF
[Unit]
Description=OlcRTC Manager Panel
Documentation=https://github.com/$PANEL_REPO
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=OLCRTC_PATH=$BIN_DIR/olcrtc
Environment=OLCRTC_MANAGER_ADDR=$LISTEN_ADDR
ExecStart=$BIN_DIR/olcrtc-manager -config $CONFIG_PATH -port $PORT
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5s
KillSignal=SIGTERM
TimeoutStopSec=10s

# The manager creates network namespaces, veth interfaces, tc qdiscs and iptables rules.
# It intentionally runs as root.

[Install]
WantedBy=multi-user.target
EOF
	as_root install -m 0644 "$tmp_service" "$SERVICE_PATH"
	ok "systemd unit installed: $SERVICE_PATH"
}

check_port() {
	if command -v ss >/dev/null 2>&1; then
		if ss -ltn | awk '{print $4}' | grep -Eq "[:.]$PORT$"; then
			warn "port $PORT already appears to be in use"
		fi
	fi
}

install_files() {
	local manager_bin="$1"
	local olcrtc_bin="$2"
	as_root install -d -m 0755 "$BIN_DIR"
	as_root install -m 0755 "$manager_bin" "$BIN_DIR/olcrtc-manager"
	as_root install -m 0755 "$olcrtc_bin" "$BIN_DIR/olcrtc"
	ok "binaries installed to $BIN_DIR"
}

start_service() {
	as_root systemctl daemon-reload
	as_root systemctl enable "$SERVICE_NAME" >/dev/null

	if [ "$SKIP_START" -eq 1 ]; then
		ok "service enabled; start skipped"
		return 0
	fi

	as_root systemctl restart "$SERVICE_NAME"
	sleep 2
	if systemctl is-active --quiet "$SERVICE_NAME"; then
		ok "$SERVICE_NAME is running"
	else
		as_root systemctl --no-pager --full status "$SERVICE_NAME" || true
		die "$SERVICE_NAME failed to start"
	fi
}

print_summary() {
	local host='SERVER'
	local public_ip=''
	public_ip="$(download_stdout 'https://api.ipify.org' 2>/dev/null || true)"
	if [ "$LISTEN_ADDR" = "127.0.0.1" ] || [ "$LISTEN_ADDR" = "localhost" ]; then
		host='127.0.0.1'
	elif [ -n "$public_ip" ]; then
		host="$public_ip"
	fi

	cat <<EOF

Installation complete.

Panel:
  http://$host:$PORT/admin

Files:
  $BIN_DIR/olcrtc-manager
  $BIN_DIR/olcrtc
  $CONFIG_PATH
  $SERVICE_PATH

Commands:
  systemctl status $SERVICE_NAME
  journalctl -u $SERVICE_NAME -f
  systemctl reload $SERVICE_NAME

First run:
  Open /admin and set the admin password. The installer does not create panel.env.
EOF
}

main() {
	local manager_out="$TMP_ROOT/olcrtc-manager"
	local olcrtc_out="$TMP_ROOT/olcrtc"
	local panel_src=''
	local olcrtc_src=''

	step "Preparing system"
	detect_arch
	install_packages
	need_commands tar gzip sed awk grep find install systemctl ip iptables tc
	check_port

	obtain_binary "olcrtc-manager" "$PANEL_BINARY_URL" "$PANEL_REPO" "$PANEL_REF" "$manager_out" panel_src
	obtain_binary "olcrtc" "$OLCRTC_BINARY_URL" "$OLCRTC_REPO" "$OLCRTC_REF" "$olcrtc_out" olcrtc_src

	step "Installing runtime files"
	install_files "$manager_out" "$olcrtc_out"
	write_config "$olcrtc_out"
	write_service
	start_service
	print_summary
}

main "$@"
