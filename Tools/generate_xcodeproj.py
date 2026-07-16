#!/usr/bin/env python3
"""Regenera el proyecto Xcode sin dependencias externas."""
from __future__ import annotations

import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE_ROOT = ROOT / "MiPatrimonio"
PROJECT_DIR = ROOT / "MiPatrimonio.xcodeproj"


def object_id(kind: str, key: str) -> str:
    return hashlib.sha1(f"{kind}:{key}".encode()).hexdigest()[:24].upper()


def setting_lines(settings: list[tuple[str, str]]) -> list[str]:
    lines = ["\t\t\tbuildSettings = {"]
    lines.extend(f"\t\t\t\t{key} = {value};" for key, value in settings)
    lines.append("\t\t\t};")
    return lines


def generate() -> None:
    PROJECT_DIR.mkdir(parents=True, exist_ok=True)
    swift_files = sorted(SOURCE_ROOT.rglob("*.swift"))
    info_plist = SOURCE_ROOT / "Resources" / "Info.plist"
    if not info_plist.exists():
        raise FileNotFoundError(info_plist)

    project_id = object_id("PBXProject", "project")
    target_id = object_id("PBXNativeTarget", "MiPatrimonio")
    product_ref_id = object_id("PBXFileReference", "MiPatrimonio.app")
    main_group_id = object_id("PBXGroup", "main")
    products_group_id = object_id("PBXGroup", "Products")
    sources_phase_id = object_id("PBXSourcesBuildPhase", "sources")
    frameworks_phase_id = object_id("PBXFrameworksBuildPhase", "frameworks")
    resources_phase_id = object_id("PBXResourcesBuildPhase", "resources")
    project_config_list_id = object_id("XCConfigurationList", "project")
    target_config_list_id = object_id("XCConfigurationList", "target")
    project_debug_id = object_id("XCBuildConfiguration", "project-debug")
    project_release_id = object_id("XCBuildConfiguration", "project-release")
    target_debug_id = object_id("XCBuildConfiguration", "target-debug")
    target_release_id = object_id("XCBuildConfiguration", "target-release")

    directories = [SOURCE_ROOT] + sorted(path for path in SOURCE_ROOT.rglob("*") if path.is_dir())
    group_ids = {path: object_id("PBXGroup", str(path.relative_to(ROOT))) for path in directories}
    source_files = swift_files + [info_plist]
    file_refs = {path: object_id("PBXFileReference", str(path.relative_to(ROOT))) for path in source_files}
    build_files = {path: object_id("PBXBuildFile", str(path.relative_to(ROOT))) for path in swift_files}

    lines: list[str] = []
    add = lines.append
    add("// !$*UTF8*$!")
    add("{")
    add("\tarchiveVersion = 1;")
    add("\tclasses = {};")
    add("\tobjectVersion = 56;")
    add("\tobjects = {")

    add("\n/* Begin PBXBuildFile section */")
    for path in swift_files:
        add(f"\t\t{build_files[path]} /* {path.name} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_refs[path]} /* {path.name} */; }};")
    add("/* End PBXBuildFile section */\n")

    add("/* Begin PBXFileReference section */")
    for path in swift_files:
        add(f"\t\t{file_refs[path]} /* {path.name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {path.name}; sourceTree = \"<group>\"; }};")
    add(f"\t\t{file_refs[info_plist]} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = \"<group>\"; }};")
    add(f"\t\t{product_ref_id} /* MiPatrimonio.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = MiPatrimonio.app; sourceTree = BUILT_PRODUCTS_DIR; }};")
    add("/* End PBXFileReference section */\n")

    add("/* Begin PBXFrameworksBuildPhase section */")
    add(f"\t\t{frameworks_phase_id} /* Frameworks */ = {{")
    add("\t\t\tisa = PBXFrameworksBuildPhase;")
    add("\t\t\tbuildActionMask = 2147483647;")
    add("\t\t\tfiles = ();")
    add("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    add("\t\t};")
    add("/* End PBXFrameworksBuildPhase section */\n")

    add("/* Begin PBXGroup section */")
    add(f"\t\t{main_group_id} = {{")
    add("\t\t\tisa = PBXGroup;")
    add("\t\t\tchildren = (")
    add(f"\t\t\t\t{group_ids[SOURCE_ROOT]} /* MiPatrimonio */,")
    add(f"\t\t\t\t{products_group_id} /* Products */,")
    add("\t\t\t);")
    add("\t\t\tsourceTree = \"<group>\";")
    add("\t\t};")
    add(f"\t\t{products_group_id} /* Products */ = {{")
    add("\t\t\tisa = PBXGroup;")
    add("\t\t\tchildren = (")
    add(f"\t\t\t\t{product_ref_id} /* MiPatrimonio.app */,")
    add("\t\t\t);")
    add("\t\t\tname = Products;")
    add("\t\t\tsourceTree = \"<group>\";")
    add("\t\t};")

    for directory in directories:
        add(f"\t\t{group_ids[directory]} /* {directory.name} */ = {{")
        add("\t\t\tisa = PBXGroup;")
        add("\t\t\tchildren = (")
        for child in sorted((path for path in directories if path.parent == directory), key=lambda item: item.name):
            add(f"\t\t\t\t{group_ids[child]} /* {child.name} */,")
        for child in sorted((path for path in source_files if path.parent == directory), key=lambda item: item.name):
            add(f"\t\t\t\t{file_refs[child]} /* {child.name} */,")
        add("\t\t\t);")
        add(f"\t\t\tpath = {'MiPatrimonio' if directory == SOURCE_ROOT else directory.name};")
        add("\t\t\tsourceTree = \"<group>\";")
        add("\t\t};")
    add("/* End PBXGroup section */\n")

    add("/* Begin PBXNativeTarget section */")
    add(f"\t\t{target_id} /* MiPatrimonio */ = {{")
    add("\t\t\tisa = PBXNativeTarget;")
    add(f"\t\t\tbuildConfigurationList = {target_config_list_id} /* Build configuration list for PBXNativeTarget \"MiPatrimonio\" */;")
    add("\t\t\tbuildPhases = (")
    add(f"\t\t\t\t{sources_phase_id} /* Sources */,")
    add(f"\t\t\t\t{frameworks_phase_id} /* Frameworks */,")
    add(f"\t\t\t\t{resources_phase_id} /* Resources */,")
    add("\t\t\t);")
    add("\t\t\tbuildRules = ();")
    add("\t\t\tdependencies = ();")
    add("\t\t\tname = MiPatrimonio;")
    add("\t\t\tpackageProductDependencies = ();")
    add("\t\t\tproductName = MiPatrimonio;")
    add(f"\t\t\tproductReference = {product_ref_id} /* MiPatrimonio.app */;")
    add("\t\t\tproductType = \"com.apple.product-type.application\";")
    add("\t\t};")
    add("/* End PBXNativeTarget section */\n")

    add("/* Begin PBXProject section */")
    add(f"\t\t{project_id} /* Project object */ = {{")
    add("\t\t\tisa = PBXProject;")
    add("\t\t\tattributes = {")
    add("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
    add("\t\t\t\tLastSwiftUpdateCheck = 1600;")
    add("\t\t\t\tLastUpgradeCheck = 1600;")
    add("\t\t\t\tTargetAttributes = {")
    add(f"\t\t\t\t\t{target_id} = {{ CreatedOnToolsVersion = 16.0; }};")
    add("\t\t\t\t};")
    add("\t\t\t};")
    add(f"\t\t\tbuildConfigurationList = {project_config_list_id} /* Build configuration list for PBXProject \"MiPatrimonio\" */;")
    add("\t\t\tcompatibilityVersion = \"Xcode 14.0\";")
    add("\t\t\tdevelopmentRegion = es;")
    add("\t\t\thasScannedForEncodings = 0;")
    add("\t\t\tknownRegions = (es, en, Base);")
    add(f"\t\t\tmainGroup = {main_group_id};")
    add(f"\t\t\tproductRefGroup = {products_group_id} /* Products */;")
    add("\t\t\tprojectDirPath = \"\";")
    add("\t\t\tprojectRoot = \"\";")
    add(f"\t\t\ttargets = ({target_id} /* MiPatrimonio */);")
    add("\t\t};")
    add("/* End PBXProject section */\n")

    add("/* Begin PBXResourcesBuildPhase section */")
    add(f"\t\t{resources_phase_id} /* Resources */ = {{")
    add("\t\t\tisa = PBXResourcesBuildPhase;")
    add("\t\t\tbuildActionMask = 2147483647;")
    add("\t\t\tfiles = ();")
    add("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    add("\t\t};")
    add("/* End PBXResourcesBuildPhase section */\n")

    add("/* Begin PBXSourcesBuildPhase section */")
    add(f"\t\t{sources_phase_id} /* Sources */ = {{")
    add("\t\t\tisa = PBXSourcesBuildPhase;")
    add("\t\t\tbuildActionMask = 2147483647;")
    add("\t\t\tfiles = (")
    for path in swift_files:
        add(f"\t\t\t\t{build_files[path]} /* {path.name} in Sources */,")
    add("\t\t\t);")
    add("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    add("\t\t};")
    add("/* End PBXSourcesBuildPhase section */\n")

    project_common = [
        ("ALWAYS_SEARCH_USER_PATHS", "NO"),
        ("CLANG_ANALYZER_NONNULL", "YES"),
        ("CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION", "YES_AGGRESSIVE"),
        ("CLANG_CXX_LANGUAGE_STANDARD", '"gnu++20"'),
        ("CLANG_ENABLE_MODULES", "YES"),
        ("CLANG_ENABLE_OBJC_ARC", "YES"),
        ("CLANG_ENABLE_OBJC_WEAK", "YES"),
        ("CLANG_WARN_BOOL_CONVERSION", "YES"),
        ("CLANG_WARN_COMMA", "YES"),
        ("CLANG_WARN_CONSTANT_CONVERSION", "YES"),
        ("CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS", "YES"),
        ("CLANG_WARN_DIRECT_OBJC_ISA_USAGE", "YES_ERROR"),
        ("CLANG_WARN_EMPTY_BODY", "YES"),
        ("CLANG_WARN_ENUM_CONVERSION", "YES"),
        ("CLANG_WARN_INFINITE_RECURSION", "YES"),
        ("CLANG_WARN_INT_CONVERSION", "YES"),
        ("CLANG_WARN_OBJC_LITERAL_CONVERSION", "YES"),
        ("CLANG_WARN_OBJC_ROOT_CLASS", "YES_ERROR"),
        ("CLANG_WARN_RANGE_LOOP_ANALYSIS", "YES"),
        ("CLANG_WARN_STRICT_PROTOTYPES", "YES"),
        ("CLANG_WARN_SUSPICIOUS_MOVE", "YES"),
        ("CLANG_WARN_UNGUARDED_AVAILABILITY", "YES_AGGRESSIVE"),
        ("CLANG_WARN_UNREACHABLE_CODE", "YES"),
        ("COPY_PHASE_STRIP", "NO"),
        ("ENABLE_STRICT_OBJC_MSGSEND", "YES"),
        ("ENABLE_USER_SCRIPT_SANDBOXING", "YES"),
        ("GCC_C_LANGUAGE_STANDARD", "gnu17"),
        ("GCC_NO_COMMON_BLOCKS", "YES"),
        ("GCC_WARN_64_TO_32_BIT_CONVERSION", "YES"),
        ("GCC_WARN_ABOUT_RETURN_TYPE", "YES_ERROR"),
        ("GCC_WARN_UNDECLARED_SELECTOR", "YES"),
        ("GCC_WARN_UNINITIALIZED_AUTOS", "YES_AGGRESSIVE"),
        ("GCC_WARN_UNUSED_FUNCTION", "YES"),
        ("GCC_WARN_UNUSED_VARIABLE", "YES"),
        ("IPHONEOS_DEPLOYMENT_TARGET", "17.0"),
        ("SDKROOT", "iphoneos"),
    ]
    target_common = [
        ("CODE_SIGN_STYLE", "Automatic"),
        ("CURRENT_PROJECT_VERSION", "2"),
        ("DEVELOPMENT_TEAM", '""'),
        ("ENABLE_PREVIEWS", "YES"),
        ("GENERATE_INFOPLIST_FILE", "NO"),
        ("INFOPLIST_FILE", "MiPatrimonio/Resources/Info.plist"),
        ("IPHONEOS_DEPLOYMENT_TARGET", "17.0"),
        ("LD_RUNPATH_SEARCH_PATHS", '"$(inherited) @executable_path/Frameworks"'),
        ("MARKETING_VERSION", "0.2.0"),
        ("PRODUCT_BUNDLE_IDENTIFIER", "com.example.MiPatrimonio"),
        ("PRODUCT_NAME", '"$(TARGET_NAME)"'),
        ("SUPPORTED_PLATFORMS", '"iphoneos iphonesimulator"'),
        ("SUPPORTS_MACCATALYST", "NO"),
        ("SWIFT_EMIT_LOC_STRINGS", "YES"),
        ("SWIFT_STRICT_CONCURRENCY", "targeted"),
        ("SWIFT_VERSION", "5.0"),
        ("TARGETED_DEVICE_FAMILY", "1"),
    ]

    configurations = [
        (project_debug_id, "Debug", project_common + [
            ("DEBUG_INFORMATION_FORMAT", "dwarf"),
            ("ENABLE_TESTABILITY", "YES"),
            ("GCC_OPTIMIZATION_LEVEL", "0"),
            ("GCC_PREPROCESSOR_DEFINITIONS", '("DEBUG=1", "$(inherited)")'),
            ("MTL_ENABLE_DEBUG_INFO", "INCLUDE_SOURCE"),
            ("ONLY_ACTIVE_ARCH", "YES"),
            ("SWIFT_ACTIVE_COMPILATION_CONDITIONS", '"DEBUG $(inherited)"'),
            ("SWIFT_OPTIMIZATION_LEVEL", '"-Onone"'),
        ]),
        (project_release_id, "Release", project_common + [
            ("DEBUG_INFORMATION_FORMAT", '"dwarf-with-dsym"'),
            ("ENABLE_NS_ASSERTIONS", "NO"),
            ("MTL_ENABLE_DEBUG_INFO", "NO"),
            ("SWIFT_COMPILATION_MODE", "wholemodule"),
            ("VALIDATE_PRODUCT", "YES"),
        ]),
        (target_debug_id, "Debug", target_common),
        (target_release_id, "Release", target_common),
    ]

    add("/* Begin XCBuildConfiguration section */")
    for config_id, name, settings in configurations:
        add(f"\t\t{config_id} /* {name} */ = {{")
        add("\t\t\tisa = XCBuildConfiguration;")
        lines.extend(setting_lines(settings))
        add(f"\t\t\tname = {name};")
        add("\t\t};")
    add("/* End XCBuildConfiguration section */\n")

    add("/* Begin XCConfigurationList section */")
    add(f"\t\t{project_config_list_id} /* Build configuration list for PBXProject \"MiPatrimonio\" */ = {{")
    add("\t\t\tisa = XCConfigurationList;")
    add(f"\t\t\tbuildConfigurations = ({project_debug_id} /* Debug */, {project_release_id} /* Release */);")
    add("\t\t\tdefaultConfigurationIsVisible = 0;")
    add("\t\t\tdefaultConfigurationName = Release;")
    add("\t\t};")
    add(f"\t\t{target_config_list_id} /* Build configuration list for PBXNativeTarget \"MiPatrimonio\" */ = {{")
    add("\t\t\tisa = XCConfigurationList;")
    add(f"\t\t\tbuildConfigurations = ({target_debug_id} /* Debug */, {target_release_id} /* Release */);")
    add("\t\t\tdefaultConfigurationIsVisible = 0;")
    add("\t\t\tdefaultConfigurationName = Release;")
    add("\t\t};")
    add("/* End XCConfigurationList section */")
    add("\t};")
    add(f"\trootObject = {project_id} /* Project object */;")
    add("}")

    (PROJECT_DIR / "project.pbxproj").write_text("\n".join(lines) + "\n")

    workspace = PROJECT_DIR / "project.xcworkspace"
    workspace.mkdir(exist_ok=True)
    (workspace / "contents.xcworkspacedata").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<Workspace version="1.0">\n'
        '   <FileRef location="self:">\n'
        '   </FileRef>\n'
        '</Workspace>\n'
    )

    schemes = PROJECT_DIR / "xcshareddata" / "xcschemes"
    schemes.mkdir(parents=True, exist_ok=True)
    (schemes / "MiPatrimonio.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.7">
   <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
            <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target_id}" BuildableName="MiPatrimonio.app" BlueprintName="MiPatrimonio" ReferencedContainer="container:MiPatrimonio.xcodeproj"/>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables/></TestAction>
   <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
      <BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target_id}" BuildableName="MiPatrimonio.app" BlueprintName="MiPatrimonio" ReferencedContainer="container:MiPatrimonio.xcodeproj"/></BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES">
      <BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target_id}" BuildableName="MiPatrimonio.app" BlueprintName="MiPatrimonio" ReferencedContainer="container:MiPatrimonio.xcodeproj"/></BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration="Debug"/>
   <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
    print(f"Generated {PROJECT_DIR / 'project.pbxproj'} with {len(swift_files)} Swift files")


if __name__ == "__main__":
    generate()
