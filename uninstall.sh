#!/usr/bin/env bash
set -Eeuo pipefail

PANEL_REPO="${PANEL_REPO:-plumbicon/olcrtc-manager-panel}"
PANEL_REF="${PANEL_REF:-main}"

BIN_DIR="${BIN_DIR:-/usr/local/bin}"
CONFIG_DIR="${CONFIG_DIR:-/etc/olcrtc-manager}"
SERVICE_NAME="${SERVICE_NAME:-olcrtc-manager}"
SERVICE_PATH="${SERVICE_PATH:-/etc/systemd/system/$SERVICE_NAME.service}"
TOOL_ROOT="${TOOL_ROOT:-/usr/local/lib/olcrtc-manager}"
TLS_CERT_PATH="${TLS_CERT_PATH:-}"
TLS_KEY_PATH="${TLS_KEY_PATH:-}"
TLS_MANAGED="${TLS_MANAGED:-}"

KEEP_CONFIG=0
KEEP_TOOLS=0
KEEP_CERTS=0
SKIP_NETWORK=0

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
OlcRTC Manager uninstaller

Usage:
  curl -fsSL https://raw.githubusercontent.com/$PANEL_REPO/$PANEL_REF/uninstall.sh | sudo bash
  bash uninstall.sh [options]

Options:
  --keep-config     Do not remove $CONFIG_DIR
  --keep-tools      Do not remove $TOOL_ROOT
  --keep-certs      Do not remove Let's Encrypt certificate files
  --skip-network    Do not remove olc-* netns, olh* links, cgroups, or iptables rules
  -h, --help        Show this help

Environment:
  BIN_DIR, CONFIG_DIR, SERVICE_NAME, SERVICE_PATH, TOOL_ROOT, TLS_CERT_PATH, TLS_KEY_PATH, TLS_MANAGED
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--keep-config)
			KEEP_CONFIG=1
			shift
			;;
		--keep-tools)
			KEEP_TOOLS=1
			shift
			;;
		--keep-certs)
			KEEP_CERTS=1
			shift
			;;
		--skip-network)
			SKIP_NETWORK=1
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

if [ "$(uname -s)" != "Linux" ]; then
	die "this uninstaller supports Linux only"
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

try() {
	"$@" || warn "command failed: $*"
}

quiet_try() {
	"$@" >/dev/null 2>&1 || true
}

safe_rm_rf() {
	local path="$1"
	local cleaned="${path%/}"
	if [ -z "$cleaned" ]; then
		cleaned="/"
	fi
	case "$cleaned" in
		''|/|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/sys|/tmp|/usr|/usr/bin|/usr/lib|/usr/local|/var)
			die "refusing to remove unsafe path: $path"
			;;
	esac
	if [ -e "$path" ] || [ -L "$path" ]; then
		if as_root rm -rf -- "$path"; then
			ok "removed $path"
		else
			warn "failed to remove $path"
		fi
	fi
}

service_env_value() {
	local key="$1"
	[ -f "$SERVICE_PATH" ] || return 1
	sed -n "s/^Environment=$key=//p" "$SERVICE_PATH" | tail -n1
}

capture_tls_paths() {
	if [ -z "$TLS_CERT_PATH" ]; then
		TLS_CERT_PATH="$(service_env_value OLCRTC_MANAGER_TLS_CERT || true)"
	fi
	if [ -z "$TLS_KEY_PATH" ]; then
		TLS_KEY_PATH="$(service_env_value OLCRTC_MANAGER_TLS_KEY || true)"
	fi
	if [ -z "$TLS_MANAGED" ]; then
		TLS_MANAGED="$(service_env_value OLCRTC_MANAGER_TLS_MANAGED || true)"
	fi
}

remove_cgroup_tree() {
	local root="$1"
	local dir=''
	local pids=''

	[ -d "$root" ] || return 0

	while read -r dir; do
		[ -n "$dir" ] || continue

		if [ -r "$dir/cgroup.procs" ]; then
			pids="$(as_root cat "$dir/cgroup.procs" 2>/dev/null || true)"
			if [ -n "$pids" ]; then
				while read -r pid; do
					[ -n "$pid" ] || continue
					as_root kill "$pid" 2>/dev/null || true
				done <<EOF
$pids
EOF
				sleep 1
				while read -r pid; do
					[ -n "$pid" ] || continue
					as_root kill -9 "$pid" 2>/dev/null || true
				done <<EOF
$pids
EOF
			fi
		fi

		if as_root rmdir "$dir" 2>/dev/null; then
			ok "removed cgroup $dir"
		fi
	done <<EOF
$(find "$root" -depth -type d 2>/dev/null || true)
EOF

	if [ -d "$root" ]; then
		warn "cgroup still exists: $root"
		warn "this usually means the kernel has live tasks there; reboot will clear an empty stale cgroup"
	fi
}

remove_certs() {
	local live_dir=''
	local domain=''

	if [ "$KEEP_CERTS" -eq 1 ]; then
		warn "keeping TLS certificate files"
		return 0
	fi
	[ -n "$TLS_CERT_PATH" ] || return 0
	if [ "$TLS_MANAGED" != "letsencrypt" ]; then
		warn "not removing TLS certificate because it is not marked as installer-managed: $TLS_CERT_PATH"
		return 0
	fi

	case "$TLS_CERT_PATH" in
		/etc/letsencrypt/live/*/fullchain.pem)
			live_dir="$(dirname "$TLS_CERT_PATH")"
			domain="$(basename "$live_dir")"
			safe_rm_rf "/etc/letsencrypt/live/$domain"
			safe_rm_rf "/etc/letsencrypt/archive/$domain"
			as_root rm -f -- "/etc/letsencrypt/renewal/$domain.conf"
			ok "removed Let's Encrypt certificate for $domain"
			;;
		*)
			warn "not removing custom TLS certificate path: $TLS_CERT_PATH"
			;;
	esac
}

delete_iptables_comment() {
	local table="$1"
	local comment="$2"
	local line=''
	local rule=''

	command -v iptables >/dev/null 2>&1 || return 0

	while line="$(as_root iptables -t "$table" -S 2>/dev/null | grep -- "$comment" | head -n1 || true)"; [ -n "$line" ]; do
		rule="$(printf '%s\n' "$line" | sed 's/^-A /-D /')"
		# iptables -S emits shell-like tokens. Project comments do not contain spaces.
		# shellcheck disable=SC2086
		if ! as_root iptables -t "$table" $rule; then
			warn "failed to delete iptables rule from $table: $line"
			break
		fi
	done
}

stop_service() {
	step "Stopping systemd service"
	if command -v systemctl >/dev/null 2>&1; then
		try as_root systemctl stop "$SERVICE_NAME"
		try as_root systemctl disable "$SERVICE_NAME"
	else
		warn "systemctl not found; skipping service stop"
	fi
}

remove_service() {
	step "Removing systemd unit"
	as_root rm -f -- "$SERVICE_PATH"
	if command -v systemctl >/dev/null 2>&1; then
		try as_root systemctl daemon-reload
		quiet_try as_root systemctl reset-failed "$SERVICE_NAME"
	fi
	ok "service unit removed"
}

cleanup_network() {
	local ns=''
	local dev=''
	local pids=''

	if [ "$SKIP_NETWORK" -eq 1 ]; then
		warn "network cleanup skipped"
		return 0
	fi

	step "Cleaning network namespaces and links"
	if command -v ip >/dev/null 2>&1; then
		while read -r ns; do
			[ -n "$ns" ] || continue
			pids="$(as_root ip netns pids "$ns" 2>/dev/null || true)"
			if [ -n "$pids" ]; then
				while read -r pid; do
					[ -n "$pid" ] || continue
					as_root kill "$pid" 2>/dev/null || true
				done <<EOF
$pids
EOF
				sleep 1
				while read -r pid; do
					[ -n "$pid" ] || continue
					as_root kill -9 "$pid" 2>/dev/null || true
				done <<EOF
$pids
EOF
			fi
			try as_root ip netns delete "$ns"
		done <<EOF
$(as_root ip netns list 2>/dev/null | awk '/^olc-/ {print $1}')
EOF

		while read -r dev; do
			[ -n "$dev" ] || continue
			try as_root ip link delete "$dev"
		done <<EOF
$(as_root ip -o link show 2>/dev/null | awk -F': ' '$2 ~ /^olh/ {gsub(/@.*/, "", $2); print $2}')
EOF
	else
		warn "ip command not found; skipping netns and veth cleanup"
	fi

	step "Cleaning iptables rules"
	delete_iptables_comment nat olcrtc-manager-netns
	delete_iptables_comment filter olcrtc-manager-netns
	delete_iptables_comment filter olcrtc-manager
	delete_iptables_comment nat olcrtc-manager
	ok "network cleanup completed"
}

remove_files() {
	step "Removing installed files"
	as_root rm -f -- "$BIN_DIR/olcrtc-manager" "$BIN_DIR/olcrtc"
	ok "binaries removed from $BIN_DIR"

	if [ "$KEEP_CONFIG" -eq 1 ]; then
		warn "keeping config directory: $CONFIG_DIR"
	else
		safe_rm_rf "$CONFIG_DIR"
	fi

	if [ "$KEEP_TOOLS" -eq 1 ]; then
		warn "keeping tool directory: $TOOL_ROOT"
	else
		safe_rm_rf "$TOOL_ROOT"
	fi

	remove_certs

	remove_cgroup_tree "/sys/fs/cgroup/net_cls,net_prio/olcrtc-manager"

	if [ -d /etc/netns ]; then
		while read -r ns_dir; do
			[ -n "$ns_dir" ] || continue
			safe_rm_rf "$ns_dir"
		done <<EOF
$(find /etc/netns -mindepth 1 -maxdepth 1 -type d -name 'olc-*' 2>/dev/null || true)
EOF
	fi
}

main() {
	capture_tls_paths
	stop_service
	cleanup_network
	remove_service
	remove_files

	cat <<EOF

Uninstall complete.

Removed:
  $SERVICE_PATH
  $BIN_DIR/olcrtc-manager
  $BIN_DIR/olcrtc
EOF

	if [ "$KEEP_CONFIG" -eq 0 ]; then
		printf '  %s\n' "$CONFIG_DIR"
	fi
	if [ "$KEEP_TOOLS" -eq 0 ]; then
		printf '  %s\n' "$TOOL_ROOT"
	fi
}

main "$@"
