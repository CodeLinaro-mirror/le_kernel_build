#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.

set -euo pipefail

usage() {
  cat <<EOF
Usage:
  $0 --dist DIST_PATH --dtbo DTBO_NAME [--host HOST_PATH] [options]

Required:
  --dist PATH            DIST directory (must contain Image, boot images,
                         super_unsparsed.img, and the packed DTBO image)
  --dtbo NAME            Packed DTBO image filename in DIST
                         (e.g. hamoa_dtbo.img). Written verbatim into
                         the dtbo_a partition; no FIT merge is performed.

Prebuilt image option:
  --prebuilts PATH       Directory containing:
                         esp.img, NON-HLOS.bin, BTFM.bin,
                         dspso.bin, persist.img, pvmfw.img

Optional:
  --host PATH            Host tools directory (mkbootimg, avbtool, pack_image)
                         Default: ./host/linux-x86/bin from current working directory
  --stage PATH           Stage/output working directory
                         (default: /tmp/manual_pack_noavb_<timestamp>)
  -h, --help             Show this help

Notes:
  - Missing --prebuilts or missing files only produce WARNINGs and script continues.
  - For required installable images (NON-HLOS.bin, BTFM.bin, dspso.bin, persist.img),
    placeholders are created when missing so pack_image can still run.
EOF
}

warn() {
  echo "WARNING: $*" >&2
}

add_hash_footer_none() {
  local image="$1"
  local partition_name="$2"
  local partition_size="$3"
  local required="${4:-true}"

  if [ ! -f "$image" ]; then
    if [ "$required" = "true" ]; then
      echo "ERROR: missing image for AVB footer: $image"
      exit 1
    fi
    warn "Skipping AVB footer for $partition_name; image not found: $image"
    return 1
  fi

  # Remove old metadata if present so footer regeneration is deterministic.
  "$HOST/avbtool" erase_footer --image "$image" >/dev/null 2>&1 || true

  if ! "$HOST/avbtool" add_hash_footer \
      --image "$image" \
      --partition_name "$partition_name" \
      --partition_size "$partition_size" \
      --algorithm NONE >/dev/null; then
    if [ "$required" = "true" ]; then
      echo "ERROR: failed to add AVB footer for $partition_name ($image)"
      exit 1
    fi
    warn "Failed to add AVB footer for optional $partition_name; continuing."
    return 1
  fi

  return 0
}

copy_or_placeholder() {
  local src="$1"
  local dst="$2"
  local label="$3"
  local make_empty="${4:-false}"

  if [ -n "$src" ] && [ -f "$src" ]; then
    cp "$src" "$dst"
    return
  fi

  if [ -z "$src" ]; then
    warn "$label path not provided; continuing."
  else
    warn "$label not found: $src; continuing."
  fi

  if [ "$make_empty" = "true" ]; then
    : > "$dst"
    warn "Created empty placeholder: $dst"
  fi
}

DIST=""
HOST=""
PREBUILTS_DIR=""
STAGE=""
DTBO_NAME=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dist)
      DIST="${2:-}"
      shift 2
      ;;
    --dtbo)
      DTBO_NAME="${2:-}"
      shift 2
      ;;
    --host)
      HOST="${2:-}"
      shift 2
      ;;
    --prebuilts)
      PREBUILTS_DIR="${2:-}"
      shift 2
      ;;
    --stage)
      STAGE="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [ -z "$DTBO_NAME" ]; then
  echo "ERROR: --dtbo is required." >&2
  usage
  exit 1
fi

if [ ! -f "$DIST/$DTBO_NAME" ]; then
  echo "ERROR: packed DTBO image not found: $DIST/$DTBO_NAME"
  exit 1
fi

if [ -z "$HOST" ]; then
  HOST="$PWD/host/linux-x86/bin"
fi

if [ ! -d "$HOST" ]; then
  echo "ERROR: host path not found: $HOST"
  echo "Hint: provide --host PATH or run from a directory that has host/linux-x86/bin"
  exit 1
fi

if [ -n "$PREBUILTS_DIR" ] && [ ! -d "$PREBUILTS_DIR" ]; then
  warn "--prebuilts directory not found: $PREBUILTS_DIR;" \
       " continuing with missing-prebuilt fallbacks."
  PREBUILTS_DIR=""
fi

for req in mkbootimg avbtool pack_image; do
  if [ ! -x "$HOST/$req" ]; then
    echo "ERROR: required host tool missing or not executable: $HOST/$req"
    exit 1
  fi
done

for req in boot-lz4.img "$DTBO_NAME" init_boot.img vendor_boot.img super_unsparsed.img; do
  if [ ! -f "$DIST/$req" ]; then
    echo "ERROR: required file missing in DIST: $DIST/$req"
    exit 1
  fi
done

for tool in xxd file; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: required tool not found in PATH: $tool"
    exit 1
  fi
done

# Pure-Python3 GPT partition lookup — no host tools required.
# Prints "start_lba end_lba" for the named partition, or nothing if not found.
gpt_find_partition() {
  python3 - "$1" "$2" << 'PYEOF'
import struct, sys

def gpt_lookup(path, target):
    with open(path, "rb") as f:
        f.seek(512)
        hdr = f.read(512)
        if hdr[:8] != b"EFI PART":
            return None
        part_lba  = struct.unpack_from("<Q", hdr, 72)[0]
        part_num  = struct.unpack_from("<I", hdr, 80)[0]
        part_size = struct.unpack_from("<I", hdr, 84)[0]
        f.seek(part_lba * 512)
        for _ in range(part_num):
            entry = f.read(part_size)
            if len(entry) < 128 or entry[:16] == b"\x00" * 16:
                continue
            start, end = struct.unpack_from("<QQ", entry, 32)
            name = entry[56:128].decode("utf-16-le").rstrip("\x00")
            if name == target:
                return start, end
    return None

result = gpt_lookup(sys.argv[1], sys.argv[2])
if result:
    print(result[0], result[1])
PYEOF
}

if [ -z "$STAGE" ]; then
  STAMP=$(date +%Y%m%d_%H%M%S)
  STAGE="/tmp/manual_pack_noavb_${STAMP}"
fi

mkdir -p "$STAGE"
echo "STAGE=$STAGE"
echo "DIST=$DIST"
echo "HOST=$HOST"
echo "DTBO_NAME=$DTBO_NAME"
echo "PREBUILTS_DIR=${PREBUILTS_DIR:-<not provided>}"

# 1) Stage the packed DTBO image (no FIT merge, no fdtoverlay).
#    $DTBO_NAME is the packed DTBO image (e.g. hamoa_dtbo.img); it is written
#    verbatim into the dtbo_a partition by pack_image later.
rm -f "$STAGE/boot.img" "$STAGE/dtbo.img"
cp "$DIST/$DTBO_NAME" "$STAGE/dtbo.img"

# 2) Use boot-lz4.img from dist verbatim as boot.img.
#    boot-lz4.img is the Android boot image produced by the Bazel build with
#    the lz4-compressed kernel payload. depthcharge loads this directly from
#    boot_a; no mkbootimg re-wrap needed.
cp "$DIST/boot-lz4.img" "$STAGE/boot.img"

# boot_a partition is 64 MiB
boot_size=$(stat -c%s "$STAGE/boot.img")
if [ "$boot_size" -gt 67108864 ]; then
  echo "ERROR: boot-lz4.img too large: $boot_size > 67108864"
  exit 2
fi

# 3) Copy required dist images into STAGE
cp "$DIST/init_boot.img" "$STAGE/"
cp "$DIST/vendor_boot.img" "$STAGE/"
cp "$DIST/super_unsparsed.img" "$STAGE/super.img"

# 4) Prebuilt images from arguments; warn and continue if missing
if [ -n "$PREBUILTS_DIR" ]; then
  ESP_IMG="$PREBUILTS_DIR/esp.img"
  NON_HLOS_IMG="$PREBUILTS_DIR/NON-HLOS.bin"
  BTFM_IMG="$PREBUILTS_DIR/BTFM.bin"
  DSPSO_IMG="$PREBUILTS_DIR/dspso.bin"
  PERSIST_IMG="$PREBUILTS_DIR/persist.img"
  PVMFW_IMG="$PREBUILTS_DIR/pvmfw.img"
else
  ESP_IMG=""
  NON_HLOS_IMG=""
  BTFM_IMG=""
  DSPSO_IMG=""
  PERSIST_IMG=""
  PVMFW_IMG=""
fi

copy_or_placeholder "$ESP_IMG" "$STAGE/esp.img" "esp.img" false
copy_or_placeholder "$NON_HLOS_IMG" "$STAGE/NON-HLOS.bin" "NON-HLOS.bin" true
copy_or_placeholder "$BTFM_IMG" "$STAGE/BTFM.bin" "BTFM.bin" true
copy_or_placeholder "$DSPSO_IMG" "$STAGE/dspso.bin" "dspso.bin" true

if [ -f "$PERSIST_IMG" ]; then
  cp "$PERSIST_IMG" "$STAGE/persist.img"
else
  if [ -z "$PERSIST_IMG" ]; then
    warn "persist.img path not provided; using zero-filled fallback."
  else
    warn "persist.img not found: $PERSIST_IMG; using zero-filled fallback."
  fi
  truncate -s 32M "$STAGE/persist.img"
fi

if [ -f "$PVMFW_IMG" ]; then
  cp "$PVMFW_IMG" "$STAGE/pvmfw.img"
else
  if [ -z "$PVMFW_IMG" ]; then
    warn "pvmfw.img path not provided; continuing without pvmfw."
  else
    warn "pvmfw.img not found: $PVMFW_IMG; continuing without pvmfw."
  fi
fi

# 5) Add AVB hash footers and build vbmeta.
#    boot-lz4.img already carries an AVB footer from the Bazel build; skip
#    re-adding it (which would corrupt it) and reuse its existing descriptor.
#    dtbo_a partition is 8 MiB; add footer so depthcharge can verify dtbo_a.
include_dtbo_descriptor=false
if [ -f "$STAGE/dtbo.img" ]; then
  dtbo_size=$(stat -c%s "$STAGE/dtbo.img")
  if [ "$dtbo_size" -gt 8388608 ]; then
    echo "ERROR: dtbo.img too large for dtbo_a (8MiB): $dtbo_size > 8388608"
    exit 2
  fi
  if add_hash_footer_none "$STAGE/dtbo.img" "dtbo" 8388608 true; then
    include_dtbo_descriptor=true
  fi
fi

if "$HOST/avbtool" info_image --image "$STAGE/boot.img" 2>/dev/null \
     | grep -q "Footer version"; then
  echo ">> boot.img already has an AVB footer; skipping add_hash_footer for boot"
else
  add_hash_footer_none "$STAGE/boot.img" "boot" 67108864 true
fi
add_hash_footer_none "$STAGE/init_boot.img"   "init_boot"   33554432  true
add_hash_footer_none "$STAGE/vendor_boot.img" "vendor_boot" 100663296 true

include_pvmfw_descriptor=false
if add_hash_footer_none "$STAGE/pvmfw.img" "pvmfw" 4194304 false; then
  include_pvmfw_descriptor=true
fi

# 6) Build vbmeta including dtbo hash descriptor so depthcharge AVB
#    verification of dtbo_a passes.
vbmeta_cmd=(
  make_vbmeta_image
  --output "$STAGE/vbmeta.img"
  --algorithm NONE
  --include_descriptors_from_image "$STAGE/boot.img"
  --include_descriptors_from_image "$STAGE/init_boot.img"
  --include_descriptors_from_image "$STAGE/vendor_boot.img"
)
if [ "$include_pvmfw_descriptor" = "true" ]; then
  vbmeta_cmd+=(--include_descriptors_from_image "$STAGE/pvmfw.img")
fi
if [ "$include_dtbo_descriptor" = "true" ]; then
  vbmeta_cmd+=(--include_descriptors_from_image "$STAGE/dtbo.img")
fi
"$HOST/avbtool" "${vbmeta_cmd[@]}"

# 7) Generate .bin
"$HOST/pack_image" --out_dir="$STAGE" --noarchive

# 7a) Write dtbo.img into dtbo_a.
#     pack_image does not have built-in dtbo write logic for this target;
#     write it explicitly using the sector offset from the GPT.
BIN="$STAGE/android-desktop_image.bin"
dtbo_sector=$(gpt_find_partition "$BIN" "dtbo_a" | awk '{print $1}')
if [ -z "$dtbo_sector" ]; then
  echo "ERROR: dtbo_a partition not found in generated bin."
  exit 3
fi
dd if="$STAGE/dtbo.img" of="$BIN" oflag=seek_bytes \
   seek=$((dtbo_sector * 512)) conv=notrunc status=none
echo "Written dtbo.img into dtbo_a at sector $dtbo_sector"

# 8) Post-build checks: partition count and kernel header format from boot_a
part_count=$(python3 - "$BIN" << 'PYEOF'
import struct, sys
with open(sys.argv[1], "rb") as f:
    f.seek(512)
    hdr = f.read(512)
    if hdr[:8] == b"EFI PART":
        print(struct.unpack_from("<I", hdr, 80)[0])
    else:
        print(0)
PYEOF
)

read -r boot_start boot_end < <(gpt_find_partition "$BIN" "boot_a")
if [ -z "${boot_start:-}" ] || [ -z "${boot_end:-}" ]; then
  echo "ERROR: boot_a partition not found in generated bin."
  exit 3
fi

boot_offset=$((boot_start * 512))
boot_part_size=$(((boot_end - boot_start + 1) * 512))
BOOT_A_IMG="$STAGE/boot_a.img"
dd if="$BIN" iflag=skip_bytes,count_bytes skip="$boot_offset" \
   count="$boot_part_size" status=none of="$BOOT_A_IMG"

boot_container_magic="$(xxd -p -l 8 "$BOOT_A_IMG")"
kernel_magic="N/A"
kernel_format="N/A"

if [ -x "$HOST/unpack_bootimg" ]; then
  BOOT_A_UNPACK_DIR="$STAGE/unpack_boot_a"
  rm -rf "$BOOT_A_UNPACK_DIR"
  mkdir -p "$BOOT_A_UNPACK_DIR"

  if "$HOST/unpack_bootimg" --boot_img "$BOOT_A_IMG" \
       --out "$BOOT_A_UNPACK_DIR" >/dev/null 2>&1; then
    if [ -f "$BOOT_A_UNPACK_DIR/kernel" ]; then
      kernel_magic="$(xxd -p -l 4 "$BOOT_A_UNPACK_DIR/kernel")"
      kernel_format="$(file -b "$BOOT_A_UNPACK_DIR/kernel")"
    else
      warn "unpack_bootimg succeeded but kernel payload not found."
    fi
  else
    warn "unpack_bootimg failed on boot_a payload."
  fi
else
  warn "$HOST/unpack_bootimg not found; skipped kernel payload format check."
fi

# 9) Show result in formatted summary
echo
printf '%s\n' "============================================================"
printf '%s\n' "                  android-desktop_image Summary             "
printf '%s\n' "============================================================"
printf 'Output Image         : %s\n' "$BIN"
printf 'Partition Count      : %s\n' "$part_count"
printf 'DTBO Image           : %s (%s bytes)\n' "$DTBO_NAME" "$(stat -c%s "$STAGE/dtbo.img")"
printf 'boot_a Container     : %s\n' "$boot_container_magic"
printf 'Kernel Magic         : %s\n' "$kernel_magic"
printf 'Kernel Header Format : %s\n' "$kernel_format"
printf '%s\n' "============================================================"
