#!/bin/sh
set -eu
umask 077

# A launcher/installer only. The normal CLI owns providers, credentials, phones,
# startup, recovery and the daemon. Never write its connection configuration here.
mindwire_tools="$HOME/.local/share/mindwire/toolchain"
PATH="$PATH:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin"
export PATH
mindwire_cli=$(command -v mindwire || true)

progress() { printf '{"event":"progress","message":"%s"}\n' "$1"; }

ensure_node() {
    if command -v node >/dev/null 2>&1 && node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 22 ? 0 : 1)' >/dev/null 2>&1 \
        && { [ "${1:-}" != npm ] || command -v npm >/dev/null 2>&1; }; then
        return
    fi
    mindwire_node_version=v24.22.0
    case "$(uname -m)" in
        arm64) mindwire_node_arch=arm64; mindwire_node_sha=6a9724d9b50a5f22b4816cded441b5a8d9ddae546191a5e5b7efa5a5e2ee26d5 ;;
        x86_64) mindwire_node_arch=x64; mindwire_node_sha=495e3f273c645f3c4677d438304cdfc701729ea5dec5728f5c8e76a2dece4b91 ;;
        *) printf '{"event":"error","message":"This Mac architecture is not supported."}\n'; exit 1 ;;
    esac
    mindwire_node_name="node-$mindwire_node_version-darwin-$mindwire_node_arch"
    if [ ! -x "$mindwire_tools/$mindwire_node_name/bin/node" ]; then
        progress "Installing the connection toolchain…"
        mkdir -p "$mindwire_tools"
        mindwire_install_tmp=$(mktemp -d "$mindwire_tools/.install.XXXXXX")
        trap 'rm -rf "$mindwire_install_tmp"' EXIT
        trap 'exit 130' INT
        trap 'exit 143' HUP TERM
        /usr/bin/curl --fail --silent --show-error --location --connect-timeout 15 --max-time 180 \
            "https://nodejs.org/dist/$mindwire_node_version/$mindwire_node_name.tar.gz" -o "$mindwire_install_tmp/node.tar.gz"
        mindwire_download_sha=$(/usr/bin/shasum -a 256 "$mindwire_install_tmp/node.tar.gz")
        if [ "${mindwire_download_sha%% *}" != "$mindwire_node_sha" ]; then
            printf '{"event":"error","message":"The toolchain download could not be verified. Try again."}\n'; exit 1
        fi
        /usr/bin/tar -xzf "$mindwire_install_tmp/node.tar.gz" -C "$mindwire_install_tmp"
        mv "$mindwire_install_tmp/$mindwire_node_name" "$mindwire_tools/$mindwire_node_name"
        rm -rf "$mindwire_install_tmp"
        trap - EXIT HUP INT TERM
    fi
    PATH="$mindwire_tools/$mindwire_node_name/bin:$PATH"
    export PATH
}

ensure_cli() {
    ensure_node
    if [ -n "$mindwire_cli" ]; then return; fi
    if [ -x "$mindwire_tools/npm/bin/mindwire" ]; then
        mindwire_cli="$mindwire_tools/npm/bin/mindwire"
        return
    fi
    ensure_node npm
    progress "Installing Mindwire…"
    mkdir -p "$mindwire_tools/npm"
    npm install --global --prefix "$mindwire_tools/npm" --no-audit --no-fund mindwire >&2
    mindwire_cli="$mindwire_tools/npm/bin/mindwire"
    if [ ! -x "$mindwire_cli" ]; then
        printf '{"event":"error","message":"Mindwire could not be installed. Try again."}\n'; exit 1
    fi
}

ensure_cli
case "${1:-}" in
    prepare)
        "$mindwire_cli" --version --json
        ;;
    pair)
        if [ -f "$HOME/.mindwire/computer/computer-config.json" ]; then
            exec "$mindwire_cli" connect pair --json
        else
            exec "$mindwire_cli" connection automatic --json
        fi
        ;;
    cli)
        shift
        exec "$mindwire_cli" --json "$@"
        ;;
    *) printf '{"event":"error","message":"Unsupported Mindwire launcher action."}\n'; exit 1 ;;
esac
