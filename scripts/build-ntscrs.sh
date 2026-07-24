#!/usr/bin/env bash
# Build the ntscrs-capi dylib (C ABI over the ntsc-rs core library) and place
# it where the app looks for it (Vendor/ntscrs-capi/ntscrs_capi.dylib).
# Requires the Rust toolchain and the Vendor/ntsc-rs submodule.

set -euo pipefail
cd "$(dirname "$0")/../Vendor/ntscrs-capi"

if [[ ! -f ../ntsc-rs/crates/ntscrs/Cargo.toml ]]; then
  echo "Vendor/ntsc-rs submodule missing — run: git submodule update --init --recursive" >&2
  exit 1
fi

# Universal (arm64 + x86_64) when the rustup stable toolchain is present
# (homebrew's rust is host-only); falls back to a host-arch build otherwise.
TC="$HOME/.rustup/toolchains/stable-aarch64-apple-darwin"
if [[ -x "$TC/bin/cargo" ]]; then
  RUSTC="$TC/bin/rustc" "$TC/bin/cargo" build --release --target aarch64-apple-darwin
  RUSTC="$TC/bin/rustc" "$TC/bin/cargo" build --release --target x86_64-apple-darwin
  lipo -create target/aarch64-apple-darwin/release/libntscrs_capi.dylib \
               target/x86_64-apple-darwin/release/libntscrs_capi.dylib \
       -output ntscrs_capi.dylib
else
  echo 'note: rustup stable toolchain not found - building host-arch only' >&2
  cargo build --release
  cp target/release/libntscrs_capi.dylib ntscrs_capi.dylib
fi
install_name_tool -id @rpath/ntscrs_capi.dylib ntscrs_capi.dylib
echo "built: Vendor/ntscrs-capi/ntscrs_capi.dylib ($(lipo -archs ntscrs_capi.dylib))"
