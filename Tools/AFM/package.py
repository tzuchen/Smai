#!/usr/bin/env python3
"""
McBopomofo AFM Packaging CLI

Copyright © 2011-2026 Mengjuei Hsieh et al.
Licensed under the MIT License.

This tool packages the McBopomofo AFM input method for local distribution.
It does NOT install, register, or modify system preferences.
"""

import argparse
import hashlib
import os
import plistlib
import re
import shutil
import subprocess
import sys
from pathlib import Path

# Resolve repository root relative to this file
# This file is at Tools/AFM/package.py, so repo root is two levels up
REPO_ROOT = Path(__file__).resolve().parent.parent.parent

# Expected identity values from Source/McBopomofo-Info.plist
EXPECTED_BUNDLE_ID = "org.orin.inputmethod.Smai"
EXPECTED_CONNECTION_NAME = "Smai_1_Connection"
EXPECTED_MODE_IDS = [
    "org.orin.inputmethod.Smai.Bopomofo",
    "org.orin.inputmethod.Smai.PlainBopomofo",
]

# Default paths
DEFAULT_SOURCE_APP = REPO_ROOT / ".build" / "xcode" / "Build" / "Products" / "Debug" / "Smai.app"
DEFAULT_OUTPUT = REPO_ROOT / ".build" / "afm-distribution" / "Smai.app"

def sha256_file(path: Path) -> str:
    """Compute SHA-256 hash of a file."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()


def preflight_identity(source_app: Path) -> None:
    """
    Verify the source app's Info.plist has the correct AFM identity.
    Refuses if identity is mismatched.
    """
    plist_path = source_app / "Contents" / "Info.plist"
    if not plist_path.is_file():
        raise FileNotFoundError(f"Info.plist not found at {plist_path}")

    with open(plist_path, "rb") as f:
        plist = plistlib.load(f)

    # Check CFBundleIdentifier
    actual_bundle_id = plist.get("CFBundleIdentifier", "")
    if actual_bundle_id != EXPECTED_BUNDLE_ID:
        raise ValueError(
            f"CFBundleIdentifier mismatch: expected '{EXPECTED_BUNDLE_ID}', "
            f"got '{actual_bundle_id}'. "
            f"The source app does not have the correct AFM identity."
        )

    # Check InputMethodConnectionName
    actual_conn = plist.get("InputMethodConnectionName", "")
    if actual_conn != EXPECTED_CONNECTION_NAME:
        raise ValueError(
            f"InputMethodConnectionName mismatch: expected '{EXPECTED_CONNECTION_NAME}', "
            f"got '{actual_conn}'."
        )

    # Check TISInputSourceID matches bundle ID
    actual_tis = plist.get("TISInputSourceID", "")
    if actual_tis != EXPECTED_BUNDLE_ID:
        raise ValueError(
            f"TISInputSourceID mismatch: expected '{EXPECTED_BUNDLE_ID}', "
            f"got '{actual_tis}'."
        )

    # Check ComponentInputModeDict has exactly two expected mode IDs in order
    cid = plist.get("ComponentInputModeDict", {})
    mode_list = cid.get("tsInputModeListKey", {})
    visible_array = cid.get("tsVisibleInputModeOrderedArrayKey", [])

    # Verify the visible array matches expected order
    if visible_array != EXPECTED_MODE_IDS:
        raise ValueError(
            f"tsVisibleInputModeOrderedArrayKey mismatch: expected {EXPECTED_MODE_IDS}, "
            f"got {visible_array}."
        )

    # Verify the mode list keys match expected
    mode_keys = list(mode_list.keys())
    if mode_keys != EXPECTED_MODE_IDS:
        raise ValueError(
            f"tsInputModeListKey keys mismatch: expected {EXPECTED_MODE_IDS}, "
            f"got {mode_keys}."
        )

    print(f"[preflight] Identity verified: {EXPECTED_BUNDLE_ID}")


def run_xcode_build() -> None:
    """Run the scoped Xcode build command."""
    print("[build] Running Xcode build...")
    env = os.environ.copy()
    env["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"

    cmd = [
        "env",
        "DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer",
        "xcodebuild",
        "-project", "McBopomofo.xcodeproj",
        "-scheme", "McBopomofo",
        "-configuration", "Debug",
        "-derivedDataPath", ".build/xcode",
        "CODE_SIGNING_ALLOWED=NO",
        "build",
    ]

    result = subprocess.run(
        cmd,
        cwd=REPO_ROOT,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )

    if result.returncode != 0:
        print(result.stdout, file=sys.stderr)
        raise subprocess.CalledProcessError(
            result.returncode, cmd, output=result.stdout
        )

    print("[build] Xcode build completed successfully.")


def copy_app(source: Path, destination: Path) -> None:
    """
    Copy the app bundle using /usr/bin/ditto to preserve bundle structure.
    Refuses if destination already exists or is a dangling symlink.
    """
    if destination.exists() or destination.is_symlink():
        raise FileExistsError(
            f"Destination already exists: {destination}\n"
            f"Use a new --output path to avoid overwriting an existing distribution."
        )

    # Prevent recursive copy: output must not be inside source, source must not be inside output
    source_resolved = source.resolve()
    dest_resolved = destination.resolve()
    if dest_resolved.is_relative_to(source_resolved):
        raise ValueError(
            f"Output path {destination} is inside source bundle {source}. "
            f"Choose a destination outside the source app."
        )
    if source_resolved.is_relative_to(dest_resolved):
        raise ValueError(
            f"Source path {source} is inside output path {destination}. "
            f"Choose a source outside the output directory."
        )

    # Ensure parent directory exists
    destination.parent.mkdir(parents=True, exist_ok=True)

    print(f"[copy] Copying {source} -> {destination}")
    result = subprocess.run(
        ["/usr/bin/ditto", str(source), str(destination)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )

    if result.returncode != 0:
        raise subprocess.CalledProcessError(
            result.returncode,
            ["/usr/bin/ditto", str(source), str(destination)],
            output=result.stdout + result.stderr,
        )

    print("[copy] App bundle copied.")


def remove_test_plugins(destination: Path) -> None:
    """
    Remove unit test PlugIns from the newly-created destination bundle.
    Only removes within destination/Contents/PlugIns.
    """
    plugins_dir = destination / "Contents" / "PlugIns"
    if not plugins_dir.is_dir():
        print("[cleanup] No PlugIns directory found; nothing to remove.")
        return

    # Identify test-related plugin bundles
    test_plugin_names = [
        "McBopomofoTests",
        "McBopomofoTests.xctest",
    ]

    removed = []
    for item in plugins_dir.iterdir():
        if item.name in test_plugin_names:
            # Reject symlinks: do not follow symlink removal
            if item.is_symlink():
                raise RuntimeError(
                    f"Refusing to remove {item}: is a symlink"
                )
            # Verify containment: ensure the path is under destination
            resolved = item.resolve()
            dest_resolved = destination.resolve()
            if not resolved.is_relative_to(dest_resolved):
                raise RuntimeError(
                    f"Refusing to remove {resolved}: not contained within {dest_resolved}"
                )
            shutil.rmtree(item)
            removed.append(item.name)

    if removed:
        print(f"[cleanup] Removed test plugins: {', '.join(removed)}")
    else:
        print("[cleanup] No test plugins found to remove.")


def adhoc_codesign(destination: Path) -> None:
    """Ad-hoc codesign the destination bundle for local testing."""
    print("[codesign] Ad-hoc signing...")
    result = subprocess.run(
        ["/usr/bin/codesign", "--force", "--deep", "--sign", "-", str(destination)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0:
        raise subprocess.CalledProcessError(
            result.returncode,
            ["/usr/bin/codesign", "--force", "--deep", "--sign", "-", str(destination)],
            output=result.stdout + result.stderr,
        )
    print("[codesign] Ad-hoc signing completed.")


def print_summary(destination: Path) -> None:
    """Print output path, identity, and SHA-256 of the executable."""
    plist_path = destination / "Contents" / "Info.plist"
    with open(plist_path, "rb") as f:
        plist = plistlib.load(f)

    bundle_id = plist.get("CFBundleIdentifier", "unknown")
    conn_name = plist.get("InputMethodConnectionName", "unknown")

    # Find the main executable
    exec_name = plist.get("CFBundleExecutable", "")
    if exec_name:
        exec_path = destination / "Contents" / "MacOS" / exec_name
    else:
        # Fallback: look for any executable in MacOS/
        macos_dir = destination / "Contents" / "MacOS"
        if macos_dir.is_dir():
            execs = [f for f in macos_dir.iterdir() if f.is_file()]
            exec_path = execs[0] if execs else None
        else:
            exec_path = None

    if exec_path and exec_path.is_file():
        sha = sha256_file(exec_path)
        print(f"[summary] Executable: {exec_path.name}")
        print(f"[summary] SHA-256:    {sha}")
    else:
        print("[summary] Executable: (not found)")
        print("[summary] SHA-256:    (n/a)")

    print(f"[summary] Bundle ID:  {bundle_id}")
    print(f"[summary] Connection: {conn_name}")
    print(f"[summary] Output:     {destination}")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Package McBopomofo AFM input method for local distribution.",
        epilog="This tool does NOT install, register, or modify system preferences.",
    )
    parser.add_argument(
        "--build",
        action="store_true",
        help="Run the scoped Xcode build before copying.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=None,
        help="Custom destination path (must end with .app). Default: .build/afm-distribution/McBopomofoAFM.app",
    )
    args = parser.parse_args()

    # Determine output path
    if args.output is not None:
        output_path = args.output.resolve()
        if not output_path.name.endswith(".app"):
            parser.error(f"--output must end with .app, got: {args.output}")
    else:
        output_path = DEFAULT_OUTPUT

    # Determine source path
    source_app = DEFAULT_SOURCE_APP

    # Refuse existing output destination EARLY (before --build)
    if output_path.exists() or output_path.is_symlink():
        print(
            f"Error: Destination already exists: {output_path}\n"
            f"Use a new --output path to avoid overwriting an existing distribution.",
            file=sys.stderr,
        )
        sys.exit(1)

    # Prevent recursive copy: output must not be inside source, source must not be inside output
    source_resolved = source_app.resolve()
    dest_resolved = output_path.resolve()
    if dest_resolved.is_relative_to(source_resolved):
        print(
            f"Error: Output path {output_path} is inside source bundle {source_app}. "
            f"Choose a destination outside the source app.",
            file=sys.stderr,
        )
        sys.exit(1)
    if source_resolved.is_relative_to(dest_resolved):
        print(
            f"Error: Source path {source_app} is inside output path {output_path}. "
            f"Choose a source outside the output directory.",
            file=sys.stderr,
        )
        sys.exit(1)

    # Optionally build BEFORE source existence and identity checks
    if args.build:
        try:
            run_xcode_build()
        except subprocess.CalledProcessError as e:
            print(f"Error: Xcode build failed: {e}", file=sys.stderr)
            sys.exit(1)

    # After optional build, do one source check and one identity preflight
    if not source_app.is_dir():
        print(
            f"Error: Source app not found at {source_app}\n"
            f"Run --build first to generate the app, or ensure the Xcode build "
            f"has completed successfully.",
            file=sys.stderr,
        )
        sys.exit(1)

    try:
        preflight_identity(source_app)
    except (ValueError, FileNotFoundError) as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

    # Copy
    try:
        copy_app(source_app, output_path)
    except FileExistsError as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)
    except subprocess.CalledProcessError as e:
        print(f"Error: ditto failed: {e}", file=sys.stderr)
        sys.exit(1)

    # Remove test plugins
    try:
        remove_test_plugins(output_path)
    except (RuntimeError, OSError) as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

    # Ad-hoc codesign
    try:
        adhoc_codesign(output_path)
    except subprocess.CalledProcessError as e:
        print(f"Error: codesign failed: {e}", file=sys.stderr)
        sys.exit(1)

    # Print summary
    print_summary(output_path)


if __name__ == "__main__":
    main()
