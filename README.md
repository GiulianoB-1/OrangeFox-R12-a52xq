# OrangeFox R12 builder for Samsung Galaxy A52 5G (`a52xq`)

This repository builds the current OrangeFox R12 recovery code from the
OrangeFox `12.1` manifest for the Samsung Galaxy A52 5G.

## Why the 12.1 manifest is used

OrangeFox's manifest number and OrangeFox's release number are different.
The `12.1` source is the recommended build system for devices like the A52 5G
that launched before Android 14. The latest R12 recovery code is included in
that source branch. Porting this phone to the `14.1` build system is not needed
for the initial R12 build and introduces extra risk.

## Device facts

- Hardware codename: `a52xq`
- Typical model: `SM-A526B`
- Partition scheme: non-A/B
- Recovery location: dedicated `recovery` partition
- Recovery partition size: `81,788,928` bytes

The custom ROM may spoof another model or codename. The build must still target
`a52xq`.

## Preserved fixes from the known-working recovery dump

The overlay contains the exact working configuration extracted from the user's
OrangeFox R11.3 recovery image:

- Dynamic MicroSD discovery and pre-mount helper
- Samsung `sdfat` support with FAT, NTFS and ext4 fallbacks
- Dynamic xHCI USB-OTG path instead of fixed `/dev/block/sdg1`
- Samsung OTG enable properties

The build verification step refuses to publish an artifact unless these fixes
are present inside the generated ramdisk and the recovery reports an R12
version.

## Build on GitHub

The initial build starts automatically when these files are pushed to `main`.
For later builds:

1. Open the repository's **Actions** tab.
2. Select **Build OrangeFox R12 for Galaxy A52 5G**.
3. Press **Run workflow**.
4. When it finishes, download the `OrangeFox-R12-a52xq-*` artifact.
5. Read `verification.txt` and verify that every check says `PASS` before any
   flashing attempt.

The source sync is large and GitHub Actions may occasionally fail because of a
network interruption. The uploaded build log is intended for troubleshooting.

## Do not flash immediately

This is an experimental first R12 build. Keep the known-working recovery dump
available for rollback. Before flashing, inspect the generated checksum,
verification report and image size. The first boot should be treated as a test,
and the phone should be rebooted directly back into recovery after flashing.

Do not use a build for `a52q`, `a52sxq`, `r0q`, or another Samsung device.

## Source and licensing

The workflow obtains the current OrangeFox sources and the public `a52xq`
device tree during the build. The local modifications are included in this
repository so the resulting build remains reproducible and the changes are
publicly available.
