# AppIcon

Purpose: primary iOS app icon. Design goal: display the selected phone-and-robot artwork against a full-bleed dark background, with system-applied corners.

- ✅ 1024 × 1024 PNG, square corners, opaque background; universal iOS asset slot.
- ✅ White armored robot holding a phone screen toward the viewer; small top/side padding and natural bottom cropping. Original and new artwork remain available in [AppIconVariants](../../AppIconVariants/README.md).
- ❌ Home-screen visual verification on physical devices.

Use `./scripts/select-app-icon.sh original` or `./scripts/select-app-icon.sh robot-camera` from the repository root, then rebuild and install. Selection replaces only the active PNG. Generation provenance is recorded with the saved variants.
