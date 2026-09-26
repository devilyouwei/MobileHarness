#!/usr/bin/env python3
"""Regenerate Xcode sandbox inputs/outputs from production download profiles."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
profiles = ["nemotron", "qwen3.5-2b", "silero", "kokoro", "yolov8-pose"]
licenses = [
    "Nemotron-OpenMDW-1.1", "CoreAIKit-BSD-3-Clause", "Qwen35-Apache-2.0",
    "MLX-Swift-MIT", "MLX-Swift-LM-MIT", "Silero-MIT", "Hugging-Mac-MIT", "Kokoro-Apache-2.0", "YOLOPose-AGPL-3.0",
]
for platform in ["iphoneos", "iphonesimulator"]:
    inputs = ["$(SRCROOT)/scripts/stage-voice-models.sh"]
    outputs = {"$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/Models"}
    files = []
    if platform == "iphoneos":
        for name in profiles:
            profile = json.loads((ROOT / "MobileHarness/Resources/Models" / (name + ".download.json")).read_text())
            paths = profile.get("files") or profile["platforms"][profile["defaultPlatform"]]
            for path in paths:
                relative = profile["directory"] + "/" + path
                files.append(("MobileHarness/Resources/Models/" + relative, relative))
        files += [("docs/licenses/" + name + ".txt", "Licenses/" + name + ".txt") for name in licenses]
    for source, relative in files:
        inputs.append("$(SRCROOT)/" + source)
        destination = Path("$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/Models") / relative
        outputs.add(str(destination))
        while destination.parent.name != "Models":
            destination = destination.parent
            outputs.add(str(destination))
    config = ROOT / "Config" / ("Voice-Models-" + platform)
    Path(str(config) + "-Inputs.xcfilelist").write_text("\n".join(inputs) + "\n")
    Path(str(config) + "-Outputs.xcfilelist").write_text("\n".join(sorted(outputs)) + "\n")
