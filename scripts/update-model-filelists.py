#!/usr/bin/env python3
"""Regenerate Xcode sandbox inputs/outputs for metadata-only model packaging."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
profiles = ["nemotron", "gemma4-e2b", "silero", "moss-tts-nano", "yolo26-pose"]
licenses = [
    "Nemotron-OpenMDW-1.1", "CoreAIKit-BSD-3-Clause", "Gemma4-Apache-2.0", "CoreAIModels-BSD-3-Clause",
    "Silero-MIT", "Hugging-Mac-MIT", "MOSS-TTS-Nano-Apache-2.0", "FluidAudio-Apache-2.0", "YOLOPose-AGPL-3.0",
]
for platform in ["iphoneos", "iphonesimulator"]:
    inputs = ["$(SRCROOT)/scripts/stage-voice-models.sh"]
    outputs = {"$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/Models"}
    files = []
    files = [("MobileHarness/Resources/Models/model-catalog.json", "model-catalog.json")]
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
