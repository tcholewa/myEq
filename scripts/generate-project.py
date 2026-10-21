#!/usr/bin/env python3
"""Generate the small Xcode app wrapper around the local MyEqCore package."""
from pathlib import Path
import hashlib

root = Path(__file__).resolve().parent.parent
objects = {}

def ident(name):
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()

def add(name, value):
    objects[ident(name)] = value
    return ident(name)

files = sorted((root / 'Sources/MyEqApp').glob('*.swift'))
refs = [add(str(p.name), f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {p.name}; sourceTree = "<group>";') for p in files]
builds = [add('build'+r, f'isa = PBXBuildFile; fileRef = {r};') for r in refs]
product = add('product', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = myEq.app; sourceTree = BUILT_PRODUCTS_DIR;')
sourcegroup = add('sources', 'isa = PBXGroup; path = Sources/MyEqApp; sourceTree = "<group>"; children = (' + ','.join(refs) + ');')
productgroup = add('products', f'isa = PBXGroup; name = Products; sourceTree = "<group>"; children = ({product});')
group = add('rootgroup', f'isa = PBXGroup; sourceTree = "<group>"; children = ({sourcegroup},{productgroup});')
package = add('package', 'isa = XCLocalSwiftPackageReference; relativePath = .;')
dependency = add('core', f'isa = XCSwiftPackageProductDependency; package = {package}; productName = MyEqCore;')
framework = add('framework', f'isa = PBXBuildFile; productRef = {dependency};')
sources = add('sourcephase', 'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (' + ','.join(builds) + '); runOnlyForDeploymentPostprocessing = 0;')
frameworks = add('frameworkphase', f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({framework}); runOnlyForDeploymentPostprocessing = 0;')
resources = add('resourcephase', 'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
configs = []
for mode in ['Debug','Release']:
    configs.append(add('config'+mode, '''isa = XCBuildConfiguration; name = %s; buildSettings = {
        PRODUCT_NAME = myEq;
        PRODUCT_BUNDLE_IDENTIFIER = com.tc.myEq;
        SDKROOT = macosx;
        ALWAYS_SEARCH_USER_PATHS = NO;
        MACOSX_DEPLOYMENT_TARGET = 27.0;
        ARCHS = arm64;
        SWIFT_VERSION = 5.0;
        SWIFT_OPTIMIZATION_LEVEL = "%s";
        CLANG_CXX_LANGUAGE_STANDARD = "c++17";
        INFOPLIST_FILE = Resources/Info.plist;
        GENERATE_INFOPLIST_FILE = NO;
        CODE_SIGN_IDENTITY = "-";
        CODE_SIGN_STYLE = Manual;
        ENABLE_APP_SANDBOX = NO;
        ENABLE_HARDENED_RUNTIME = YES;
        LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/../Frameworks";
    };''' % (mode, '-Onone' if mode == 'Debug' else '-O')))
configlist = add('configlist', 'isa = XCConfigurationList; buildConfigurations = ('+','.join(configs)+'); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
target = add('target', f'isa = PBXNativeTarget; buildConfigurationList = {configlist}; buildPhases = ({sources},{frameworks},{resources}); buildRules = (); dependencies = (); name = myEq; packageProductDependencies = ({dependency}); productName = myEq; productReference = {product}; productType = "com.apple.product-type.application";')
project = add('project', f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 2700; }}; buildConfigurationList = {configlist}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; knownRegions = (en,Base); mainGroup = {group}; productRefGroup = {productgroup}; projectDirPath = ""; projectRoot = ""; packageReferences = ({package}); targets = ({target});')
body = '// !$*UTF8*$!\n{\n archiveVersion = 1; classes = {}; objectVersion = 60;\n objects = {\n'
body += '\n'.join(f'{key} = {{ {value} }};' for key,value in objects.items())
body += f'\n }};\n rootObject = {project};\n}}\n'
(root/'myEq.xcodeproj/project.pbxproj').write_text(body)
scheme = root/'myEq.xcodeproj/xcshareddata/xcschemes/myEq.xcscheme'
scheme.parent.mkdir(parents=True,exist_ok=True)
ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="myEq.app" BlueprintName="myEq" ReferencedContainer="container:myEq.xcodeproj"/>'
scheme.write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="NO"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/>
 <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
