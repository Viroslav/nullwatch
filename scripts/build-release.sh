#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-2026.3.16}"
OUT_DIR="${2:-${ROOT_DIR}/release/${VERSION}}"

mkdir -p "${OUT_DIR}"

TARGETS=(
  "linux-x86_64:x86_64-linux-musl:"
  "linux-aarch64:aarch64-linux-musl:"
  "linux-riscv64:riscv64-linux-musl:"
  "macos-aarch64:aarch64-macos:"
  "macos-x86_64:x86_64-macos:"
  "windows-x86_64:x86_64-windows:.exe"
  "windows-aarch64:aarch64-windows:.exe"
)

for entry in "${TARGETS[@]}"; do
  IFS=":" read -r target zig_target ext <<<"${entry}"
  echo "==> building ${target}"
  (
    cd "${ROOT_DIR}"
    zig build -Doptimize=ReleaseSmall -Dversion="${VERSION}" -Dtarget="${zig_target}"
  )

  src_path="${ROOT_DIR}/zig-out/bin/nullwatch${ext}"
  if [[ "${ext}" == ".exe" ]]; then
    dest_path="${OUT_DIR}/nullwatch-${target}.exe"
  else
    dest_path="${OUT_DIR}/nullwatch-${target}.bin"
  fi
  cp "${src_path}" "${dest_path}"
done

archive_name="nullwatch-source-v${VERSION}.tar.gz"
tar \
  --exclude='.git' \
  --exclude='.zig-cache' \
  --exclude='release' \
  --exclude='zig-out' \
  -czf "${OUT_DIR}/${archive_name}" \
  -C "${ROOT_DIR}" .

if command -v shasum >/dev/null 2>&1; then
  (cd "${OUT_DIR}" && shasum -a 256 nullwatch-* > SHA256SUMS)
else
  (cd "${OUT_DIR}" && sha256sum nullwatch-* > SHA256SUMS)
fi

echo "release artifacts: ${OUT_DIR}"
