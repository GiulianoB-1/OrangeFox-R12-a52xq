#!/usr/bin/env bash
set -euo pipefail

FOX_DIR="${1:?usage: patch-apex-loop.sh <orangefox-source-root>}"
APEX_CPP="$FOX_DIR/bootable/recovery/twrpApex.cpp"

if [[ ! -f "$APEX_CPP" ]]; then
  echo "ERROR: cannot find $APEX_CPP" >&2
  exit 1
fi

python3 - "$APEX_CPP" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
original = text

# 1. A successful APEX setup can survive a recovery/UI reinitialization.
# Do not attach the same APEX payloads to loop devices a second time.
needle = '''bool twrpApex::loadApexImages() {
	std::vector<std::string> apexFiles;
'''
replacement = '''bool twrpApex::loadApexImages() {
	if (android::base::GetProperty("twrp.apex.loaded", "false") == "true") {
		LOGINFO("APEX images are already loaded; reusing existing mounts\\n");
		return true;
	}

	std::vector<std::string> apexFiles;
'''
if needle in text:
    text = text.replace(needle, replacement, 1)
elif 'APEX images are already loaded; reusing existing mounts' not in text:
    raise SystemExit("ERROR: loadApexImages() layout changed; refusing an unsafe patch")

# 2. LOOP_CTL_GET_FREE returns the loop number that must actually be used.
text = text.replace(
    'makedev(7, device_no)',
    'makedev(7, num)'
)
text = text.replace(
    'bool load_result = loadApexImage(fileToMount, device_no);',
    'bool load_result = loadApexImage(fileToMount, num);'
)

# device_no is no longer valid state. Remove the counter and increment.
text = text.replace('\tsize_t device_no = 0;\n', '')
text = text.replace('\t\tdevice_no++;\n', '')

# 3. The original code closes fd and then calls lseek(fd,...), which yields
# -1 and becomes UINT64_MAX in lo_sizelimit. Determine the size first.
old = '''	close(fd);

	memset(&info, 0, sizeof(struct loop_info64));
	strlcpy((char*)info.lo_crypt_name, "twrpApex", LO_NAME_SIZE);
	off_t apex_size = lseek(fd, 0, SEEK_END);
	info.lo_sizelimit = apex_size;
'''
new = '''	off_t apex_size = lseek(fd, 0, SEEK_END);
	if (apex_size < 0) {
		LOGERR("unable to determine apex image size for %s. Reason: %s\\n",
			fileToMount.c_str(), strerror(errno));
		ioctl(loop_fd, LOOP_CLR_FD, 0);
		close(fd);
		close(loop_fd);
		return false;
	}

	close(fd);

	memset(&info, 0, sizeof(struct loop_info64));
	strlcpy((char*)info.lo_crypt_name, "twrpApex", LO_NAME_SIZE);
	info.lo_sizelimit = apex_size;
'''
if old in text:
    text = text.replace(old, new, 1)
elif 'unable to determine apex image size' not in text:
    raise SystemExit("ERROR: loadApexImage() size block changed; refusing an unsafe patch")

# Keep twrp.apex.loaded coherent when TWRP explicitly tears APEX down.
old_unmount = '''bool twrpApex::Unmount() {
	return (PartitionManager.UnMount_By_Path(APEX_BASE, false, MNT_DETACH) == 0);
}
'''
new_unmount = '''bool twrpApex::Unmount() {
	bool result = (PartitionManager.UnMount_By_Path(APEX_BASE, false, MNT_DETACH) == 0);
	if (result) {
		android::base::SetProperty("twrp.apex.loaded", "false");
	}
	return result;
}
'''
if old_unmount in text:
    text = text.replace(old_unmount, new_unmount, 1)
elif 'android::base::SetProperty("twrp.apex.loaded", "false")' not in text:
    raise SystemExit("ERROR: Unmount() layout changed; refusing an unsafe patch")

required = [
    'loadApexImage(fileToMount, num)',
    'makedev(7, num)',
    'off_t apex_size = lseek(fd, 0, SEEK_END);',
    'APEX images are already loaded; reusing existing mounts',
]
for token in required:
    if token not in text:
        raise SystemExit(f"ERROR: expected patched token is missing: {token}")

bad = [
    'loadApexImage(fileToMount, device_no)',
    'makedev(7, device_no)',
]
for token in bad:
    if token in text:
        raise SystemExit(f"ERROR: stale buggy token remains: {token}")

if text != original:
    path.write_text(text)
    print(f"Patched {path}")
else:
    print(f"{path} already contains the APEX loop fixes")
PY

echo "----- APEX patch verification -----"
grep -nE 'already loaded|LOOP_CTL_GET_FREE|makedev\(7, num\)|loadApexImage\(fileToMount, num\)|apex_size|twrp\.apex\.loaded' "$APEX_CPP"
