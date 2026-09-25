"""Generate a temporary evaluation project; never edits the production project.
Requires scripts/download-qwen35.py artifacts and existing local app signing.
Installs with the existing app ID; reinstall the normal app after testing.
"""
from pathlib import Path
import json
import subprocess
import sys
root = Path(__file__).resolve().parents[2]
out = Path(__file__).resolve().parent
p=json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(root/'MobileHarness.xcodeproj/project.pbxproj')]));o=p['objects'];r=o[p['rootObject']];r['projectDirPath']=str(root);r['targets']=['0E8A3AD980EC179856012B7E']
o['BCE16DD0260827ECF338C787']['files']=['DE4D08C8782EBD48948DE548']
ref=o['DE4D08C8782EBD48948DE548']['fileRef'];o[ref]['path']=str(out/'Qwen35Probe.swift');o[ref]['sourceTree']='<absolute>'
o['0189424A5A60FED329FA868E']['files']=[]
phase=o['F92F8933D7644FCD9D016517'];phase['inputFileListPaths']=[];phase['outputFileListPaths']=[];phase['name']='Stage Qwen3.5 evaluation model';phase['shellScript']='set -eu\nrm -rf "${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/Models/Qwen35"\nmkdir -p "${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/Models/Qwen35"\nditto "${SRCROOT}/MobileHarness/Resources/Models/artifacts/qwen3.5-2b-mlx/674aaa7240b91e8012fcad5d791b7dfe5ba90207/mlx" "${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/Models/Qwen35/mlx"\ncp "${SRCROOT}/MobileHarness/Resources/Models/qwen3.5-2b-mlx.manifest.json" "${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/Models/Qwen35/"\n'
o['A01300000000000000000002']['productName']='ModelKitQwen35'
for v in o.values():
 if v.get('isa')=='XCLocalSwiftPackageReference': v['relativePath']=str(root/v['relativePath'])
 if v.get('isa')=='XCBuildConfiguration':
  b=v.get('buildSettings',{});b['PRODUCT_BUNDLE_IDENTIFIER']='dev.mobileharness.app';b['INFOPLIST_KEY_CFBundleDisplayName']='Qwen Evaluation';b['ENABLE_USER_SCRIPT_SANDBOXING']='NO'
if '--four-b' in sys.argv:
 phase['shellScript']=phase['shellScript'].replace('qwen3.5-2b-mlx','qwen3.5-4b-mlx').replace('674aaa7240b91e8012fcad5d791b7dfe5ba90207','0e7ffd5c629ef7719d4cbc04069232580bfa9d9c')
proj=Path('/tmp/Qwen35Probe.xcodeproj');proj.mkdir(exist_ok=True);(proj/'project.pbxproj').write_text(json.dumps(p))
