#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
: "${WRITER_SIMULATOR_ID:?Use an isolated simulator ID; this script seeds its app data.}"
: "${WRITER_SIMULATOR_SEED:?Use a completed synthetic evaluate-writer model output directory.}"
writer_ui_work="$(mktemp -d /tmp/mobileharness-writer-ui.XXXXXX)"
writer_ui_app="${MOBILEHARNESS_SIMULATOR_APP:-build/SimulatorDerivedData/Build/Products/Debug-iphonesimulator/MobileHarnessSimulator.app}"
xcrun simctl install "$WRITER_SIMULATOR_ID" "$writer_ui_app"
writer_ui_container="$(xcrun simctl get_app_container "$WRITER_SIMULATOR_ID" dev.mobileharness.app data)"
python3 - "$writer_ui_container" "$WRITER_SIMULATOR_SEED" <<'PY'
from pathlib import Path
import shutil,sqlite3,sys
container,seed=map(Path,sys.argv[1:])
root=container/'Library/Application Support/MobileHarness'
root.mkdir(parents=True,exist_ok=True)
if (root/'records.sqlite').exists():
    raise SystemExit('Refusing to replace an existing simulator database; use a fresh isolated simulator.')
with sqlite3.connect(f"file:{seed/'records.sqlite'}?mode=ro",uri=True) as source:
    with sqlite3.connect(root/'records.sqlite') as target:
        source.backup(target)
shutil.copytree(seed/'workspaces',root/'ArtifactWorkspaces',dirs_exist_ok=True)
shutil.copy2(seed/'workspace-index.json',root/'ArtifactWorkspaces/index.json')
PY
python3 - "$writer_ui_work" "$PWD/Tests/UITests/WriterRecordsNativeAcceptance.swift" <<'PY'
import sys
from pathlib import Path
work,source=map(Path,sys.argv[1:]);project=work/'WriterUI.xcodeproj';project.mkdir()
pbx='''// !$*UTF8*$!
{archiveVersion=1;classes={};objectVersion=56;objects={
A10000000000000000000001={isa=PBXProject;attributes={LastUpgradeCheck=2700;};buildConfigurationList=A10000000000000000000002;compatibilityVersion="Xcode 14.0";developmentRegion=en;knownRegions=(en,Base);mainGroup=A10000000000000000000003;productRefGroup=A10000000000000000000004;projectDirPath="";projectRoot="";targets=(A10000000000000000000005);};
A10000000000000000000002={isa=XCConfigurationList;buildConfigurations=(A10000000000000000000006);defaultConfigurationIsVisible=0;defaultConfigurationName=Debug;};
A10000000000000000000003={isa=PBXGroup;children=(A10000000000000000000007,A10000000000000000000004);sourceTree="<group>";};
A10000000000000000000004={isa=PBXGroup;children=(A10000000000000000000008);name=Products;sourceTree="<group>";};
A10000000000000000000005={isa=PBXNativeTarget;buildConfigurationList=A10000000000000000000009;buildPhases=(A1000000000000000000000A,A1000000000000000000000B);buildRules=();dependencies=();name=WriterUI;productName=WriterUI;productReference=A10000000000000000000008;productType="com.apple.product-type.bundle.ui-testing";};
A10000000000000000000006={isa=XCBuildConfiguration;buildSettings={SDKROOT=iphonesimulator;IPHONEOS_DEPLOYMENT_TARGET=27.0;};name=Debug;};
A10000000000000000000007={isa=PBXFileReference;lastKnownFileType=sourcecode.swift;path="SOURCE";sourceTree="<absolute>";};
A10000000000000000000008={isa=PBXFileReference;explicitFileType=wrapper.cfbundle;includeInIndex=0;path=WriterUI.xctest;sourceTree=BUILT_PRODUCTS_DIR;};
A10000000000000000000009={isa=XCConfigurationList;buildConfigurations=(A1000000000000000000000C);defaultConfigurationIsVisible=0;defaultConfigurationName=Debug;};
A1000000000000000000000A={isa=PBXSourcesBuildPhase;buildActionMask=2147483647;files=(A1000000000000000000000D);runOnlyForDeploymentPostprocessing=0;};
A1000000000000000000000B={isa=PBXFrameworksBuildPhase;buildActionMask=2147483647;files=();runOnlyForDeploymentPostprocessing=0;};
A1000000000000000000000C={isa=XCBuildConfiguration;buildSettings={PRODUCT_NAME="$(TARGET_NAME)";PRODUCT_BUNDLE_IDENTIFIER="dev.mobileharness.writer-ui";SWIFT_VERSION=6.0;GENERATE_INFOPLIST_FILE=YES;SWIFT_ACTIVE_COMPILATION_CONDITIONS=WRITER_UI_ACCEPTANCE;TARGETED_DEVICE_FAMILY="1,2";CODE_SIGNING_ALLOWED=NO;};name=Debug;};
A1000000000000000000000D={isa=PBXBuildFile;fileRef=A10000000000000000000007;};
};rootObject=A10000000000000000000001;}
'''.replace('SOURCE',str(source))
(project/'project.pbxproj').write_text(pbx)
schemes=project/'xcshareddata/xcschemes';schemes.mkdir(parents=True)
ref='<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="A10000000000000000000005" BuildableName="WriterUI.xctest" BlueprintName="WriterUI" ReferencedContainer="container:WriterUI.xcodeproj"/>'
(schemes/'WriterUI.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?><Scheme LastUpgradeVersion="2700" version="1.3"><BuildAction parallelizeBuildables="NO" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{ref}</TestableReference></Testables></TestAction></Scheme>''')
PY
xcodebuild -project "$writer_ui_work/WriterUI.xcodeproj" -scheme WriterUI -destination "platform=iOS Simulator,id=$WRITER_SIMULATOR_ID" -derivedDataPath "$writer_ui_work/DerivedData" -resultBundlePath "$writer_ui_work/WriterUI.xcresult" CODE_SIGNING_ALLOWED=NO test
printf 'Native Writer UI evidence: %s\n' "$writer_ui_work/WriterUI.xcresult"
