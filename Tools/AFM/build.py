#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
AFM build script for McBopomofo dictionary and native engine probe.

Run: python3 Tools/AFM/build.py
"""

import os
import sys
import subprocess
import shutil
from pathlib import Path


def main() -> int:
    # Resolve paths
    ROOT = Path(__file__).resolve().parents[2]
    DATA = ROOT / "Source" / "Data"
    OUT = ROOT / ".build" / "afm"
    WORKDIR = OUT / "dictionary-work"

    # Ensure output directories exist
    OUT.mkdir(parents=True, exist_ok=True)
    WORKDIR.mkdir(parents=True, exist_ok=True)

    # ------------------------------------------------------------------
    # 1. Copy read-only inputs to workdir
    # ------------------------------------------------------------------
    phrase_occ_src = DATA / "phrase.occ"
    exclusion_src = DATA / "exclusion.txt"

    phrase_occ_dst = WORKDIR / "phrase.occ"
    exclusion_dst = WORKDIR / "exclusion.txt"

    # Copy phrase.occ
    if not phrase_occ_src.is_file():
        print(f"ERROR: Missing source file: {phrase_occ_src}", file=sys.stderr)
        return 1
    shutil.copy2(phrase_occ_src, phrase_occ_dst)

    # Copy exclusion.txt
    if not exclusion_src.is_file():
        print(f"ERROR: Missing source file: {exclusion_src}", file=sys.stderr)
        return 1
    shutil.copy2(exclusion_src, exclusion_dst)

    # ------------------------------------------------------------------
    # 2. Determine if regeneration is needed (incremental check)
    # ------------------------------------------------------------------
    # Collect all source/input files that affect the build
    source_files = [
        phrase_occ_src,
        exclusion_src,
        DATA / "BPMFMappings.txt",
        DATA / "BPMFBase.txt",
        DATA / "BPMFPunctuations.txt",
        DATA / "Symbols.txt",
        DATA / "Macros.txt",
        DATA / "heterophony1.list",
        DATA / "heterophony2.list",
        DATA / "heterophony3.list",
        DATA / "Postprocess.txt",
    ]

    # Check all compiler .py files under DATA/curation
    curation_dir = DATA / "curation"
    if curation_dir.is_dir():
        for py_file in curation_dir.rglob("*.py"):
            source_files.append(py_file)

    # Also check the frequency builder specifically
    freq_builder = DATA / "curation" / "builders" / "frequency_builder.py"
    if freq_builder.is_file() and freq_builder not in source_files:
        source_files.append(freq_builder)

    # Output files to check for staleness
    output_files = [
        WORKDIR / "PhraseFreq.txt",
        OUT / "data-raw.txt",
        OUT / "data.txt",
    ]

    # Check if all outputs exist and are newer than all sources
    need_rebuild = True
    if all(f.is_file() for f in output_files):
        max_source_mtime = max(f.stat().st_mtime for f in source_files if f.is_file())
        min_output_mtime = min(f.stat().st_mtime for f in output_files)
        if min_output_mtime >= max_source_mtime:
            need_rebuild = False

    if not need_rebuild:
        print("All outputs are up to date. Skipping dictionary generation.")
    else:
        print("Generating dictionary data...")

        # ------------------------------------------------------------------
        # 3. Run frequency_builder.py to create PhraseFreq.txt
        # ------------------------------------------------------------------
        freq_builder = DATA / "curation" / "builders" / "frequency_builder.py"
        if not freq_builder.is_file():
            print(f"ERROR: Missing frequency builder: {freq_builder}", file=sys.stderr)
            return 1

        # frequency_builder takes NO arguments; it reads phrase.occ and
        # exclusion.txt from cwd and writes PhraseFreq.txt to cwd.
        freq_env = os.environ.copy()
        freq_env["PYTHONPATH"] = str(DATA)

        freq_result = subprocess.run(
            [sys.executable, str(freq_builder)],
            cwd=str(WORKDIR),
            env=freq_env,
            check=False,
        )
        if freq_result.returncode != 0:
            print(
                f"ERROR: frequency_builder.py failed with exit code {freq_result.returncode}",
                file=sys.stderr,
            )
            return freq_result.returncode

        phrase_freq = WORKDIR / "PhraseFreq.txt"
        if not phrase_freq.is_file():
            print("ERROR: PhraseFreq.txt was not generated.", file=sys.stderr)
            return 1

        # ------------------------------------------------------------------
        # 4. Run main_compiler to produce data-raw.txt
        # ------------------------------------------------------------------
        main_compiler = DATA / "curation" / "compilers" / "main_compiler.py"
        if not main_compiler.is_file():
            print(f"ERROR: Missing main compiler: {main_compiler}", file=sys.stderr)
            return 1

        data_raw = OUT / "data-raw.txt"

        main_env = os.environ.copy()
        main_env["PYTHONPATH"] = str(DATA)

        main_cmd = [
            sys.executable, "-m", "curation.compilers.main_compiler",
            "--heterophony1", str(DATA / "heterophony1.list"),
            "--heterophony2", str(DATA / "heterophony2.list"),
            "--heterophony3", str(DATA / "heterophony3.list"),
            "--phrase_freq", str(phrase_freq),
            "--bpmf_mappings", str(DATA / "BPMFMappings.txt"),
            "--bpmf_base", str(DATA / "BPMFBase.txt"),
            "--punctuations", str(DATA / "BPMFPunctuations.txt"),
            "--symbols", str(DATA / "Symbols.txt"),
            "--macros", str(DATA / "Macros.txt"),
            "--output", str(data_raw),
        ]

        main_result = subprocess.run(
            main_cmd,
            cwd=str(DATA),
            env=main_env,
            check=False,
        )
        if main_result.returncode != 0:
            print(
                f"ERROR: main_compiler failed with exit code {main_result.returncode}",
                file=sys.stderr,
            )
            return main_result.returncode

        if not data_raw.is_file():
            print("ERROR: data-raw.txt was not generated.", file=sys.stderr)
            return 1

        # ------------------------------------------------------------------
        # 5. Run postprocess to produce data.txt
        # ------------------------------------------------------------------
        postprocess = DATA / "curation" / "compilers" / "postprocess.py"
        if not postprocess.is_file():
            print(f"ERROR: Missing postprocess: {postprocess}", file=sys.stderr)
            return 1

        data_txt = OUT / "data.txt"
        postprocess_directive = DATA / "Postprocess.txt"

        post_env = os.environ.copy()
        post_env["PYTHONPATH"] = str(DATA)

        post_cmd = [
            sys.executable, "-m", "curation.compilers.postprocess",
            "--input", str(data_raw),
            "--directive", str(postprocess_directive),
            "--output", str(data_txt),
        ]

        post_result = subprocess.run(
            post_cmd,
            cwd=str(DATA),
            env=post_env,
            check=False,
        )
        if post_result.returncode != 0:
            print(
                f"ERROR: postprocess failed with exit code {post_result.returncode}",
                file=sys.stderr,
            )
            return post_result.returncode

        if not data_txt.is_file():
            print("ERROR: data.txt was not generated.", file=sys.stderr)
            return 1

        print("Dictionary generation complete.")

    # ------------------------------------------------------------------
    # 6. Compile native engine probe
    # ------------------------------------------------------------------
    engine_dir = ROOT / "Source" / "Engine"
    probe_src = ROOT / "Tools" / "AFM" / "EngineProbe.cpp"
    probe_bin = OUT / "engine-probe"

    if not probe_src.is_file():
        print(f"ERROR: Missing probe source: {probe_src}", file=sys.stderr)
        return 1

    # Check if probe is up to date
    engine_sources = [
        probe_src,
        engine_dir / "AssociatedPhrasesV2.cpp",
        engine_dir / "ByteBlockBackedDictionary.cpp",
        engine_dir / "McBopomofoLM.cpp",
        engine_dir / "MemoryMappedFile.cpp",
        engine_dir / "ParselessPhraseDB.cpp",
        engine_dir / "ParselessLM.cpp",
        engine_dir / "PhraseReplacementMap.cpp",
        engine_dir / "UTF8Helper.cpp",
        engine_dir / "UserOverrideModel.cpp",
        engine_dir / "UserPhrasesLM.cpp",
        engine_dir / "VariantAnnotator.cpp",
        engine_dir / "Mandarin" / "Mandarin.cpp",
        engine_dir / "gramambular2" / "reading_grid.cpp",
    ]

    # Also include header files that may affect the build
    engine_headers = [
        engine_dir / "AssociatedPhrasesV2.h",
        engine_dir / "ByteBlockBackedDictionary.h",
        engine_dir / "McBopomofoLM.h",
        engine_dir / "MemoryMappedFile.h",
        engine_dir / "ParselessPhraseDB.h",
        engine_dir / "ParselessLM.h",
        engine_dir / "PhraseReplacementMap.h",
        engine_dir / "UTF8Helper.h",
        engine_dir / "UserOverrideModel.h",
        engine_dir / "UserPhrasesLM.h",
        engine_dir / "VariantAnnotator.h",
    ]

    all_engine_files = engine_sources + engine_headers

    need_compile = True
    if probe_bin.is_file():
        max_engine_mtime = max(
            f.stat().st_mtime for f in all_engine_files if f.is_file()
        )
        probe_mtime = probe_bin.stat().st_mtime
        if probe_mtime >= max_engine_mtime:
            need_compile = False

    if not need_compile:
        print("Engine probe is up to date. Skipping compilation.")
    else:
        print("Compiling engine probe...")

        compile_cmd = [
            "clang++",
            "-std=c++20",
            "-O2",
            "-I", str(engine_dir),
        ]
        compile_cmd.extend(str(f) for f in engine_sources)
        compile_cmd.extend(["-o", str(probe_bin)])

        compile_result = subprocess.run(
            compile_cmd,
            check=False,
        )
        if compile_result.returncode != 0:
            print(
                f"ERROR: Engine probe compilation failed with exit code {compile_result.returncode}",
                file=sys.stderr,
            )
            return compile_result.returncode

        if not probe_bin.is_file():
            print("ERROR: engine-probe binary was not generated.", file=sys.stderr)
            return 1

        print("Engine probe compilation complete.")

    print("AFM build finished successfully.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
