#!/usr/bin/env python3
"""Gera OptiStats.xcodeproj (objectVersion 60) a partir de App/OptiStats/**.
Sem dependências externas. Rode de qualquer lugar: python3 scripts/generate_xcodeproj.py"""
import hashlib, pathlib, re, os

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = ROOT / "App" / "OptiStats"
PROJ = ROOT / "OptiStats.xcodeproj"

def uid(s): return hashlib.md5(s.encode()).hexdigest()[:24].upper()
def q(s): return '"%s"' % s.replace('\\', '\\\\').replace('"', '\\"')

objs = {}  # id -> (comment, body)
def add(key, comment, body): objs[uid(key)] = (comment, body); return uid(key)

swift = sorted(p for p in APP.rglob("*.swift"))
strings = {}   # nome -> {lang: path}
for p in sorted(APP.rglob("*.strings")):
    strings.setdefault(p.name, {})[p.parent.name.replace(".lproj", "")] = p
assets = APP / "Resources" / "Assets.xcassets"
plist = APP / "Support" / "Info.plist"
ent = APP / "Support" / "OptiStats.entitlements"

# --- referências de arquivo -------------------------------------------------
def rel(p): return str(p.relative_to(ROOT))
fileref = {}
def ftype(p):
    return {".swift": "sourcecode.swift", ".strings": "text.plist.strings", ".plist": "text.plist.xml",
            ".entitlements": "text.plist.entitlements", ".xcassets": "folder.assetcatalog"}.get(p.suffix, "text")
def mkref(p, name=None):
    i = add("ref:" + rel(p), p.name,
            f"isa = PBXFileReference; lastKnownFileType = {ftype(p)}; name = {q(name or p.name)}; path = {q(rel(p))}; sourceTree = SOURCE_ROOT;")
    fileref[p] = i; return i

for p in swift: mkref(p)
for p in [plist, ent]: mkref(p)
if assets.exists(): mkref(assets)
variant = {}
for n, langs in strings.items():
    kids = []
    for lang, p in sorted(langs.items()):
        i = add("ref:" + rel(p), lang,
                f"isa = PBXFileReference; lastKnownFileType = text.plist.strings; name = {q(lang)}; path = {q(rel(p))}; sourceTree = SOURCE_ROOT;")
        kids.append(i)
    variant[n] = add("var:" + n, n, "isa = PBXVariantGroup; children = (%s); name = %s; sourceTree = \"<group>\";" %
                     (", ".join(kids), q(n)))

# --- grupos (árvore espelhando o disco) ------------------------------------
def group(dirpath, name):
    kids = []
    for d in sorted(x for x in dirpath.iterdir() if x.is_dir() and not x.name.endswith(".lproj") and x.suffix != ".xcassets"):
        g = group(d, d.name)
        if g: kids.append(g)
    for f in sorted(x for x in dirpath.iterdir() if x.is_file()):
        if f in fileref: kids.append(fileref[f])
    if dirpath.name == "Resources":
        kids += list(variant.values())
        if assets.exists(): kids.append(fileref[assets])
    if not kids: return None
    return add("grp:" + rel(dirpath), name, "isa = PBXGroup; children = (%s); name = %s; sourceTree = \"<group>\";" %
               (", ".join(kids), q(name)))
appgroup = group(APP, "OptiStats")
pkgref = add("pkgref", "OptiStatsCore", 'isa = XCLocalSwiftPackageReference; relativePath = "Packages/OptiStatsCore";')
pkgprod = add("pkgprod", "OptiStatsCore", f"isa = XCSwiftPackageProductDependency; package = {pkgref}; productName = OptiStatsCore;")
pkgfile = add("pkgfile", "Packages/OptiStatsCore", 'isa = PBXFileReference; lastKnownFileType = folder; name = OptiStatsCore; path = "Packages/OptiStatsCore"; sourceTree = SOURCE_ROOT;')
product = add("product", "OptiStats.app", "isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = OptiStats.app; sourceTree = BUILT_PRODUCTS_DIR;")
productsgrp = add("products", "Products", f"isa = PBXGroup; children = ({product}); name = Products; sourceTree = \"<group>\";")
maingrp = add("main", "Main", f"isa = PBXGroup; children = ({appgroup}, {pkgfile}, {productsgrp}); sourceTree = \"<group>\";")

# --- build phases ----------------------------------------------------------
sbf = [add("bf:" + rel(p), p.name + " in Sources", f"isa = PBXBuildFile; fileRef = {fileref[p]};") for p in swift]
rbf = [add("bfr:" + n, n + " in Resources", f"isa = PBXBuildFile; fileRef = {v};") for n, v in variant.items()]
if assets.exists(): rbf.append(add("bfr:assets", "Assets in Resources", f"isa = PBXBuildFile; fileRef = {fileref[assets]};"))
pbf = add("bfp", "OptiStatsCore in Frameworks", f"isa = PBXBuildFile; productRef = {pkgprod};")
srcphase = add("ph:src", "Sources", "isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (%s); runOnlyForDeploymentPostprocessing = 0;" % ", ".join(sbf))
fwphase = add("ph:fw", "Frameworks", f"isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({pbf}); runOnlyForDeploymentPostprocessing = 0;")
resphase = add("ph:res", "Resources", "isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (%s); runOnlyForDeploymentPostprocessing = 0;" % ", ".join(rbf))

# --- configurações -----------------------------------------------------------
common = {
    "ALWAYS_SEARCH_USER_PATHS": "NO", "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES",
    "ENABLE_STRICT_OBJC_MSGSEND": "YES", "GCC_NO_COMMON_BLOCKS": "YES", "MACOSX_DEPLOYMENT_TARGET": "13.0",
    "SDKROOT": "macosx", "SWIFT_VERSION": "5.0", "ONLY_ACTIVE_ARCH": "NO",
}
dbg = dict(common, **{"DEBUG_INFORMATION_FORMAT": "dwarf", "ENABLE_TESTABILITY": "YES", "GCC_OPTIMIZATION_LEVEL": "0",
                      "SWIFT_OPTIMIZATION_LEVEL": "-Onone", "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG", "ONLY_ACTIVE_ARCH": "YES"})
rel_ = dict(common, **{"DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym", "SWIFT_OPTIMIZATION_LEVEL": "-O",
                       "SWIFT_COMPILATION_MODE": "wholemodule", "ENABLE_NS_ASSERTIONS": "NO"})
tgt = {
    "PRODUCT_NAME": "OptiStats", "PRODUCT_BUNDLE_IDENTIFIER": "dev.optistats.OptiStats", "MARKETING_VERSION": "1.0.0",
    "CURRENT_PROJECT_VERSION": "1", "INFOPLIST_FILE": rel(plist), "CODE_SIGN_ENTITLEMENTS": rel(ent),
    "CODE_SIGN_IDENTITY": "-", "ENABLE_HARDENED_RUNTIME": "YES",
    "GENERATE_INFOPLIST_FILE": "NO", "COMBINE_HIDPI_IMAGES": "YES", "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../Frameworks",
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon", "SWIFT_EMIT_LOC_STRINGS": "NO",
    "CODE_SIGNING_ALLOWED": "YES", 
}
def cfg(key, name, d):
    body = "isa = XCBuildConfiguration; buildSettings = {%s}; name = %s;" % (
        " ".join(f"{k} = {q(v)};" for k, v in sorted(d.items())), name)
    return add(key, name, body)
pc = [cfg("pcd", "Debug", dbg), cfg("pcr", "Release", rel_)]
tc = [cfg("tcd", "Debug", tgt), cfg("tcr", "Release", tgt)]
def cl(key, ids): return add(key, "Build configuration list", "isa = XCConfigurationList; buildConfigurations = (%s); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;" % ", ".join(ids))
pcl = cl("pcl", pc); tcl = cl("tcl", tc)

target = add("target", "OptiStats", f"isa = PBXNativeTarget; buildConfigurationList = {tcl}; buildPhases = ({srcphase}, {fwphase}, {resphase}); buildRules = (); dependencies = (); name = OptiStats; packageProductDependencies = ({pkgprod}); productName = OptiStats; productReference = {product}; productType = \"com.apple.product-type.application\";")
project = add("project", "Project object", f"isa = PBXProject; attributes = {{BuildIndependentTargetsInParallel = 1; LastSwiftUpdateCheck = 1500; LastUpgradeCheck = 1500;}}; buildConfigurationList = {pcl}; compatibilityVersion = \"Xcode 14.0\"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, \"pt-BR\", Base); mainGroup = {maingrp}; packageReferences = ({pkgref}); productRefGroup = {productsgrp}; projectDirPath = \"\"; projectRoot = \"\"; targets = ({target});")

# --- saída -------------------------------------------------------------------
sections = {}
for i, (c, b) in objs.items():
    isa = re.match(r"isa = (\w+);", b).group(1)
    sections.setdefault(isa, []).append((i, c, b))
out = ["// !$*UTF8*$!", "{", "\tarchiveVersion = 1;", "\tclasses = {", "\t};", "\tobjectVersion = 60;", "\tobjects = {"]
for isa in sorted(sections):
    out.append(f"\n/* Begin {isa} section */")
    for i, c, b in sorted(sections[isa]): out.append(f"\t\t{i} /* {c} */ = {{{b}}};")
    out.append(f"/* End {isa} section */")
out += ["\t};", f"\trootObject = {project} /* Project object */;", "}", ""]
PROJ.mkdir(exist_ok=True)
(PROJ / "project.pbxproj").write_text("\n".join(out), encoding="utf-8")

# scheme compartilhado
sd = PROJ / "xcshareddata" / "xcschemes"; sd.mkdir(parents=True, exist_ok=True)
(sd / "OptiStats.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1500" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{target}" BuildableName = "OptiStats.app" BlueprintName = "OptiStats" ReferencedContainer = "container:OptiStats.xcodeproj"/>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" allowLocationSimulation = "NO">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{target}" BuildableName = "OptiStats.app" BlueprintName = "OptiStats" ReferencedContainer = "container:OptiStats.xcodeproj"/>
      </BuildableProductRunnable>
   </LaunchAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES"/>
</Scheme>
''', encoding="utf-8")
print(f"OK: {len(swift)} fontes, {len(variant)} tabelas de strings")
