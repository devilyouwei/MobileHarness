# App icon variants

Purpose: retain selectable app artwork outside the compiled asset catalog. Design goal: reversible icon selection without changing Xcode configuration.

- ✅ `original.png`: original robotic hand holding a phone with smiling blue eyes, preserved unchanged.
- ✅ `robot-camera.png`: white armored robot holding a landscape phone with its screen facing the viewer; top and sides have padding, lower body extends through the bottom edge.
- ✅ Both are opaque 1024 × 1024 PNGs. The selected copy lives in `../Assets.xcassets/AppIcon.appiconset/AppIcon.png` and is shared by both app targets.
- ❌ Runtime icon switching inside the app; selection currently requires a rebuild and installation.

From the repository root, select either version:

```sh
./scripts/select-app-icon.sh original
./scripts/select-app-icon.sh robot-camera
```

The script copies the selected variant into the active asset slot without changing either saved variant. The active version can be identified by comparing the asset with these files.

The new artwork was created with the built-in image generation tool. Final prompt direction: preserve the seasoned white-and-titanium robot, cyan eyes and navy background; enlarge the robot and phone together, retain small top and side margins, crop the lower torso at the bottom, and keep the horizontal phone screen facing the viewer. Exported to 1024 × 1024 for iOS.
