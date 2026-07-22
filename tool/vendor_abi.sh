#!/bin/sh
# SPDX-FileCopyrightText: 2026 Joel Winarske
# SPDX-License-Identifier: MIT
#
# Vendors the C ABI headers from the libwebrtc fork and regenerates the
# bindings, or checks that what is vendored still matches.
#
#   tool/vendor_abi.sh <libwebrtc-checkout>  vendor from a checkout, pin the
#                                            revision, regenerate bindings
#   tool/vendor_abi.sh --check               verify the vendored headers are
#                                            byte-identical to the pinned
#                                            revision (what CI runs)
#
# The headers are the contract between this package and libwebrtc.so. Drift
# between them is silent -- the bindings simply stop covering part of the
# surface -- so it is checked rather than trusted.
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
vendor_dir="$repo_root/third_party/lw_abi"
revision_file="$vendor_dir/REVISION"
upstream=https://github.com/jwinarske/libwebrtc.git
headers='lw_c_api.h lw_video_sink.h'

usage() {
  echo "usage: $0 <libwebrtc-checkout> | --check" >&2
  exit 2
}

pinned_revision() {
  grep -v '^#' "$revision_file" | grep -v '^[[:space:]]*$' | head -1
}

# libclang needs its own builtin headers (stddef.h, stdint.h) on the include
# path. Where they live depends on the clang installation, so it is resolved
# here rather than hardcoded in ffigen.yaml.
regenerate() {
  resource_dir=$(clang -print-resource-dir 2>/dev/null || true)
  config="$repo_root/ffigen.yaml"
  generated=""
  if [ -n "$resource_dir" ] && [ -d "$resource_dir/include" ]; then
    # ffigen resolves the paths in a config relative to the config's own
    # directory, so the derived one has to sit beside the original.
    generated=$(mktemp "$repo_root/.ffigen-resolved.XXXXXX.yaml")
    awk -v inc="$resource_dir/include" '
      { print }
      /^compiler-opts:/ { print "  - \x27-I" inc "\x27" }
    ' "$config" > "$generated"
    config="$generated"
  fi
  ( cd "$repo_root" && dart run ffigen --config "$config" )
  [ -z "$generated" ] || rm -f "$generated"
}

# Puts the pinned headers in $1. Uses a partial, sparse clone: only the two
# files at that revision are ever fetched.
fetch_pinned() {
  revision=$(pinned_revision)
  git clone --quiet --filter=blob:none --no-checkout "$upstream" "$1"
  git -C "$1" sparse-checkout set --no-cone include/c >/dev/null
  if ! git -C "$1" checkout --quiet "$revision" 2>/dev/null; then
    echo "pinned revision $revision is not in $upstream;" \
         "was it pushed?" >&2
    exit 1
  fi
}

case "${1:-}" in
  --check)
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/lw_abi.XXXXXX")
    trap 'rm -rf "$tmp"' EXIT
    fetch_pinned "$tmp"
    status=0
    for header in $headers; do
      if ! diff -u "$tmp/include/c/$header" "$vendor_dir/$header"; then
        echo "vendored $header differs from $(pinned_revision)" >&2
        status=1
      fi
    done
    if [ "$status" -eq 0 ]; then
      echo "vendored headers match $(pinned_revision)"
    fi
    exit "$status"
    ;;
  -h|--help|'')
    usage
    ;;
  *)
    src=$1
    [ -d "$src/include/c" ] || { echo "$src is not a libwebrtc checkout" >&2; exit 1; }
    revision=$(git -C "$src" rev-parse HEAD)
    if ! git -C "$src" diff --quiet -- include/c; then
      echo "$src has uncommitted changes under include/c; commit them first" >&2
      exit 1
    fi
    for header in $headers; do
      cp "$src/include/c/$header" "$vendor_dir/$header"
    done
    cat > "$revision_file" <<EOF
# The jwinarske/libwebrtc revision the headers in this directory were taken
# from. tool/vendor_abi.sh --check verifies they are byte-identical to it.
$revision
EOF
    regenerate
    echo "vendored $headers from $revision; bindings regenerated"
    echo "check kExpectedAbiVersion in lib/src/native_library.dart against" \
         "LW_ABI_VERSION"
    ;;
esac
