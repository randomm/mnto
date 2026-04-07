#!/usr/bin/env bash
set -euo pipefail

# Description: Install mnto from GitHub releases
# Usage: install.sh [options]
# Options:
#   --uninstall  Remove mnto installation
#   --help       Show this help message

readonly REPO="randomm/mnto"
readonly GITHUB_API="https://api.github.com/repos/${REPO}/releases/latest"

# Configuration defaults
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local}"
VERSION="${VERSION:-latest}"

usage() {
	cat <<EOF
Usage: install.sh [options]

Install mnto from GitHub releases

Options:
    --uninstall    Remove mnto installation
    --help         Show this help message

Environment Variables:
    INSTALL_DIR    Installation directory (default: ~/.local)
    VERSION        Version to install (default: latest)

Examples:
    install.sh                    # Install latest version
    install.sh --uninstall        # Remove installation
    VERSION=v1.0.0 install.sh     # Install specific version
    INSTALL_DIR=/usr/local install.sh  # Install to custom location
EOF
}

log() {
	echo "→ $*"
}

error() {
	echo "✗ $*" >&2
	exit 1
}

require() {
	command -v "$1" >/dev/null 2>&1 || error "Required command not found: $1"
}

check_path() {
	local bin_dir="$1"
	case ":$PATH:" in
	*:"$bin_dir":*) return 0 ;;
	*) return 1 ;;
	esac
}

install() {
	log "Installing mnto ${VERSION} to ${INSTALL_DIR}"

	require curl
	require mktemp
	require tar

	# Create directories
	local bin_dir="${INSTALL_DIR}/bin"
	local lib_dir="${INSTALL_DIR}/lib/mnto"
	local config_dir="${HOME}/.config/mnto"

	# Pre-check permissions
	if [ ! -d "$INSTALL_DIR" ]; then
		mkdir -p "$INSTALL_DIR" || error "Cannot create installation directory: $INSTALL_DIR"
	fi
	[ -w "$INSTALL_DIR" ] || error "No write permission for: $INSTALL_DIR"

	log "Creating directories..."
	mkdir -p "${bin_dir}" "${lib_dir}" "${config_dir}"

	# Get download URL
	local download_url
	if [ "$VERSION" = "latest" ]; then
		log "Fetching latest release info..."
		download_url=$(curl -fsSL "${GITHUB_API}" | grep '"browser_download_url"' | head -n 1 | cut -d '"' -f 4)
	else
		download_url="https://github.com/${REPO}/releases/download/${VERSION}/mnto.tar.gz"
	fi

	[ -n "$download_url" ] || error "Failed to find download URL for version ${VERSION}"
	log "Downloading from ${download_url}"

	# Download and extract
	local temp_dir
	temp_dir="$(mktemp -d)"
	trap 'rm -rf "$temp_dir"' EXIT INT TERM

	local tarball="${temp_dir}/mnto.tar.gz"
	curl -fsSL -o "$tarball" "$download_url" || error "Failed to download release"

	# Download checksum if available
	local checksum_url="${download_url%.tar.gz}.sha256"
	local expected_hash=""
	expected_hash=$(curl -fsSL "$checksum_url" 2>/dev/null | cut -d' ' -f1) || true

	# Verify checksum
	if [ -n "$expected_hash" ]; then
		local actual_hash
		actual_hash=$(sha256sum "$tarball" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$tarball" | cut -d' ' -f1)
		[ "$actual_hash" = "$expected_hash" ] || error "Checksum mismatch - archive may be corrupted"
	fi

	# Safe extraction to isolated directory
	local extract_dir="${temp_dir}/extract"
	mkdir -p "$extract_dir"
	tar -xzf "$tarball" --strip-components=1 -C "$extract_dir" || error "Failed to extract"

	# Verify contents
	[ -f "${extract_dir}/mnto" ] || error "Archive does not contain mnto executable"
	[ -d "${extract_dir}/lib" ] || error "Archive does not contain lib directory"

	# Install files
	log "Installing executable to ${bin_dir}/mnto"
	cp "${extract_dir}/mnto" "${bin_dir}/mnto"
	chmod +x "${bin_dir}/mnto"

	log "Installing libraries to ${lib_dir}"
	cp -r "${extract_dir}/lib"/* "${lib_dir}/"

	log "Creating config directory at ${config_dir}"
	touch "${config_dir}/.gitkeep"

	# PATH check
	if ! check_path "$bin_dir"; then
		echo ""
		echo "⚠️  Warning: ${bin_dir} is not in your PATH"
		echo ""
		echo "Add the following to your shell profile (~/.bashrc, ~/.zshrc, etc.):"
		echo ""
		case "$SHELL" in
		*/zsh)
			echo "  export PATH=\"${bin_dir}:\$PATH\""
			;;
		*)
			echo "  export PATH=\"${bin_dir}:\$PATH\""
			;;
		esac
		echo ""
		echo "Then restart your shell or run: source ~/.bashrc (or ~/.zshrc)"
	fi

	echo ""
	# Validate installation
	if ! "${bin_dir}/mnto" --help >/dev/null 2>&1; then
		error "Installation validation failed"
	fi

	log "Installation complete!"
	log "Run '${bin_dir}/mnto --version' to verify"
}

uninstall() {
	log "Uninstalling mnto from ${INSTALL_DIR}"

	local bin_dir="${INSTALL_DIR}/bin/mnto"
	local lib_dir="${INSTALL_DIR}/lib/mnto"
	local config_dir="${HOME}/.config/mnto"

	if [ -f "$bin_dir" ]; then
		# Verify it's mnto by checking shebang
		if ! head -n 1 "$bin_dir" 2>/dev/null | grep -q "bash\|sh"; then
			error "$bin_dir does not appear to be mnto"
		fi
		log "Removing executable..."
		rm -f "$bin_dir"
	fi

	if [ -d "$lib_dir" ]; then
		log "Removing libraries..."
		rm -rf "$lib_dir"
	fi

	if [ -d "$config_dir" ]; then
		log "Removing config directory..."
		rm -rf "$config_dir"
	fi

	log "Uninstallation complete"
}

main() {
	case "${1:-}" in
	--help | -h)
		usage
		exit 0
		;;
	--uninstall)
		uninstall
		exit 0
		;;
	"")
		install
		exit 0
		;;
	*)
		echo "Unknown option: $1" >&2
		usage
		exit 1
		;;
	esac
}

main "$@"
