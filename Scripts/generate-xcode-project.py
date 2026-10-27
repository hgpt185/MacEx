#!/usr/bin/env python3
"""Generate the thin Xcode app/UI-test host; MacExCore stays in the local package."""
from pathlib import Path
import hashlib
import json
import plistlib

root = Path(__file__).resolve().parent.parent
objects = {}
def uid(value):
    return hashlib.sha1(value.encode()).hexdigest()[:24].upper()
def q(value):
    return json.dumps(str(value))
def add(key, body):
    objects[uid(key)] = body
    return uid(key)
def array(values):
    return "(" + ", ".join(values) + ")"
def configs(name, settings):
    ids = []
    for mode in ("Debug", "Release"):
        values = dict(settings)
        values.update({"SWIFT_OPTIMIZATION_LEVEL": "-Onone" if mode == "Debug" else "-O",
                       "ONLY_ACTIVE_ARCH": "YES" if mode == "Debug" else "NO",
                       "ENABLE_HARDENED_RUNTIME": "NO" if mode == "Debug" else "YES"})
        ids.append(add(name + mode, "isa = XCBuildConfiguration; name = " + mode + "; buildSettings = {" +
                       " ".join(q(k) + " = " + q(v) + ";" for k, v in values.items()) + "};"))
    return add(name + "Configurations", "isa = XCConfigurationList; buildConfigurations = " + array(ids) + "; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")

source_builds, source_refs = [], []
for source in sorted((root / "Sources/MacEx").glob("*.swift")):
    relative = source.relative_to(root).as_posix()
    ref = add(relative, "isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = " + q(relative) + "; sourceTree = SOURCE_ROOT;")
    source_refs.append(ref)
    source_builds.append(add(relative + "Build", "isa = PBXBuildFile; fileRef = " + ref + ";"))
test_path = "Tests/UITests/MacExUITests.swift"
test_ref = add(test_path, "isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = " + q(test_path) + "; sourceTree = SOURCE_ROOT;")
test_build = add("UITestBuild", "isa = PBXBuildFile; fileRef = " + test_ref + ";")
app_product = add("AppProduct", "isa = PBXFileReference; explicitFileType = wrapper.application; path = MacEx.app; sourceTree = BUILT_PRODUCTS_DIR;")
test_product = add("TestProduct", "isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = MacExUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR;")
app_group = add("AppGroup", "isa = PBXGroup; name = App; children = " + array(source_refs) + "; sourceTree = \"<group>\";")
test_group = add("TestGroup", "isa = PBXGroup; name = UITests; children = " + array([test_ref]) + "; sourceTree = \"<group>\";")
product_group = add("Products", "isa = PBXGroup; name = Products; children = " + array([app_product, test_product]) + "; sourceTree = \"<group>\";")
main_group = add("MainGroup", "isa = PBXGroup; children = " + array([app_group, test_group, product_group]) + "; sourceTree = \"<group>\";")
local_package = add("Package", 'isa = XCLocalSwiftPackageReference; relativePath = ".";')
library = add("CoreProduct", "isa = XCSwiftPackageProductDependency; package = " + local_package + "; productName = MacExCore;")
library_build = add("CoreBuild", "isa = PBXBuildFile; productRef = " + library + ";")
app_sources = add("AppSources", "isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = " + array(source_builds) + "; runOnlyForDeploymentPostprocessing = 0;")
app_frameworks = add("AppFrameworks", "isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = " + array([library_build]) + "; runOnlyForDeploymentPostprocessing = 0;")
test_sources = add("TestSources", "isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = " + array([test_build]) + "; runOnlyForDeploymentPostprocessing = 0;")
test_frameworks = add("TestFrameworks", "isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;")
common = {"SDKROOT": "macosx", "MACOSX_DEPLOYMENT_TARGET": "14.0", "SWIFT_VERSION": "6.0", "SWIFT_STRICT_CONCURRENCY": "complete", "CLANG_ENABLE_MODULES": "YES", "CODE_SIGN_IDENTITY": "-", "CODE_SIGN_STYLE": "Manual", "ENABLE_APP_SANDBOX": "NO"}
project_configs = configs("Project", common)
app_configs = configs("App", {"PRODUCT_NAME": "MacEx", "PRODUCT_MODULE_NAME": "$(MACEX_APP_MODULE)", "MACEX_APP_MODULE": "MacExUIHost", "PRODUCT_BUNDLE_IDENTIFIER": "local.macex.app.uihost", "INFOPLIST_FILE": "Resources/UIHost-Info.plist", "GENERATE_INFOPLIST_FILE": "NO", "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../Frameworks", "SWIFT_EMIT_LOC_STRINGS": "YES"})
test_configs = configs("UITest", {"PRODUCT_NAME": "MacExUITests", "PRODUCT_BUNDLE_IDENTIFIER": "local.macex.UITests", "GENERATE_INFOPLIST_FILE": "YES", "TEST_TARGET_NAME": "MacExUIHost"})
proxy = add("TestProxy", "isa = PBXContainerItemProxy; containerPortal = " + uid("Project") + "; proxyType = 1; remoteGlobalIDString = " + uid("AppTarget") + "; remoteInfo = MacExUIHost;")
dependency = add("TestDependency", "isa = PBXTargetDependency; target = " + uid("AppTarget") + "; targetProxy = " + proxy + ";")
app_target = add("AppTarget", "isa = PBXNativeTarget; buildConfigurationList = " + app_configs + "; buildPhases = " + array([app_sources, app_frameworks]) + "; buildRules = (); dependencies = (); name = MacExUIHost; packageProductDependencies = " + array([library]) + "; productName = MacEx; productReference = " + app_product + '; productType = "com.apple.product-type.application";')
test_target = add("TestTarget", "isa = PBXNativeTarget; buildConfigurationList = " + test_configs + "; buildPhases = " + array([test_sources, test_frameworks]) + "; buildRules = (); dependencies = " + array([dependency]) + "; name = MacExUITests; productName = MacExUITests; productReference = " + test_product + '; productType = "com.apple.product-type.bundle.ui-testing";')
project = add("Project", "isa = PBXProject; attributes = { LastUpgradeCheck = 1600; TargetAttributes = { " + test_target + " = { TestTargetID = " + app_target + "; }; }; }; buildConfigurationList = " + project_configs + "; compatibilityVersion = \"Xcode 15.0\"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = " + main_group + "; productRefGroup = " + product_group + "; projectDirPath = \"\"; projectRoot = \"\"; packageReferences = " + array([local_package]) + "; targets = " + array([app_target, test_target]) + ";")
destination = root / "MacEx.xcodeproj"
info = plistlib.loads((root / "Resources/Info.plist").read_bytes())
info["CFBundleIdentifier"] = "local.macex.app.uihost"
info["CFBundleDisplayName"] = "MacEx UI Host"
(root / "Resources/UIHost-Info.plist").write_bytes(plistlib.dumps(info))
destination.mkdir(exist_ok=True)
(destination / "project.pbxproj").write_text("// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 60; objects = {\n" + "\n".join(key + " = { " + value + " };" for key, value in objects.items()) + "\n}; rootObject = " + project + "; }\n")
def buildable(target, product, name):
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{product}" BlueprintName="{name}" ReferencedContainer="container:MacEx.xcodeproj"/>'
app_ref = buildable(app_target, "MacEx.app", "MacExUIHost")
test_ref = buildable(test_target, "MacExUITests.xctest", "MacExUITests")
schemes = destination / "xcshareddata/xcschemes"
schemes.mkdir(parents=True, exist_ok=True)
(schemes / "MacEx.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
<BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{app_ref}</BuildActionEntry>
<BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO">{test_ref}</BuildActionEntry>
</BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{test_ref}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="NO"><BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print(destination)
