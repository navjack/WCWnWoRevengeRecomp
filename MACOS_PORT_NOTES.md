# macOS port notes — WCW/nWo Revenge: Recompiled

Builds and runs natively on Apple Silicon (arm64), rendering through rt64's **Metal** backend.
Installed as `RevengeRecompiled.app`.

## Changes made

**`CMakeLists.txt`** — four Apple branches added:
- `enable_language(OBJC OBJCXX)` and a default `CMAKE_OSX_DEPLOYMENT_TARGET` of 11.0
- `add_compile_options(-include stdlib.h)` for the hlslpp `labs` issue
- DXC: use the arm64 `dxc-macos` binary and set `ZLIB_PATH` in the parent scope
- `find_package(SDL2 REQUIRED)`, link `SDL2::SDL2`, and `-Wl,-stack_size,0x1000000`

**`src/main.cpp`** — `create_window()` returns a real `{NSWindow*, CAMetalLayer*}` handle on
Apple and sets `SDL_WINDOW_METAL`. Before this the app crashed on startup in
`plume::CocoaWindow::CocoaWindow` on the Gfx Thread.

**`tools/make_macos_app.sh`** (new) — builds the .app: generates an `.icns` via `sips`/`iconutil`,
copies `assets/` and `recompcontrollerdb.txt` into `Contents/Resources` (on Apple
`recompui::file::get_program_path()` returns the bundle Resources dir), vendors the four Homebrew
dylibs into `Contents/Frameworks`, rewrites install names, strips Homebrew rpaths, and ad-hoc
re-signs (`install_name_tool` invalidates arm64 signatures).

## Build

```bash
cmake -B build-macos -DCMAKE_BUILD_TYPE=Release .
cmake --build build-macos -j8
./tools/make_macos_app.sh
```

## Known issues

Crashes on quit — see the shared note below. The game itself plays fine; saves are flushed on a
10ms debounce in `pi.cpp`, so they are safe. Force Quit is the workaround.

## Shared background (applies to every rt64-based port here)

**hlslpp `labs`** — rt64 forces `HLSLPP_SCALAR` on Apple Silicon and its `scalar.h` calls
`labs()` without including `<stdlib.h>`. Fix: `add_compile_options("SHELL:-include stdlib.h")`.
The `SHELL:` prefix matters — without it CMake de-duplicates the repeated `-include` token and
collapses it with any other `-include`, turning the following header into a bare input file.

**Window handle** — ultramodern's `WindowHandle` is platform-variant. On Apple it is
`{NSWindow*, CAMetalLayer*}`, and plume's Metal backend casts `.view` straight to
`CA::MetalLayer*`. Passing the `SDL_Window*` instead crashes in `objc_msgSend` the moment the
render thread starts. Correct form:

```cpp
flags |= SDL_WINDOW_METAL;
SDL_MetalView metal_view = SDL_Metal_CreateView(window);
return ultramodern::renderer::WindowHandle{ wmInfo.info.cocoa.window,
                                            SDL_Metal_GetLayer(metal_view) };
```

**Bundling rules learned the hard way**
- `codesign` treats *any* non-Mach-O file in `Contents/MacOS` as unsigned nested code and
  refuses to seal the bundle. Data files belong in `Contents/Resources`.
- Strip absolute Homebrew `LC_RPATH` entries. These builds bake `/opt/homebrew/lib` in as the
  **first** rpath; dyld searches rpaths in order, so `@rpath/libSDL2-2.0.0.dylib` resolves to
  Homebrew and the vendored copies are never loaded. `otool -L` still looks correct because it
  only shows the `@rpath` load commands — verify with
  `otool -l <bin> | grep -A2 LC_RPATH` instead.
- sdl2-compat `dlopen`s `libSDL3.dylib` at load time. Dependency walkers (including CMake's
  `fixup_bundle`) never see it, so it must be vendored explicitly or the app aborts in
  `dllinit` with "Failed loading SDL3 library" before `main()` runs.
- Test the **installed** copy from `/Applications`, not the build directory. A writable build
  dir hides any bug involving a read-only or relative config path.

**N64Recomp is per-project** — every project pins its own recompiler under `lib/N64Recomp` or
`lib/N64ModernRuntime/N64Recomp`. Build *that* copy and run it from the repo root (the build
shells out to a literal `./N64Recomp <game>.toml`). Reusing another project's binary appears to
work and emits a plausible file count, but the generated code targets a different runtime API
and fails much later with errors like `no member named 'nullopt' in namespace 'std'` inside
`recomp_overlays.inl`. Regenerate after `rm -rf RecompiledFuncs RecompiledPatches`.

**Known upstream issue (not fixed)** — rt64/plume's Metal backend over-releases metal-cpp
objects. It shows up as a crash on quit in the "RT64 Workload" thread inside `objc_release` /
`objc_autoreleasePoolPop`, with memory-poison values (`0xa1a1a1a1`, `0xa3a3a3a3a3a3a3a3`) in the
registers. Adding a per-iteration `NS::AutoreleasePool` to rt64's render thread loop makes it
**worse** — the crash moves to ~0.5s after launch and macOS reports "API MISUSE: Over-release of
an object", proving the missing pool was masking a genuine double-release rather than causing
it. Do not re-attempt that fix; the real bug is unbalanced retain/release inside plume.
