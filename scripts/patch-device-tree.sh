#!/usr/bin/env bash
set -euo pipefail

TREE="${1:?Usage: patch-device-tree.sh /path/to/device/samsung/a52xq}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! -f "$TREE/BoardConfig.mk" ]]; then
  echo "ERROR: $TREE does not look like the a52xq recovery device tree." >&2
  exit 1
fi

# Copy the exact MicroSD and USB-OTG configuration extracted from the user's
# known-working OrangeFox R11.3 recovery image.
mkdir -p "$TREE/recovery/root"
cp -a "$ROOT_DIR/overlay/recovery/root/." "$TREE/recovery/root/"
chmod 0755 "$TREE/recovery/root/sbin/of_sdcard_mount.sh"
chmod 0644 "$TREE/recovery/root/init.of_sdcard.rc"
chmod 0644 "$TREE/recovery/root/system/etc/twrp.flags"

# Import the MicroSD helper from an existing device-specific init file. This
# avoids replacing OrangeFox's generated main init.rc with an older R11.3 copy.
QCOM_RC="$TREE/recovery/root/init.recovery.qcom.rc"
if [[ ! -f "$QCOM_RC" ]]; then
  echo "ERROR: Missing $QCOM_RC" >&2
  exit 1
fi
if ! grep -q '^import /init\.of_sdcard\.rc$' "$QCOM_RC"; then
  tmp="$(mktemp)"
  awk '
    BEGIN { inserted=0 }
    /^import / && inserted==0 {
      print "import /init.of_sdcard.rc"
      inserted=1
    }
    { print }
    END {
      if (inserted==0) print "import /init.of_sdcard.rc"
    }
  ' "$QCOM_RC" > "$tmp"
  mv "$tmp" "$QCOM_RC"
fi

# Preserve the OTG properties used by the working recovery.
PROP="$TREE/system.prop"
touch "$PROP"
for line in \
  'persist.sys.isUsbOtgEnabled=true' \
  'persist.sys.oem.otg_support=true'
do
  key="${line%%=*}"
  if grep -qE "^${key//./\.}=" "$PROP"; then
    sed -i -E "s|^${key//./\.}=.*$|$line|" "$PROP"
  else
    printf '\n%s\n' "$line" >> "$PROP"
  fi
done

# Add only build-time settings that are appropriate for this non-A/B Samsung
# device with a prebuilt kernel and a dedicated recovery partition.
VENDORSETUP="$TREE/vendorsetup.sh"
touch "$VENDORSETUP"
append_export() {
  local key="$1" value="$2"
  if grep -qE "^[[:space:]]*export[[:space:]]+$key=" "$VENDORSETUP"; then
    sed -i -E "s|^[[:space:]]*export[[:space:]]+$key=.*$|export $key=\"$value\"|" "$VENDORSETUP"
  else
    printf 'export %s="%s"\n' "$key" "$value" >> "$VENDORSETUP"
  fi
}
append_export OF_FORCE_PREBUILT_KERNEL 1
append_export FOX_MAINTAINER_PATCH_VERSION 1
append_export FOX_VARIANT a52xq-fixed

# Sanity checks that fail the build early if the working fixes disappeared.
grep -q 'OrangeFox a52xq unified microSD pre-mount helper v2' \
  "$TREE/recovery/root/init.of_sdcard.rc"
grep -q 'OrangeFox a52xq unified SD mount helper v2' \
  "$TREE/recovery/root/sbin/of_sdcard_mount.sh"
grep -q 'xhci-hcd\.\*\.auto\* /usb_otg auto' \
  "$TREE/recovery/root/system/etc/twrp.flags"
grep -q '^import /init\.of_sdcard\.rc$' "$QCOM_RC"
grep -q '^persist\.sys\.isUsbOtgEnabled=true$' "$PROP"
grep -q '^persist\.sys\.oem\.otg_support=true$' "$PROP"

echo "Patched a52xq tree successfully."
