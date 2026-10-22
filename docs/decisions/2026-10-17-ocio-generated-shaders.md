# OpenColorIO as generated shaders, not a linked library — October 17, 2026

Plan: [video-10bit-color-pipeline.md](../../plans/active/video-10bit-color-pipeline.md), Task 10 (Phase B2, decision only). Builds on the Task 9 result in the [compositor decision record](2026-10-16-10bit-compositor.md#task-9-result-opencolorio-shaders-phase-b1).

## Context

V-Log footage needs a camera input transform and a display transform. OpenColorIO (OCIO, BSD-3) is the reference implementation of both. There are two ways to use it:

- **B1, generated shaders (shipped in Task 9).** PyOpenColorIO, run offline from a pinned venv, writes Metal shader text and lookup tables for a fixed set of transforms into `OCIOGeneratedShaders.swift`. The app compiles that text at run time. OCIO is not part of the build.
- **B2, linked library.** The app links OCIO's C++ library and asks it for processors at run time, from any config, including a user's own `.ocio` file.

Facts on the target Mac (8 GB M1), checked on October 16 and 17, 2026:

- Only the Command Line Tools are installed (`xcode-select -p` is `/Library/Developer/CommandLineTools`). There is no `cmake`, no `xcodebuild`, and no `metal` compiler. Swift is 6.4.
- OCIO builds with CMake. Its library depends on yaml-cpp, pystring, Imath, minizip-ng with zlib, and expat. Homebrew's bottle (now 2.6.0) also pulls in little-cms2 and OpenEXR. Homebrew bottles are dynamic libraries for the local Homebrew prefix, so the app bundle cannot ship them.
- The project's rule is no third-party packages, with `Package.swift` unchanged (stated in the proxy plan's constraints and carried into this milestone as Decision 1).
- OCIO's API is C++. Calling it directly from Swift needs C++ interoperability turned on (`-cxx-interoperability-mode=default`) for the target that imports it and for every target that imports that one, tests included. That changes how the whole app compiles.
- Task 9 showed that B1 is accurate enough. On 4 096 samples per transform, the shaders stay within 1e-3 of OCIO's CPU processor (0.2% above 1). Gate G4 on real V-Log frames reached 0.49 of that limit.

## Decision

1. **Keep B1.** The app ships OCIO-generated shader text and tables, with the BSD-3 notice, and links nothing. `scripts/ocio/generate-shaders.py` is the only place OCIO runs. It is rerun by hand when the pinned version, the config or the transform list changes. A unit test checks that the generated file's recorded script hash matches the script.
2. **New transforms go through the generator.** For a new camera (such as Apple Log in Task 13) or another view (such as ACES 1.3 if G8 asks for it), add an entry to the script's transform list, regenerate, and extend the golden data. This is cheap and keeps the GPU-against-CPU tests.
3. **B2 is deferred.** Nothing is linked in this milestone.

**Trigger for B2.** The user needs color management that cannot be known when the app is built:

- loading their own `.ocio` config (a facility or colorist pipeline),
- camera input transforms beyond the generated set that they pick at run time, or
- transforms with dynamic properties (OCIO's exposure/contrast or grading uniforms) that must change per frame.

A request for one more fixed camera or view is not a trigger. That is Decision 2.

**The B2 path, when triggered:**

1. A script (`scripts/ocio/build-static.sh`) builds OCIO and its dependencies (yaml-cpp, pystring, Imath, minizip-ng with zlib, expat) as static arm64 libraries from pinned, hash-checked source archives. It turns off OpenEXR, little-cms2, the apps and the Python bindings. It needs CMake, so it runs on a build machine or in CI, or installs CMake into a throwaway prefix first. It never runs on the target Mac's system.
2. A small C shim (`ocio_shim.h`/`.cpp`) exposes only what the app uses: load a config, create a processor, get MSL shader text and tables, and apply on the CPU for tests. Swift imports a C header, so C++ interop stays off.
3. The libraries and the shim go into an XCFramework, used as a SwiftPM `binaryTarget` with a checksum. `xcodebuild -create-xcframework` needs Xcode. Without Xcode, the XCFramework has to be assembled by hand (an `Info.plist` and a library folder per platform), and that must be verified first. Adding the target changes `Package.swift`, so the owner must approve an exception to the no-packages rule at that point.
4. Notices for OCIO and each static dependency go into `Resources/ThirdPartyNotices/`.
5. The runtime path still asks OCIO for MSL and compiles it with `MetalPipelineCache`, the same as B1. Only where the shader text comes from changes. The generated transforms stay as the fallback and as the tests' reference.

## Alternatives considered

- **Link OCIO now (B2 today).** Rejected. It would break the no-packages rule and could not be built on the target Mac. It also turns on C++ interop or adds a shim with no user need behind it. B1 already meets the accuracy target.
- **Homebrew's OCIO dylib.** Rejected for shipping. It depends on the local Homebrew prefix and its other bottles, so it does not work in a distributable app bundle.
- **Write the transforms by hand in Metal.** Rejected. The V-Log curve is simple, but the ACES 2.0 output transform (JMh tone scale, chroma and gamut compression, cusp tables) is large and easy to get subtly wrong. Generated code plus golden data from OCIO itself gives a reference to test against.
- **Bake everything into 3D LUTs.** This is not a replacement. It loses the scene-linear grading step and the unclamped highlights. But it stays open as a speed-up for the ACES output transform, if Task 11 needs it (about 15 ms per 4K frame on the M1, measured in Task 9).

## Affected contracts

None change. The generated-shader contract from Task 9 stays: `OCIOGeneratedShaders.swift` is generated, never edited by hand. `Tests/Fixtures/ocio-golden.json` comes from the same run. `scripts/ocio/requirements.txt` pins OCIO 2.5.2 with hashes. Going to B2 later would add a `binaryTarget` and a notices set. Projects would not be affected, because `ColorInputTransform` stores a choice, not shader text.

## Migration plan

None for this decision. If B2 is triggered, the steps above come first as their own plan with a spike: build the static libraries, assemble the XCFramework without Xcode, and check that SwiftPM accepts it. User-config support follows.

## Verification

This is a decision record; there is no code to verify. Tested facts behind it: the Task 9 suites (`OCIOGeneratedSourceTests`, `OCIOShaderTests`) and gate G4 (`RealVideoOCIOTests`). Toolchain facts were checked on October 17, 2026: no `cmake`, no `xcodebuild`, no `metal`, Swift 6.4, Homebrew `opencolorio` 2.6.0 and its dependencies. B2's XCFramework-without-Xcode step is NOT VERIFIED. It is the first thing a B2 spike must show.
