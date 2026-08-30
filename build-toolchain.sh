#!/usr/bin/env bash

set -euo pipefail

base=$(dirname "$(readlink -f "$0")")
cd "$base"

install=$base/install

# Function to show an informational message
function msg() {
    echo -e "\e[1;32m$*\e[0m"
}

# Use a throwaway shallow clone on CI; locally, assume the repo is managed by
# the user and do not update it
[[ -n "${GITHUB_RUN_ID:-}" ]] && repo_flag="--shallow-clone" || repo_flag="--no-update"

# Getting Binutils source
BINUTILS_RELEASE=2.35.2
BINUTILS_TARBALL=binutils-$BINUTILS_RELEASE.tar.gz
BINUTILS_DIR=$base/binutils-$BINUTILS_RELEASE
if [[ ! -f $BINUTILS_TARBALL ]]; then
	msg "Downloading binutils $BINUTILS_RELEASE source"
	curl -fL --retry 3 -O "https://ftp.gnu.org/gnu/binutils/$BINUTILS_TARBALL"
fi
if [[ ! -d $BINUTILS_DIR ]]; then
	tar -xf "$BINUTILS_TARBALL"
fi
msg "Binutils dir is $BINUTILS_DIR"

# Build LLVM
msg "Building LLVM..."
# PGO (--pgo kernel-defconfig) is intentionally left out until the Actions
# build fits within the runner time limit; re-enable after flow is verified
./build-llvm.py \
	--install-folder "$install" \
	--targets AArch64 ARM X86 \
	--ref llvmorg-14.0.6 \
	"$repo_flag" \
	--lto thin

# Build binutils
msg "Building binutils..."
./build-binutils.py \
	--install-folder "$install" \
	--binutils-folder "$BINUTILS_DIR" \
	--targets arm aarch64 x86_64

# Verify the toolchain actually landed in the install folder before post-processing
if [[ ! -x "$install/bin/clang" ]]; then
	msg "ERROR: clang is missing from $install, nothing was installed!"
	exit 1
fi

# Remove unused products
msg "Removing unused products..."
rm -fr "$install/include"
rm -f "$install"/lib/*.a "$install"/lib/*.la

# Strip remaining products
msg "Stripping remaining products..."
stripped=0
while IFS= read -r -d '' f; do
	if file "$f" | grep -q 'not stripped'; then
		strip "$f"
		stripped=$((stripped + 1))
	fi
done < <(find "$install" -type f -print0)
msg "Stripped $stripped files"

# Set executable rpaths so setting LD_LIBRARY_PATH isn't necessary
msg "Setting library load paths for portability..."
patched=0
while IFS= read -r -d '' bin; do
	# Only ELF executables (not shared objects) have an interpreter
	if file "$bin" | grep -q 'ELF .* interpreter'; then
		echo "$bin"
		# shellcheck disable=SC2016  # $ORIGIN must stay a literal for the dynamic linker
		patchelf --set-rpath '$ORIGIN/../lib' "$bin"
		patched=$((patched + 1))
	fi
done < <(find "$install" -mindepth 2 -maxdepth 3 -type f -print0)
msg "Patched rpath in $patched files"
