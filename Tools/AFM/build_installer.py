#!/usr/bin/env python3
"""
McBopomofo AFM Installer Builder

Copyright © 2011-2026 Mengjuei Hsieh et al.
Licensed under the MIT License.

This tool builds a shared-user macOS pkg for the McBopomofo AFM input method.
It does NOT install, register, or modify system preferences.
"""

import argparse
import os
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

# Resolve repository root relative to this file
# This file is at Tools/AFM/build_installer.py, so repo root is two levels up
REPO_ROOT = Path(__file__).resolve().parent.parent.parent

# Expected identity values from Source/McBopomofo-Info.plist
EXPECTED_BUNDLE_ID = "org.orin.inputmethod.McBopomofoAFM"
EXPECTED_PKG_IDENTIFIER = "org.orin.inputmethod.McBopomofoAFM.pkg"
EXPECTED_PKG_VERSION = "0.1.9"
EXPECTED_INSTALL_LOCATION = "/Library/Input Methods"

# Default paths
DEFAULT_SOURCE_APP = REPO_ROOT / ".build" / "afm-assist-queue" / "McBopomofoAFM.app"
DEFAULT_OUTPUT_PKG = REPO_ROOT / ".build" / "afm-assist-queue" / "McBopomofoAFM.pkg"


def preflight_identity(source_app: Path) -> None:
    """
    Verify the source app's Info.plist has the correct AFM identity.
    Refuses if identity is mismatched.
    """
    import package
    package.preflight_identity(source_app)


def verify_codesign(source_app: Path) -> None:
    """
    Verify the source app is properly codesigned using codesign --verify --deep --strict.
    """
    print(f"[codesign] Verifying signature of {source_app}")
    result = subprocess.run(
        ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(source_app)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )

    if result.returncode != 0:
        error_msg = result.stderr.strip()
        raise subprocess.CalledProcessError(
            result.returncode,
            ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(source_app)],
            output=result.stdout + error_msg,
        )

    print("[codesign] Signature verified.")


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


def set_permissions_for_all_users(root: Path) -> None:
    """
    Ensure all users can read and traverse the directory tree.
    - Directories: OR 0555 (read + execute for all)
    - Normal files: OR 0444 (read for all)
    - Executable files: retain execute bits and add a+x
    Avoids following symlinks when chmod.
    """
    print(f"[permissions] Setting permissions for all users in {root}")

    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        # Set permissions for directories
        for dirname in dirnames:
            dir_path = Path(dirpath) / dirname
            if dir_path.is_symlink():
                continue
            try:
                mode = dir_path.stat().st_mode
                new_mode = mode | stat.S_IRGRP | stat.S_IXGRP | stat.S_IROTH | stat.S_IXOTH
                os.chmod(dir_path, new_mode)
            except OSError as e:
                print(f"[permissions] Warning: Could not set permissions on {dir_path}: {e}", file=sys.stderr)

        # Set permissions for files
        for filename in filenames:
            file_path = Path(dirpath) / filename
            try:
                # Check if it's a symlink first
                if file_path.is_symlink():
                    continue

                mode = file_path.stat().st_mode
                # Check if it's an executable file
                is_executable = bool(mode & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH))

                if is_executable:
                    # Retain execute bits and add a+x
                    new_mode = mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH | stat.S_IRGRP | stat.S_IROTH
                else:
                    # Normal files: add read for all
                    new_mode = mode | stat.S_IRGRP | stat.S_IROTH

                os.chmod(file_path, new_mode)
            except OSError as e:
                print(f"[permissions] Warning: Could not set permissions on {file_path}: {e}", file=sys.stderr)

    print("[permissions] Permissions set.")


def generate_component_plist(staging_root: Path, component_plist_path: Path) -> None:
    """
    Generate components.plist using pkgbuild --analyze --root.
    Then modify all components to set BundleIsRelocatable false and BundleHasStrictIdentifier true.
    """
    print(f"[pkgbuild] Analyzing components in {staging_root}")

    # Run pkgbuild --analyze --root to generate the initial components.plist
    result = subprocess.run(
        [
            "/usr/bin/pkgbuild",
            "--analyze",
            "--root", str(staging_root),
            str(component_plist_path),
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )

    if result.returncode != 0:
        raise subprocess.CalledProcessError(
            result.returncode,
            ["/usr/bin/pkgbuild", "--analyze", "--root", str(staging_root), str(component_plist_path)],
            output=result.stdout + result.stderr,
        )

    # Load the generated components.plist
    with open(component_plist_path, "rb") as f:
        plist = plistlib.load(f)

    if not isinstance(plist, list) or not plist:
        raise ValueError("pkgbuild --analyze did not produce a non-empty list of components")

    # Modify all components to set BundleIsRelocatable false and BundleHasStrictIdentifier true
    for component in plist:
        component["BundleIsRelocatable"] = False
        component["BundleHasStrictIdentifier"] = True

    # Write back the modified components.plist
    with open(component_plist_path, "wb") as f:
        plistlib.dump(plist, f)

    print(f"[pkgbuild] Components plist modified: {len(plist)} component(s) set to non-relocatable with strict identifier.")


def build_package(staging_root: Path, component_plist_path: Path, output_pkg: Path) -> None:
    """
    Build the final package using pkgbuild with the specified options.
    """
    print(f"[pkgbuild] Building package {output_pkg}")

    result = subprocess.run(
        [
            "/usr/bin/pkgbuild",
            "--root", str(staging_root),
            "--component-plist", str(component_plist_path),
            "--identifier", EXPECTED_PKG_IDENTIFIER,
            "--version", EXPECTED_PKG_VERSION,
            "--install-location", EXPECTED_INSTALL_LOCATION,
            "--ownership", "recommended",
            str(output_pkg),
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )

    if result.returncode != 0:
        raise subprocess.CalledProcessError(
            result.returncode,
            [
                "/usr/bin/pkgbuild",
                "--root", str(staging_root),
                "--component-plist", str(component_plist_path),
                "--identifier", EXPECTED_PKG_IDENTIFIER,
                "--version", EXPECTED_PKG_VERSION,
                "--install-location", EXPECTED_INSTALL_LOCATION,
                "--ownership", "recommended",
                str(output_pkg),
            ],
            output=result.stdout + result.stderr,
        )

    print("[pkgbuild] Package built successfully.")


def print_summary(output_pkg: Path) -> None:
    """Print final path and installation instructions."""
    print("\n" + "=" * 60)
    print("Package Build Summary")
    print("=" * 60)
    print(f"Output: {output_pkg}")
    print(f"Identifier: {EXPECTED_PKG_IDENTIFIER}")
    print(f"Version: {EXPECTED_PKG_VERSION}")
    print(f"Install Location: {EXPECTED_INSTALL_LOCATION}")
    print("\nInstallation Command (requires administrator authentication):")
    print(f"  /usr/sbin/installer -pkg \"{output_pkg}\" -target /")
    print("\nNote: After installation, each user account must enable the input source")
    print("via System Settings > Keyboard > Input Sources. A logout/login may be required.")
    print("=" * 60)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Build a shared-user macOS pkg for McBopomofo AFM input method.",
        epilog="This tool builds a package but does NOT install it. "
               "Use /usr/sbin/installer with administrator privileges to install.",
    )
    parser.add_argument(
        "--source",
        type=Path,
        default=DEFAULT_SOURCE_APP,
        help=f"Path to the source McBopomofoAFM.app bundle (default: {DEFAULT_SOURCE_APP})",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=DEFAULT_OUTPUT_PKG,
        help=f"Path for the output .pkg file (default: {DEFAULT_OUTPUT_PKG})",
    )
    args = parser.parse_args()

    source_app = args.source
    output_pkg = args.output

    # Validate source
    if not source_app.is_dir():
        raise FileNotFoundError(f"Source app not found: {source_app}")
    if not (source_app / "Contents" / "Info.plist").is_file():
        raise FileNotFoundError(f"Source app does not appear to be a valid macOS app bundle: {source_app}")

    # Validate output
    if output_pkg.exists() or output_pkg.is_symlink():
        raise FileExistsError(
            f"Output file already exists: {output_pkg}\n"
            f"Use a new --output path to avoid overwriting an existing package."
        )

    # Ensure output parent directory exists
    output_pkg.parent.mkdir(parents=True, exist_ok=True)

    # Preflight identity check
    preflight_identity(source_app)

    # Verify codesign
    verify_codesign(source_app)

    # Use a temporary directory for staging
    with tempfile.TemporaryDirectory(prefix="mcBopomofoAFM_pkg_") as tmp_dir:
        base = Path(tmp_dir)
        staging_root = base / "payload"
        staging_root.mkdir()
        app_in_staging = staging_root / "McBopomofoAFM.app"

        # Copy app to staging
        copy_app(source_app, app_in_staging)

        # Set permissions for all users
        set_permissions_for_all_users(staging_root)

        # Verify codesign of staged app after permission adjustments
        verify_codesign(app_in_staging)

        # Generate and modify components.plist
        component_plist_path = base / "components.plist"
        generate_component_plist(staging_root, component_plist_path)

        # Build the package
        build_package(staging_root, component_plist_path, output_pkg)

    # Print summary
    print_summary(output_pkg)


if __name__ == "__main__":
    main()
