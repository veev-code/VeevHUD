#!/usr/bin/env bash
#
# Fetches all VeevHUD library dependencies into Libs/.
# Uses git only (no svn required). Safe to re-run — cleans and re-fetches each library.
#
# Usage: bash Tools/fetch-libs.sh    (from the VeevHUD addon root)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADDON_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIBS_DIR="$ADDON_DIR/Libs"

# Ace3 modules to extract (all from one repo)
ACE3_REPO="https://github.com/WoWUIDev/Ace3.git"
ACE3_MODULES=(
    LibStub
    CallbackHandler-1.0
    AceAddon-3.0
    AceConsole-3.0
    AceConfig-3.0
    AceDB-3.0
    AceDBOptions-3.0
    AceEvent-3.0
    AceGUI-3.0
    AceHook-3.0
)

# Libraries that need subdirectory extraction from their repo
declare -A SUBDIR_REPOS
SUBDIR_REPOS["LibSharedMedia-3.0"]="https://github.com/wowace-clone/LibSharedMedia-3.0.git"
SUBDIR_REPOS["AceGUI-3.0-SharedMediaWidgets"]="https://github.com/wowace-clone/AceGUI-3.0-SharedMediaWidgets.git"

# Libraries where the repo root IS the library
declare -A ROOT_REPOS
ROOT_REPOS["LibDualSpec-1.0"]="https://github.com/AdiAddons/LibDualSpec-1.0.git"
ROOT_REPOS["LibCustomGlow-1.0"]="https://github.com/Stanzilla/LibCustomGlow.git"

TMPDIR=""
cleanup() {
    if [[ -n "$TMPDIR" && -d "$TMPDIR" ]]; then
        rm -rf "$TMPDIR"
    fi
}
trap cleanup EXIT

fetch_ace3() {
    echo "Fetching Ace3 modules..."
    local ace3_tmp="$TMPDIR/Ace3"
    git clone --depth 1 --quiet "$ACE3_REPO" "$ace3_tmp"

    for module in "${ACE3_MODULES[@]}"; do
        local dest="$LIBS_DIR/$module"
        rm -rf "$dest"
        cp -r "$ace3_tmp/$module" "$dest"
        echo "  $module"
    done
}

fetch_subdir_repo() {
    local name="$1"
    local url="$2"
    echo "Fetching $name..."

    local repo_tmp="$TMPDIR/$name-repo"
    git clone --depth 1 --quiet "$url" "$repo_tmp"

    local dest="$LIBS_DIR/$name"
    rm -rf "$dest"
    cp -r "$repo_tmp/$name" "$dest"
    echo "  $name"
}

fetch_root_repo() {
    local name="$1"
    local url="$2"
    echo "Fetching $name..."

    local dest="$LIBS_DIR/$name"
    rm -rf "$dest"
    git clone --depth 1 --quiet "$url" "$dest"
    rm -rf "$dest/.git"
    echo "  $name"
}

create_libspelldb_stub() {
    local dest="$LIBS_DIR/LibSpellDB"
    if [[ -d "$dest" ]]; then
        return
    fi

    echo "Creating LibSpellDB stub (standalone addon expected at ../LibSpellDB/)..."
    mkdir -p "$dest"
    cat > "$dest/lib.xml" << 'XMLEOF'
<Ui xmlns="http://www.blizzard.com/wow/ui/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://www.blizzard.com/wow/ui/
..\FrameXML\UI.xsd">

    <!--
        Stub for local development.

        In packaged releases, .pkgmeta externals replaces this entire directory
        with a full clone of LibSpellDB. During local dev, the standalone
        LibSpellDB addon loads first (via OptionalDeps) and LibStub version
        checking prevents any double-initialization.

        This stub exists solely to suppress the "Couldn't open" LUA_WARNING
        that WoW emits when embeds.xml references a file that doesn't exist.
    -->

</Ui>
XMLEOF
    echo "  LibSpellDB (stub)"
}

main() {
    echo "VeevHUD Library Fetcher"
    echo "======================"
    echo ""

    TMPDIR="$(mktemp -d)"

    fetch_ace3

    for name in "${!SUBDIR_REPOS[@]}"; do
        fetch_subdir_repo "$name" "${SUBDIR_REPOS[$name]}"
    done

    for name in "${!ROOT_REPOS[@]}"; do
        fetch_root_repo "$name" "${ROOT_REPOS[$name]}"
    done

    create_libspelldb_stub

    echo ""
    echo "Done! All libraries fetched into $LIBS_DIR"
}

main
