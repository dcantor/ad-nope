#!/usr/bin/env python3
"""Generates Blocker.xcodeproj/project.pbxproj.

The project uses synchronized folders, so adding source files never needs
this script. Re-run it only to change targets or build settings:

    python3 tools/gen_xcodeproj.py

Targets:
  Blocker               the Ad Nope app             iOS, iPadOS, macOS
  BlockerAds/Privacy/   content-blocker extensions  iOS, iPadOS, macOS
    Annoyances
  BlockerShare          Safari Share menu extension iOS, iPadOS
"""

import itertools
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "Blocker.xcodeproj" / "project.pbxproj"

counter = itertools.count(1)
objs: dict[str, list] = {}


def oid():
    return "B10C%020X" % next(counter)


def add(section, comment, body):
    i = oid()
    objs.setdefault(section, []).append((i, comment, body))
    return i


def q(s):
    s = str(s)
    return s if s.replace("_", "").replace(".", "").replace("/", "").isalnum() else '"' + s.replace('"', '\\"') + '"'


def fmt_list(items):
    return "(\n" + "".join(f"\t\t\t\t{x},\n" for x in items) + "\t\t\t)"


def fmt_settings(d):
    lines = []
    for k in sorted(d):
        v = d[k]
        if isinstance(v, list):
            inner = "".join(f"\t\t\t\t\t{q(x)},\n" for x in v)
            lines.append(f"\t\t\t\t{q(k)} = (\n{inner}\t\t\t\t);\n")
        else:
            lines.append(f"\t\t\t\t{q(k)} = {q(v)};\n")
    return "{\n" + "".join(lines) + "\t\t\t}"


def synced(path):
    return add("PBXFileSystemSynchronizedRootGroup", path,
               f'{{\n\t\t\tisa = PBXFileSystemSynchronizedRootGroup;\n\t\t\tpath = {path};\n\t\t\tsourceTree = "<group>";\n\t\t}}')


def product(name, ftype):
    return add("PBXFileReference", name,
               f"{{isa = PBXFileReference; explicitFileType = {ftype}; includeInIndex = 0; path = {name}; sourceTree = BUILT_PRODUCTS_DIR; }}")


def phase(kind):
    return add(kind, kind.replace("PBX", "").replace("BuildPhase", ""),
               f"{{\n\t\t\tisa = {kind};\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}}")


def config_list(comment, debug, release):
    d = add("XCBuildConfiguration", "Debug", f"{{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {fmt_settings(debug)};\n\t\t\tname = Debug;\n\t\t}}")
    r = add("XCBuildConfiguration", "Release", f"{{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {fmt_settings(release)};\n\t\t\tname = Release;\n\t\t}}")
    return add("XCConfigurationList", comment,
               f"{{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = {fmt_list([d + ' /* Debug */', r + ' /* Release */'])};\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}}")


def target(name, settings, groups, product_ref, product_type, deps=(), extra_phases=()):
    cl = config_list(f'Build configuration list for PBXNativeTarget "{name}"', settings, settings)
    phases = [phase("PBXSourcesBuildPhase"), phase("PBXFrameworksBuildPhase"), phase("PBXResourcesBuildPhase"), *extra_phases]
    return add("PBXNativeTarget", name,
               f"{{\n\t\t\tisa = PBXNativeTarget;\n\t\t\tbuildConfigurationList = {cl};\n\t\t\tbuildPhases = {fmt_list(phases)};\n\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = {fmt_list(deps)};\n"
               f"\t\t\tfileSystemSynchronizedGroups = {fmt_list(groups)};\n"
               f"\t\t\tname = {name};\n\t\t\tproductName = {name};\n\t\t\tproductReference = {product_ref};\n\t\t\tproductType = \"{product_type}\";\n\t\t}}")


PROJECT = "PROJECT_ID"
MULTI = {
    "SDKROOT": "auto",
    "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator macosx",
    "SUPPORTS_MACCATALYST": "NO",
    "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO",
}
IOS_ONLY = {"SDKROOT": "iphoneos", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator"}

g_app, g_shared, g_ext, g_share = synced("App"), synced("Shared"), synced("Extension"), synced("ShareExtension")
g_config, g_tools = synced("Config"), synced("tools")
seeds = {n: synced(n) for n in ("Ads", "Privacy", "Annoyances")}

# --- content-blocker extensions (multiplatform)
blockers = {"Ads": ("ads", "Ads"), "Privacy": ("privacy", "Trackers"), "Annoyances": ("annoyances", "Annoyances")}
p_ext, t_ext = {}, {}
for n, (suffix, display) in blockers.items():
    p_ext[n] = product(f"Blocker{n}.appex", '"wrapper.app-extension"')
    t_ext[n] = target(f"Blocker{n}", {
        **MULTI,
        "APPLICATION_EXTENSION_API_ONLY": "YES",
        "CODE_SIGN_ENTITLEMENTS": "Config/Extension.entitlements",
        "CODE_SIGN_ENTITLEMENTS[sdk=macosx*]": "Config/Extension-macOS.entitlements",
        "GENERATE_INFOPLIST_FILE": "YES",
        "INFOPLIST_FILE": "Config/Extension-Info.plist",
        "INFOPLIST_KEY_CFBundleDisplayName": display,
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks"],
        "LD_RUNPATH_SEARCH_PATHS[sdk=macosx*]": ["$(inherited)", "@executable_path/../Frameworks", "@executable_path/../../../../Frameworks"],
        "PRODUCT_BUNDLE_IDENTIFIER": f"$(BUNDLE_ID_PREFIX).blocker.{suffix}",
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "SKIP_INSTALL": "YES",
    }, [g_shared + " /* Shared */", g_ext + " /* Extension */", seeds[n] + f" /* {n} */"],
        p_ext[n], "com.apple.product-type.app-extension")

# --- Share extension (iOS and iPadOS only)
p_share = product("BlockerShare.appex", '"wrapper.app-extension"')
t_share = target("BlockerShare", {
    **IOS_ONLY,
    "APPLICATION_EXTENSION_API_ONLY": "YES",
    "CODE_SIGN_ENTITLEMENTS": "Config/App.entitlements",
    "GENERATE_INFOPLIST_FILE": "YES",
    "INFOPLIST_FILE": "Config/Share-Info.plist",
    "INFOPLIST_KEY_CFBundleDisplayName": "Ad Nope",
    "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks"],
    "PRODUCT_BUNDLE_IDENTIFIER": "$(BUNDLE_ID_PREFIX).blocker.share",
    "PRODUCT_NAME": "$(TARGET_NAME)",
    "SKIP_INSTALL": "YES",
}, [g_shared + " /* Shared */", g_share + " /* ShareExtension */"], p_share, "com.apple.product-type.app-extension")

# --- embed everything in the app; the Share extension only on iOS
embed_files, deps = [], []
for name, ref, tgt, ios_only in [*((f"Blocker{n}", p_ext[n], t_ext[n], False) for n in blockers),
                                  ("BlockerShare", p_share, t_share, True)]:
    pf = "platformFilter = ios; " if ios_only else ""
    embed_files.append(add("PBXBuildFile", f"{name}.appex in Embed Foundation Extensions",
                           f"{{isa = PBXBuildFile; fileRef = {ref}; {pf}settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }}"))
    proxy = add("PBXContainerItemProxy", "PBXContainerItemProxy",
                f"{{\n\t\t\tisa = PBXContainerItemProxy;\n\t\t\tcontainerPortal = {PROJECT};\n\t\t\tproxyType = 1;\n\t\t\tremoteGlobalIDString = {tgt};\n\t\t\tremoteInfo = {name};\n\t\t}}")
    dep_pf = "\t\t\tplatformFilter = ios;\n" if ios_only else ""
    deps.append(add("PBXTargetDependency", "PBXTargetDependency",
                    f"{{\n\t\t\tisa = PBXTargetDependency;\n{dep_pf}\t\t\ttarget = {tgt};\n\t\t\ttargetProxy = {proxy};\n\t\t}}"))
embed = add("PBXCopyFilesBuildPhase", "Embed Foundation Extensions",
            "{\n\t\t\tisa = PBXCopyFilesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tdstPath = \"\";\n\t\t\tdstSubfolderSpec = 13;\n"
            f"\t\t\tfiles = {fmt_list(embed_files)};\n\t\t\tname = \"Embed Foundation Extensions\";\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}}")

# --- the app (multiplatform)
p_app = product("Blocker.app", "wrapper.application")
t_app = target("Blocker", {
    **MULTI,
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
    "CODE_SIGN_ENTITLEMENTS": "Config/App.entitlements",
    "CODE_SIGN_ENTITLEMENTS[sdk=macosx*]": "Config/App-macOS.entitlements",
    "ENABLE_PREVIEWS": "YES",
    "GENERATE_INFOPLIST_FILE": "YES",
    "INFOPLIST_FILE": "Config/App-Info.plist",
    "INFOPLIST_KEY_CFBundleDisplayName": "Ad Nope",
    "INFOPLIST_KEY_LSApplicationCategoryType": "public.app-category.utilities",
    "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES",
    "INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents": "YES",
    "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
    "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad": "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight",
    "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone": "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight",
    "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
    "LD_RUNPATH_SEARCH_PATHS[sdk=macosx*]": ["$(inherited)", "@executable_path/../Frameworks"],
    "PRODUCT_BUNDLE_IDENTIFIER": "$(BUNDLE_ID_PREFIX).blocker",
    "PRODUCT_NAME": "$(TARGET_NAME)",
    "SWIFT_EMIT_LOC_STRINGS": "YES",
}, [g_app + " /* App */", g_shared + " /* Shared */"], p_app, "com.apple.product-type.application",
    deps=deps, extra_phases=[embed + " /* Embed Foundation Extensions */"])

# --- project-wide settings
base = {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "APP_GROUP_ID": "group.$(BUNDLE_ID_PREFIX).blocker",
    "BUNDLE_ID_PREFIX": "com.dcantor",
    "CLANG_ENABLE_MODULES": "YES",
    "CLANG_ENABLE_OBJC_ARC": "YES",
    "CODE_SIGN_STYLE": "Automatic",
    "COPY_PHASE_STRIP": "NO",
    "CURRENT_PROJECT_VERSION": "1",
    "DEVELOPMENT_TEAM": "WQ68C644CG",
    "ENABLE_HARDENED_RUNTIME": "YES",
    "ENABLE_STRICT_OBJC_MSGSEND": "YES",
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    "IPHONEOS_DEPLOYMENT_TARGET": "18.0",
    "MACOSX_DEPLOYMENT_TARGET": "15.0",
    "MARKETING_VERSION": "1.1",
    "SDKROOT": "iphoneos",
    "SWIFT_VERSION": "5.0",
    "TARGETED_DEVICE_FAMILY": "1,2",
}
debug = dict(base, DEBUG_INFORMATION_FORMAT="dwarf", ENABLE_TESTABILITY="YES", GCC_OPTIMIZATION_LEVEL="0",
             ONLY_ACTIVE_ARCH="YES", SWIFT_ACTIVE_COMPILATION_CONDITIONS="DEBUG $(inherited)", SWIFT_OPTIMIZATION_LEVEL="-Onone")
release = dict(base, DEBUG_INFORMATION_FORMAT="dwarf-with-dsym", ENABLE_NS_ASSERTIONS="NO",
               SWIFT_COMPILATION_MODE="wholemodule", VALIDATE_PRODUCT="YES")
proj_cl = config_list('Build configuration list for PBXProject "Blocker"', debug, release)

# --- groups
g_seeds = add("PBXGroup", "Seeds",
              f"{{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = {fmt_list([seeds[n] + f' /* {n} */' for n in seeds])};\n\t\t\tpath = Seeds;\n\t\t\tsourceTree = \"<group>\";\n\t\t}}")
g_products = add("PBXGroup", "Products",
                 f"{{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = {fmt_list([p_app, *p_ext.values(), p_share])};\n\t\t\tname = Products;\n\t\t\tsourceTree = \"<group>\";\n\t\t}}")
g_main = add("PBXGroup", "",
             f"{{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = {fmt_list([g_app + ' /* App */', g_shared + ' /* Shared */', g_ext + ' /* Extension */', g_share + ' /* ShareExtension */', g_seeds + ' /* Seeds */', g_config + ' /* Config */', g_tools + ' /* tools */', g_products + ' /* Products */'])};\n\t\t\tsourceTree = \"<group>\";\n\t\t}}")

all_targets = [t_app, *t_ext.values(), t_share]
attrs = "".join(f"\t\t\t\t\t{t} = {{\n\t\t\t\t\t\tCreatedOnToolsVersion = 27.2;\n\t\t\t\t\t}};\n" for t in all_targets)
proj = add("PBXProject", "Project object",
           "{\n\t\t\tisa = PBXProject;\n\t\t\tattributes = {\n\t\t\t\tBuildIndependentTargetsInParallel = 1;\n\t\t\t\tLastSwiftUpdateCheck = 2700;\n\t\t\t\tLastUpgradeCheck = 2700;\n"
           f"\t\t\t\tTargetAttributes = {{\n{attrs}\t\t\t\t}};\n\t\t\t}};\n\t\t\tbuildConfigurationList = {proj_cl};\n\t\t\tdevelopmentRegion = en;\n\t\t\thasScannedForEncodings = 0;\n"
           "\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t);\n"
           f"\t\t\tmainGroup = {g_main};\n\t\t\tminimizedProjectReferenceProxies = 1;\n\t\t\tpreferredProjectObjectVersion = 77;\n\t\t\tproductRefGroup = {g_products};\n"
           f"\t\t\tprojectDirPath = \"\";\n\t\t\tprojectRoot = \"\";\n\t\t\ttargets = {fmt_list(all_targets)};\n\t\t}}")

text = "// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 77;\n\tobjects = {\n"
for section in sorted(objs):
    text += f"\n/* Begin {section} section */\n"
    for i, comment, body in objs[section]:
        text += f"\t\t{i}{f' /* {comment} */' if comment else ''} = {body};\n"
    text += f"/* End {section} section */\n"
text += f"\t}};\n\trootObject = {proj} /* Project object */;\n}}\n"
OUT.write_text(text.replace(PROJECT, proj))
print(f"wrote {OUT.relative_to(ROOT)}")
