#!/usr/bin/env python3
"""
Tests for McBopomofo AFM Packaging CLI.

Copyright © 2011-2026 Mengjuei Hsieh et al.
Licensed under the MIT License.
"""

import importlib.util
import os
import plistlib
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

# Load the module from the known path
MODULE_PATH = Path(__file__).resolve().parent / "package.py"

def load_module():
    spec = importlib.util.spec_from_file_location("package", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

package = load_module()


class TestPackage(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmpdir)
        self.tmp_path = Path(self.tmpdir)

    def _create_fake_app(self, app_path: Path, bundle_id: str = None, conn_name: str = None, mode_ids: list = None, visible_array: list = None):
        """Create a minimal fake .app bundle with Info.plist."""
        if bundle_id is None:
            bundle_id = package.EXPECTED_BUNDLE_ID
        if conn_name is None:
            conn_name = package.EXPECTED_CONNECTION_NAME
        if mode_ids is None:
            mode_ids = package.EXPECTED_MODE_IDS
        if visible_array is None:
            visible_array = package.EXPECTED_MODE_IDS

        contents_dir = app_path / "Contents"
        contents_dir.mkdir(parents=True, exist_ok=True)

        plist = {
            "CFBundleIdentifier": bundle_id,
            "InputMethodConnectionName": conn_name,
            "TISInputSourceID": bundle_id,
            "ComponentInputModeDict": {
                "tsInputModeListKey": {mid: {} for mid in mode_ids},
                "tsVisibleInputModeOrderedArrayKey": visible_array,
            },
        }

        with open(contents_dir / "Info.plist", "wb") as f:
            plistlib.dump(plist, f)

        # Create a dummy executable
        exec_path = contents_dir / "MacOS" / "McBopomofo"
        exec_path.parent.mkdir(parents=True, exist_ok=True)
        exec_path.write_text("fake executable")

    def _create_valid_app(self, app_path: Path):
        self._create_fake_app(app_path)

    def test_main_build_missing_source_calls_run_xcode_build_first(self):
        """Verify that when source app is missing, main --build calls run_xcode_build first."""
        source_app = self.tmp_path / "source" / "McBopomofo.app"
        output_app = self.tmp_path / "output" / "McBopomofoAFM.app"

        # Ensure source does not exist
        self.assertFalse(source_app.exists())

        # Create a mock for run_xcode_build that creates the fake app
        def mock_run_xcode_build():
            self._create_valid_app(source_app)

        with patch.object(package, "run_xcode_build", side_effect=mock_run_xcode_build) as mock_build, \
             patch.object(package, "copy_app") as mock_copy, \
             patch.object(package, "remove_test_plugins") as mock_remove, \
             patch.object(package, "adhoc_codesign") as mock_sign, \
             patch.object(package, "print_summary") as mock_summary, \
             patch.object(sys, "argv", ["package.py", "--build", "--output", str(output_app)]):

            # Set module defaults to our temp paths
            with patch.object(package, "DEFAULT_SOURCE_APP", source_app), \
                 patch.object(package, "DEFAULT_OUTPUT", output_app):

                package.main()

        # Verify run_xcode_build was called
        mock_build.assert_called_once()
        # Verify the fake app was created
        self.assertTrue(source_app.exists())
        # Verify subsequent steps were called
        mock_copy.assert_called_once()
        mock_remove.assert_called_once()
        mock_sign.assert_called_once()
        mock_summary.assert_called_once()

    def test_existing_destination_rejected_before_build(self):
        """Verify that an existing destination is rejected before any build occurs."""
        source_app = self.tmp_path / "source" / "McBopomofo.app"
        output_app = self.tmp_path / "output" / "McBopomofoAFM.app"

        # Create the destination directory to simulate existing
        output_app.mkdir(parents=True)

        with patch.object(package, "run_xcode_build") as mock_build, \
             patch.object(package, "copy_app") as mock_copy, \
             patch.object(sys, "argv", ["package.py", "--build", "--output", str(output_app)]):

            with patch.object(package, "DEFAULT_SOURCE_APP", source_app), \
                 patch.object(package, "DEFAULT_OUTPUT", output_app):

                with self.assertRaises(SystemExit):
                    package.main()

        # Build should NOT have been called
        mock_build.assert_not_called()
        mock_copy.assert_not_called()

    def test_dangling_symlink_destination_rejected(self):
        """Verify that a dangling symlink destination is rejected."""
        source_app = self.tmp_path / "source" / "McBopomofo.app"
        output_app = self.tmp_path / "output" / "McBopomofoAFM.app"

        # Create a dangling symlink
        output_app.parent.mkdir(parents=True, exist_ok=True)
        os.symlink("/nonexistent/path", str(output_app))

        with patch.object(package, "run_xcode_build") as mock_build, \
             patch.object(package, "copy_app") as mock_copy, \
             patch.object(sys, "argv", ["package.py", "--build", "--output", str(output_app)]):

            with patch.object(package, "DEFAULT_SOURCE_APP", source_app), \
                 patch.object(package, "DEFAULT_OUTPUT", output_app):

                with self.assertRaises(SystemExit):
                    package.main()

        mock_build.assert_not_called()
        mock_copy.assert_not_called()

    def test_source_output_nesting_rejected(self):
        """Verify that source inside output or output inside source is rejected."""
        source_app = self.tmp_path / "source" / "McBopomofo.app"
        output_app = source_app / "inner" / "McBopomofoAFM.app"

        # Create source
        self._create_valid_app(source_app)

        with patch.object(package, "run_xcode_build") as mock_build, \
             patch.object(package, "copy_app") as mock_copy, \
             patch.object(package, "remove_test_plugins") as mock_remove, \
             patch.object(package, "adhoc_codesign") as mock_sign, \
             patch.object(package, "print_summary") as mock_summary, \
             patch.object(sys, "argv", ["package.py", "--build", "--output", str(output_app)]):

            with patch.object(package, "DEFAULT_SOURCE_APP", source_app), \
                 patch.object(package, "DEFAULT_OUTPUT", output_app):

                with self.assertRaises(SystemExit):
                    package.main()

        mock_build.assert_not_called()
        mock_copy.assert_not_called()
        mock_remove.assert_not_called()
        mock_sign.assert_not_called()
        mock_summary.assert_not_called()

    def test_preflight_rejects_wrong_bundle_id(self):
        """Verify preflight rejects an app with wrong CFBundleIdentifier."""
        source_app = self.tmp_path / "source" / "McBopomofo.app"
        self._create_fake_app(source_app, bundle_id="org.wrong.bundle.id")

        with self.assertRaises(ValueError):
            package.preflight_identity(source_app)

    def test_preflight_rejects_wrong_connection_name(self):
        """Verify preflight rejects an app with wrong InputMethodConnectionName."""
        source_app = self.tmp_path / "source" / "McBopomofo.app"
        self._create_fake_app(source_app, conn_name="Wrong_Connection")

        with self.assertRaises(ValueError):
            package.preflight_identity(source_app)

    def test_preflight_rejects_wrong_mode_ids(self):
        """Verify preflight rejects an app with wrong mode IDs."""
        source_app = self.tmp_path / "source" / "McBopomofo.app"
        wrong_modes = ["org.orin.inputmethod.McBopomofoAFM.WrongMode"]
        self._create_fake_app(source_app, mode_ids=wrong_modes, visible_array=wrong_modes)

        with self.assertRaises(ValueError):
            package.preflight_identity(source_app)

    def test_preflight_rejects_wrong_visible_array_order(self):
        """Verify preflight rejects an app with wrong visible array order."""
        source_app = self.tmp_path / "source" / "McBopomofo.app"
        reversed_array = list(reversed(package.EXPECTED_MODE_IDS))
        self._create_fake_app(source_app, visible_array=reversed_array)

        with self.assertRaises(ValueError):
            package.preflight_identity(source_app)

    def test_preflight_accepts_valid_info(self):
        """Verify preflight accepts a valid app bundle."""
        source_app = self.tmp_path / "source" / "McBopomofo.app"
        self._create_valid_app(source_app)

        # Should not raise
        package.preflight_identity(source_app)

    def test_copy_app_rejects_existing_destination(self):
        """Verify copy_app rejects if destination already exists."""
        source_app = self.tmp_path / "source" / "McBopomofo.app"
        dest_app = self.tmp_path / "dest" / "McBopomofoAFM.app"

        self._create_valid_app(source_app)
        dest_app.mkdir(parents=True)

        with self.assertRaises(FileExistsError):
            package.copy_app(source_app, dest_app)

    def test_copy_app_rejects_dangling_symlink(self):
        """Verify copy_app rejects if destination is a dangling symlink."""
        source_app = self.tmp_path / "source" / "McBopomofo.app"
        dest_app = self.tmp_path / "dest" / "McBopomofoAFM.app"

        self._create_valid_app(source_app)
        dest_app.parent.mkdir(parents=True, exist_ok=True)
        os.symlink("/nonexistent", str(dest_app))

        with self.assertRaises(FileExistsError):
            package.copy_app(source_app, dest_app)

    def test_copy_app_rejects_source_inside_output(self):
        """Verify copy_app rejects if source is inside output."""
        dest_app = self.tmp_path / "output" / "McBopomofoAFM.app"
        source_app = dest_app / "inner" / "McBopomofo.app"

        self._create_valid_app(source_app)

        with self.assertRaises((FileExistsError, ValueError)):
            package.copy_app(source_app, dest_app)

    def test_copy_app_rejects_output_inside_source(self):
        """Verify copy_app rejects if output is inside source."""
        source_app = self.tmp_path / "source" / "McBopomofo.app"
        dest_app = self.tmp_path / "source" / "McBopomofo.app" / "inner" / "McBopomofoAFM.app"

        self._create_valid_app(source_app)

        with self.assertRaises(ValueError):
            package.copy_app(source_app, dest_app)

    def test_remove_test_plugins_containment_prefix_trick(self):
        """
        Verify that remove_test_plugins does not remove symlinks that point outside
        the destination bundle, even if the symlink name matches a test plugin pattern.
        This tests the containment check to prevent prefix tricks.
        """
        dest_app = self.tmp_path / "dest" / "McBopomofoAFM.app"
        plugins_dir = dest_app / "Contents" / "PlugIns"
        plugins_dir.mkdir(parents=True, exist_ok=True)

        # Create a symlink that looks like a test plugin but points outside
        # This simulates a "prefix trick" where the name matches but target is external
        external_target = self.tmp_path / "external" / "McBopomofoTests.xctest"
        external_target.mkdir(parents=True)
        symlink_path = plugins_dir / "McBopomofoTests.xctest"
        os.symlink(str(external_target), str(symlink_path))

        # Call remove_test_plugins - it should NOT remove the symlink pointing outside
        # The function should only remove items that are within the destination bundle
        # It should raise RuntimeError if it encounters a symlink
        with self.assertRaises(RuntimeError):
            package.remove_test_plugins(dest_app)

        # The external target should still exist
        self.assertTrue(external_target.exists())

    def test_main_no_args_exits(self):
        """Verify main exits with SystemExit when no args are provided."""
        source_app = self.tmp_path / "source" / "McBopomofo.app"
        output_app = self.tmp_path / "output" / "McBopomofoAFM.app"
        
        with patch.object(package, "DEFAULT_SOURCE_APP", source_app), \
             patch.object(package, "DEFAULT_OUTPUT", output_app), \
             patch.object(sys, "argv", ["package.py"]):
            with self.assertRaises(SystemExit):
                package.main()

    def test_main_invalid_command_exits(self):
        """Verify main exits with SystemExit for invalid command."""
        source_app = self.tmp_path / "source" / "McBopomofo.app"
        output_app = self.tmp_path / "output" / "McBopomofoAFM.app"
        
        with patch.object(package, "DEFAULT_SOURCE_APP", source_app), \
             patch.object(package, "DEFAULT_OUTPUT", output_app), \
             patch.object(sys, "argv", ["package.py", "--invalid"]):
            with self.assertRaises(SystemExit):
                package.main()

    def test_sibling_source_output_allowed(self):
        """Verify that sibling source and output paths are permitted."""
        source_app = self.tmp_path / "source" / "McBopomofo.app"
        output_app = self.tmp_path / "output" / "McBopomofoAFM.app"

        # Create the source app so it exists
        self._create_valid_app(source_app)

        with patch.object(package, "run_xcode_build") as mock_build, \
             patch.object(package, "copy_app") as mock_copy, \
             patch.object(package, "remove_test_plugins") as mock_remove, \
             patch.object(package, "adhoc_codesign") as mock_sign, \
             patch.object(package, "print_summary") as mock_summary, \
             patch.object(sys, "argv", ["package.py", "--build", "--output", str(output_app)]):

            with patch.object(package, "DEFAULT_SOURCE_APP", source_app), \
                 patch.object(package, "DEFAULT_OUTPUT", output_app):

                package.main()

        # Since --build is explicitly passed, run_xcode_build should be called
        mock_build.assert_called_once()
        # Subsequent steps should be called
        mock_copy.assert_called_once()
        mock_remove.assert_called_once()
        mock_sign.assert_called_once()
        mock_summary.assert_called_once()


if __name__ == "__main__":
    unittest.main()
