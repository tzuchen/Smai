# AFM Development Notes

This document is a Git checkout of McBopomofo commit `be6564acad6c4d3265c34a2e1a872d80f9db6068` from upstream `https://github.com/openvanilla/McBopomofo`. The project is released under the MIT License. Preserve `LICENSE.txt` in all distributions.

## Repository Status

- Primary repository: `/Users/orin/Projects/afm-zhuyin-mcbopomofo`
- Branch: `feat/afm-assist`
- The previous prototype at `/Users/orin/Projects/afm-zhuyin` is now a historical experiment only.
- Native source files have been modified to integrate AFM assist into the input method bridge.
- Generated artifacts reside under `.build/afm` and `.build/xcode`.
- No external network requests are made unless explicitly opted in via the AFM assist tool.

## Build and Run

### Build Dictionary and Engine Probe

Run the build script to generate the production dictionary and compile the native engine probe:

    python3 Tools/AFM/build.py

This script:
1. Copies `phrase.occ` and `exclusion.txt` to a working directory.
2. Runs `frequency_builder.py` to produce `PhraseFreq.txt`.
3. Runs `main_compiler.py` to produce `data-raw.txt`.
4. Runs `postprocess.py` to produce `data.txt`.
5. Compiles `EngineProbe.cpp` into `.build/afm/engine-probe`.

All outputs are placed under `.build/afm/`. The build is incremental; it skips regeneration if outputs are newer than all source inputs.

### Run Engine Probe

Query the native engine with Bopomofo keys:

    python3 Tools/AFM/assist.py --keys "su3 cl3"

This invokes the compiled `engine-probe` binary with the generated `data.txt` and prints candidate results as JSON.

### Run with AFM Assist

Enable the AFM (Apple Foundation Model) candidate selection layer:

    python3 Tools/AFM/assist.py --keys "su3 cl3" --afm --context "朋友打招呼說"

The AFM layer sends a request to a local LLM endpoint (default: `http://127.0.0.1:1975/v1/chat/completions`) with a default timeout of 800 ms. The timeout can be configured via the `--timeout-ms` flag (alias: `--timeout`). If the request fails or times out, the system falls back to the first native candidate. Fallback reasons are classified and reported in the output:

- `timeout`: Request exceeded the deadline.
- `http`: Non-2xx HTTP response.
- `transport`: Connection refused or network error.
- `invalid_response`: Malformed or unexpected JSON from the model.

Because the default endpoint is a local service that may not be running, fallbacks are frequent in development. The selected endpoint and service logging status are unverified in this checkout.

### Acceptance Example

    python3 Tools/AFM/assist.py --keys "g4 ru,4" --context "這副眼鏡讓我的" --afm

On the current setup, this command selected `視界` (baseline `世界`) with `used_afm: true` and an elapsed time of 720.63 ms. This is a single sample and does not guarantee latency or accuracy.

### Run Tests

Run the Python test suite:

    python3 -m unittest discover -s Tools/AFM -p test_assist.py -v

## Architecture

### Native Engine Integration

The AFM tool reuses the following native McBopomofo components:

- **StandardLayout reading parser**: Parses Bopomofo key sequences into readings using the upstream keyboard layout definitions.
- **McBopomofoLM**: Loads the full generated production dictionary (`data.txt`) for candidate generation.
- **ReadingGrid segmentation**: Performs existing segmentation and cursor candidate enumeration.

No toy or partial dictionaries are used. The baseline candidate list comes from the real production dictionary.

### Limitations

- Variants are currently applied only at the last reading.
- User phrase personalization is not loaded in the engine probe.
- The AFM layer is a headless engine integration only. It is NOT hooked into `InputMethodController` or the installer.
- No full zero-selection claim is made. No installation into the system has been completed.

## Native Input Method Integration

The AFM assist layer is now integrated into the native input method via `Source/AFMAssist.swift` and the `KeyHandler` bridge.

### Configuration and Opt-in

- **Preferences**: The feature is disabled by default (`false`).
- **User Interface**: Enabled via the input menu item "AI-Assisted Candidate Selection" (zh-Hant: "AI 輔助選字").
- **Network**: No network requests are made unless the user explicitly enables this preference.

### Behavior and Constraints

- **Architecture**: Whole-sentence neural semantic correction (dual-engine: Spark Qwen 27B primary on LAN with 0-thinking mode, falling back to on-device Apple Foundation Model ~3B).
- **Trigger**: Triggers on completed composition buffer (guarded against in-flight Bopomofo syllable composition via `containsBopomofoOrTone`).
- **Timing**:
    - 350 ms debounce for continuous typing.
    - 0 ms immediate trigger on punctuation marks (`，`, `。`, `？`, `！`, etc.).
    - 1500 ms request/resource timeout.
- **Visual Feedback**:
    - In-flight request: composing buffer turns Indigo.
    - Correction applied: multi-range highlighting with Yellow background and Orange text with thick underline.
- **Safety**:
    - Never rewrites submitted text (Enter commits immediately).
    - Operates per sentence without accumulating stale conversation context.
    - Silent fallback to baseline composing buffer upon network or timeout issues.

### Source Modifications

- `Source/AFMAssist.swift`: Implements whole-sentence neural correction client (Spark Qwen 27B + AFM fallback), request gate, and response sanitizer.
- `Source/InputState.swift`: Implements in-flight Indigo color and multi-range Yellow/Orange highlight styling.
- `Source/InputMethodController.swift`: Integrates whole-sentence scheduling, Bopomofo syllable composition protection, and visual state dispatching.

## Xcode Build Status

Xcode 27 is installed and `checkFirstLaunchStatus` passes. A native upstream `McBopomofo.app` Debug build succeeded:

    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project McBopomofo.xcodeproj -scheme McBopomofo -configuration Debug -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build

Artifact: `.build/xcode/Build/Products/Debug/McBopomofo.app`

This build is not installed into the system. The Xcode toolchain is available and functional. Real-app UX has not been tested.

## Independent Packaging

The AFM fork uses a distinct bundle identity to prevent overwriting upstream installations:

- **Bundle ID**: `org.orin.inputmethod.McBopomofoAFM`
- **Input Modes**: `org.orin.inputmethod.McBopomofoAFM.Bopomofo`, `org.orin.inputmethod.McBopomofoAFM.PlainBopomofo`
- **Connection Name**: `McBopomofoAFM_1_Connection`

### Build and Package

The packaging script builds the app with the new fork identity and copies it to an isolated distribution path:

    python3 Tools/AFM/package.py --build

This command:
1. Runs the scoped Xcode build to produce `.build/xcode/Build/Products/Debug/McBopomofo.app` with the new fork identity.
2. Verifies the source app's `Info.plist` matches the expected AFM identity.
3. Copies the app bundle to `.build/afm-distribution/McBopomofoAFM.app` using `/usr/bin/ditto`.
4. Refuses to overwrite an existing destination. Use `--output` to specify a custom new path.
5. Removes test plugins and ad-hoc codesigns the destination bundle.

The upstream installer target is never run, as it retains upstream destination logic.

### Isolated Defaults and Data

- **Defaults**: The fork uses isolated `UserDefaults` suite.
- **First Launch Import**: On first launch, the fork imports missing keys from the original McBopomofo `allKeys` only.
- **AI Opt-in**: The AI-assisted candidate selection preference remains `false` by default.
- **User Dictionaries**: Shared original user dictionaries are preserved; a custom path can be imported.
- **System Data**: Apple built-in Zhuyin private dictionary and settings are not imported.

### Test Status

- **Headless Tests**: 26 headless Python tests pass.
- **Native Tests**: The prior native build passed, but native test execution via `testmanager` failed. Direct suite execution encountered pasteboard failures and updater hang. No claim is made that native AFM tests passed.
- **Upstream Updater**: Upstream updater endpoints have been removed in the fork.

## Shared-User Installer Instructions

This section documents the process for building and installing the AFM fork for multiple user accounts (e.g., `orin` and `tzuchen`) on a single macOS machine.

### 1. Build and Package

The shared-user installation requires a macOS `.pkg` package that installs the app to `/Library/Input Methods/McBopomofoAFM.app`. This location allows all user accounts to share the same application binary while maintaining isolated per-user preferences.

**Step 1: Build the App Bundle**

If the app bundle has not been built yet, run:

python3 Tools/AFM/package.py --build --output .build/afm-unicode-fix/McBopomofoAFM.app

If the app bundle already exists at `.build/afm-unicode-fix/McBopomofoAFM.app`, omit the `--build` flag:

python3 Tools/AFM/package.py --output .build/afm-unicode-fix/McBopomofoAFM.app

**Step 2: Build the Installer Package**

Run the installer builder to produce the `.pkg` file:

python3 Tools/AFM/build_installer.py

This produces:

.build/afm-unicode-fix/McBopomofoAFM.pkg

**Custom Paths:**
- Use `--source` to specify a custom source app path.
- Use `--output` to specify a custom output `.pkg` path.
- The tool refuses to overwrite existing outputs.

### 2. Installation

The package must be installed with administrator privileges. Two methods are available:

**Method A: macOS Installer (GUI)**

Double-click `McBopomofoAFM.pkg` and follow the prompts. Enter an administrator password when requested.

**Method B: Command Line**

sudo /usr/sbin/installer -pkg .build/afm-unicode-fix/McBopomofoAFM.pkg -target /

**Installation Target:**
- The package installs to `/Library/Input Methods/McBopomofoAFM.app`.
- This is a system-wide location shared by all user accounts.
- The package does NOT overwrite or relocate the upstream McBopomofo installation.
- No install scripts are included in the package.

### 3. Per-User Configuration

After installation, each user account must independently configure the input method:

1. **Add Input Source**: Go to **System Settings > Keyboard > Text Input > Edit > + > Traditional Chinese** and select **小麥注音 AFM**.
2. **Logout/Login**: A logout and login may be required for the input method to appear in the input menu.
3. **Isolated Preferences**: Each user account has isolated `UserDefaults` for the AFM fork.
4. **First-Launch Import**: On first launch, the fork imports missing keys from the original McBopomofo `allKeys` for that specific user account only.
5. **User Dictionaries**: Each user's original McBopomofo user dictionaries are preserved in their own home directory. They are NOT shared across accounts.
6. **AI Opt-in**: The AI-assisted candidate selection preference remains `false` by default for each user.

### 4. Status and Limitations

- **No System Installation Performed**: No installation has been performed in the current work because no passwordless sudo is available.
- **No UI Testing**: No actual UI testing has been performed.
- **No Native Tests Passed**: No claim is made that native AFM tests passed.
- **No Commits or Pushes**: No commits or pushes have been made.

## Unicode Input Repair (v0.1.1)

### Background and Repairs

- **Native ASCII**: The native ASCII Bopomofo input path (e.g., `su3 cl3`) works correctly.
- **Unicode Input**: Per-character Unicode Bopomofo input (e.g., `ㄋㄧˇㄏㄠˇ`) formerly produced `、` (comma) or `4` errors due to parsing/layout mapping issues.
- **Repairs**: The existing Mandarin parsing and layout mapping have been repaired to handle single-character Unicode input for Standard, Eten, and IBM layouts.
- **First-Tone Completion**: Unicode input with first-tone marker `U+02C9` (ˉ) is now supported for completion.
- **Unsupported Cases**: Ambiguous Hsu/Eten26/pinyin Unicode inputs remain unsupported.
- **ASCII Preservation**: Original ASCII input paths are preserved and unaffected.

### CLI Diagnostics

The `assist.py` CLI now supports read-only native diagnostics for Unicode input:

- `--diagnose`: Enable diagnostic mode.
- `--unicode-input`: Specify Unicode Bopomofo input string.
- `--first-tone`: Enable first-tone completion handling.
- `--unknown-unicode`: Report unknown Unicode characters.

Example:

    python3 Tools/AFM/assist.py --diagnose --unicode-input "ㄋㄧˇㄏㄠˇ" --first-tone

### Package and Installation

- **New Package**: `.build/afm-unicode-fix/McBopomofoAFM.pkg` (version 0.1.1, bundle 2511).
- **Installation**: Requires administrator privileges. After installation, logout/login is required for the input method to appear.
- **Shared Desktop**: No claim is made that the actual shared desktop input method is fixed yet; user remote tool confirmation is unconfirmed.
- **Both Accounts**: Both user accounts use the same system app path (`/Library/Input Methods/McBopomofoAFM.app`).
- **Old Artifact**: The previous artifact at `.build/afm-distribution-reviewed/McBopomofoAFM.pkg` is retained.

### Build Instructions Update

The build instructions have been updated to use the new directory `.build/afm-unicode-fix/` for the v0.1.1 package. See the "Shared-User Installer Instructions" section above for the updated commands.

## CapsLock Repair (v0.1.3)

### Background and Repairs

- **User Report**: A user reports that the 中/英 key toggles between ASCII phonetic spelling (e.g., `su3 cl3`) and Unicode phonetic symbols (e.g., `ㄋㄧˇ`) in the shared desktop.
- **User Confirmation**: The user confirmed the behavior via macOS Screen Sharing and the physical CapsLock key.
- **Native CapsLock Flags Repro**: The native CapsLock flags path previously committed the Unicode input `ㄧˇ` unchanged.
- **Controller Handling**: The controller now handles `flagsChanged` for `keyCapsLock` via the existing `commitComposition` and a `basisKeyboardLayout` override. Returning `false` leaves the OS normal CapsLock behavior intact.
- **Engine Repairs**: The engine supports a Unicode fallback to English, Shift uppercase, and preserves pending text.
- **Unchanged Routes**: Chinese ASCII and Unicode routes are unchanged.
- **AFM Endpoint**: The AFM `1975` endpoint is retained.
- **Standard/Eten/IBM Unicode Limitation**: The Standard/Eten/IBM Unicode limitation persists.

### CLI Diagnostics

The `assist.py` CLI now supports read-only native diagnostics for CapsLock behavior:

- `--capslock-ascii`: Report ASCII phonetic spelling behavior.
- `--capslock-unicode`: Report Unicode phonetic symbol behavior.
- `--capslock-unicode-shift`: Report Shift + Unicode behavior.
- `--capslock-transition`: Report transition behavior between modes.

Example:

    python3 Tools/AFM/assist.py --diagnose --capslock-ascii --capslock-unicode --capslock-unicode-shift --capslock-transition

### Package and Installation

- **New Package**: `.build/afm-capslock-final/McBopomofoAFM.pkg` (version 0.1.3, bundle 2513).
- **Installation**: Requires administrator privileges. After installation, logout/login is required for the input method to appear.
- **Shared Desktop**: Both user accounts use the same system app path (`/Library/Input Methods/McBopomofoAFM.app`).
- **Older Artifact**: The earlier engine-only package at `.build/afm-capslock-fix/McBopomofoAFM.pkg` is retained.
- **No Claim**: No claim is made that global CapsLock keyboard settings are changed.

### Status and Limitations

- **No System Installation Performed**: No installation has been performed in the current work because no passwordless sudo is available.
- **No Native GUI / Shared-Desktop Human Validation**: Exact native GUI / shared-desktop human validation remains not done.
- **Engine Diagnostics**: 8 engine diagnostics pass.
- **Tool Tests**: 43 tool tests pass.
- **Controller Compile**: The controller is compile-verified only.
- **No Native Tests Passed**: No claim is made that native AFM tests passed.
- **No Commits or Pushes**: No commits or pushes have been made.
- **Earlier Tests**: The earlier test results remain factual and are preserved.
