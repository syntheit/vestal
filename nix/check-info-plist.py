"""Check Vestal.app's Info.plist: it must parse as an XML property list and
carry the keys macOS reads, with the right types.

usage: check-info-plist.py <Info.plist> <version>
"""

import plistlib
import sys

path, version = sys.argv[1], sys.argv[2]
with open(path, "rb") as f:
    info = plistlib.load(f, fmt=plistlib.FMT_XML)

expected = {
    "CFBundleIdentifier": "io.matv.vestal",
    "CFBundleName": "Vestal",
    "CFBundleExecutable": "vestal",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": version,
    "LSMinimumSystemVersion": "14.0",
    "LSUIElement": True,
}
usage = [
    "NSCalendarsUsageDescription",
    "NSCalendarsFullAccessUsageDescription",
    "NSAppleEventsUsageDescription",
]

problems = [
    f"{key} is {info.get(key)!r}, expected {want!r}"
    for key, want in expected.items()
    if type(info.get(key)) is not type(want) or info.get(key) != want
]
problems += [f"{key} is missing or empty" for key in usage if not str(info.get(key, "")).strip()]
if problems:
    sys.exit(f"{path}:\n  " + "\n  ".join(problems))
print(f"{path}: ok ({len(info)} keys)")
