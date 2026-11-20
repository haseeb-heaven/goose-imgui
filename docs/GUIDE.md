# goose-imgui guide

How the binding is put together, why it is shaped the way it is, and how to work on it.
The [README](../README.md) is the introduction; this is the part that saves you an
afternoon when something does not line up.

## 1. What talks to what

```
your program (Goose)
   │  import imgui from "<repo>@<ref>"       typed API: imgui.goose, src/widgets.goose
   ▼
raw.goose                                  one extern fn per C entry point
   │  extern fn igs_slider_f64(...)        (generated: scripts/generate_bindings.py)
   ▼
native/generated/igs_api.cpp               C wrapper, one per function
   │  → ImGui_SliderFloatEx(...)
   ▼
native/cimgui/                             dear_bindings' C API over Dear ImGui
   │
   ├── Dear ImGui 1.93.0 (docking)         native/cimgui/imgui/
   ├── imgui_impl_sdl3                     platform: input, clipboard, DPI, viewports
   └── imgui_impl_sdlgpu3                  renderer: Metal / Vulkan / D3D12 via SDL_GPU
                                            ▲
native/goose_imgui_shim.cpp                 │  the hand-written half: values, buffers,
  (speaks only the C API)  ─────────────────┘  PNG, fonts, canvas, dock building
native/goose_imgui_internal.cpp             the only place that includes imgui_internal.h
```

Two rules keep that picture true:

* **`native/goose_imgui_internal.cpp` is the only file that includes `imgui.h` or
  `imgui_internal.h`** (beyond the vendored sources). It is where the DockBuilder, style
  scaling and viewport flags live — the parts dear_bindings does not expose.
* **The shim speaks only the C API** (`dcimgui.h`). If a feature needs a C++-only symbol,
  it goes into `goose_imgui_internal.cpp` and is called from the shim.

Rendering is deliberately not the backend's job: ImGui draws into its own RGBA8 texture
(`igs_end_frame`), which is blitted to the swapchain in windowed mode and read back for
`screenshot`. That is what makes offscreen mode and windowed mode the same code path.

## 2. The ABI rules this binding is built on

Goose's FFI is small, exact and worth knowing before touching the shim:

| Goose | C | Consequence for this binding |
|---|---|---|
| `u8[:]` | `struct { uint8_t *data; int64_t len; }` | strings cross as slice structs (`igs_u8s`); the shim copies to a NUL-terminated `std::string` with `zstr()` |
| `f32[:]`, `f64[:]` | same, with `float *`/`double *` | plots and textures pass a pointer and a length |
| `T&` | `T *` | every `out` parameter is a pointer; `igs_checkbox(label, bool *v)` |
| `bool` | `uint8_t` | C `bool` parameters are `uint8_t` in the ABI |
| `struct` | **packed** (`#pragma pack(1)`) | see below — this is the one that bites |
| function values | compile time only | callbacks stay in Goose; no C callback tables, no function pointers |
| `T[..n]` | `struct { uint8_t len; T e[n]; }`, packed | a field array is at an arbitrary byte offset |

### The packed-struct rule

A fixed array inside a Goose struct is a one-byte length followed by the elements, and the
struct itself is packed. So in

```goose
struct State { name: u8[..32], colour: f64[..3] }
```

`colour`'s three doubles start at byte **33** — not 8-byte aligned, and one byte past where
a C programmer would guess. Anything that takes `&state.colour[0]` and writes through it
must:

1. never assume alignment (no `double *` vector stores), and
2. never write more elements than it was told about.

The shim does both by routing every read and write of caller memory through `memcpy`:

```cpp
double load_f64(const double *p) { double v; std::memcpy(&v, p, sizeof v); return v; }
void store_f64(double *p, double v) { std::memcpy(p, &v, sizeof v); }
```

A loop of plain `v[i] = f[i]` stores can be widened by the compiler into 16- or 32-byte
vector stores, which write past the last element — into the struct's next field, or into the
caller's stack canary. The colour widgets had exactly that bug: three components were
counted as four, so a three-element array got a fourth write. `memcpy` makes the copy size
the object's size, and the compiler cannot widen what it cannot see.

The regression test is `test_packed_fields` in `tests/test_imgui.goose`: it edits a colour,
drags a component and plots a curve from a packed struct and then checks the guard field
behind the array is untouched.

### Other consequences

* **A pointer to a multi-component value is a pointer to the first of `n`**, and `n` is
  always passed explicitly: `igs_slider_f64_n(label, v, n, lo, hi)`, `igs_color_edit(label,
  v, n)`. `n` is clamped (2..4 for sliders, 3..4 for colours) before anything is read.
* **Growable fields come last** in a struct, and a struct may have only one
  (`examples/node_graph` keeps two fixed arrays with counts instead).
* **Mutually recursive functions need `recursive fn`** — the calculator's expression
  parser is written that way.
* **`defer` runs on every exit**, which is why `window { }`, `child { }` and `table { }`
  can be closures: the block is a function value and `defer` closes the frame even if the
  body returns early.
* **A trailing block is an extra type argument, not an argument position.** Goose strips
  function values before matching a call's arguments (`ValueArgNodes` in `src/ast.h`), so
  a block can only bind a *generic parameter the function does not declare*:

  ```goose
  fn window<F>(title: const u8[:], flags: i64) {     // no `body: F` parameter
      if begin_window(title, flags) { defer end_window(); F(); }
  }
  imgui::window("settings", imgui::ALWAYS_AUTO_RESIZE) { imgui::text("hi"); }
  ```

  Writing `fn window<F>(title: const u8[:], body: F)` and calling it as
  `window("settings") { }` fails with *too few arguments: 1 given, 2 needed* — the block
  is not counted, so `body` is simply never filled. Every closing helper in this package
  follows the shape above.

## 3. Adding a wrapper

Suppose you want `ImGui::SetNextItemAllowOverlap` in the typed API.

1. **If the C API has it already**, it is in `raw.goose` as `raw::igs_set_next_item_allow_overlap`.
   Wrap it in `imgui.goose`:

   ```goose
   fn allow_overlap() {
       raw::igs_set_next_item_allow_overlap();
   }
   ```

   Nothing else to do: the wrapper was generated from the metadata.

2. **If it needs a value type the C API does not take** (an `f64`, a `bool&`, a
   `const u8[:]`), add it to the shim. Write the declaration in
   `native/goose_imgui_shim.h` with the Goose signature directly above it:

   ```cpp
   // goose: fn igs_center_next_window(x: f64, y: f64)
   void igs_center_next_window(double x, double y);
   ```

   implement it in `native/goose_imgui_shim.cpp`, then:

   ```sh
   python3 scripts/generate_bindings.py
   ```

   The `extern fn` appears in `raw.goose` and the C wrapper in `native/generated/`. The
   hand-written signature wins if a metadata wrapper of the same name exists, so a shim
   declaration can also *replace* a generated one.

3. **If it needs `imgui_internal.h`**, put the implementation in
   `native/goose_imgui_internal.cpp` (declared in `goose_imgui_internal.h`) and expose it
   through the same `// goose:` mechanism.

`scripts/generate_bindings.py --check` fails when `raw.goose` or `native/generated/` no
longer match their inputs, so a forgotten regeneration is caught by `scripts/run_tests.sh`.

### What the generator skips, and why

The generator walks every function in the metadata and skips:

* **variadic functions** (`ImGui::Text`, `ImGui::Log`) — Goose can format instead.
* **the `T*` value widgets** (`ImGui_SliderFloat`, `ImGui_InputInt`, …) — the `f64`/`i64`
  shim versions replace them, so a program never sees an out-parameter it cannot type.
* **text-input buffer functions** — they need a writable, NUL-terminated buffer and a
  capacity, which the shim's `input_text` family handles.
* **frame functions** (`NewFrame`, `Render`) — the shim owns the frame, including the
  target texture, the blit and the screenshot.
* **draw-list primitives** — the shim's `igs_draw_list_*` take plain coordinates instead
  of `ImVec2`.

Everything else is bound, including the docking, table, tab, multi-select and drag-drop
APIs, so `raw::` is a complete escape hatch.

## 4. Frames, windows and the first frame

```goose
while imgui::frame() {          // polls events, starts a frame, returns false when quitting
    imgui::window("main") { ... }
    imgui::end_frame();         // renders: target texture, blit, present
}
imgui::shutdown();              // or `defer imgui::shutdown()` right after init
```

* `init` runs **one warm-up frame** that is never shown. Dear ImGui bakes glyphs lazily, so
  this measures the printable ASCII range up front: a program's first visible frame draws
  text from an atlas that already exists instead of baking it mid-frame.
* A window with no explicit size is sized from the *previous* frame's content, so a window
  that appears for the first time is one frame behind. Programs that render a single frame
  (screenshots, tests) should set a size: `set_next_window_size(w, h, imgui::ALWAYS)`.
* `igs_atlas_info` reports the font atlas size and status; `igs_atlas_dump(path)` writes it
  as a PNG, which is the fastest way to see whether a font loaded.
* Style is context-wide: apply `dark_theme()`/`light_theme()` when the choice changes, not
  every frame.
* Ask about widgets: `metrics_render_vertices()` after `end_frame()` is 0 on a frame that
  drew nothing (which is what a mis-sized window looks like).

## 5. Docking and viewports

The docking branch is on, `ImGuiConfigFlags_DockingEnable` is set at init, and two layers
are exposed:

```goose
let dock = imgui::dockspace_over_viewport();     // fills the window with a dockspace
imgui::dock_build(dock, 1280.0, 720.0, 1);       // 1: left column, 2: right, 3: bottom
imgui::dock_window("inspector", 1);              // puts a window in that slot (first frame)
imgui::dock_finish();
```

`dock_build`/`dock_window`/`dock_finish` live in `goose_imgui_internal.cpp` (they are
DockBuilder calls), and are meant to be run once, on the first frame.

Multi-viewport (windows escaping the main window) is opt-in at runtime:

```goose
imgui::enable_viewports(true);   // after init; the platform backend does the rest
imgui::render_platform_windows(); // after end_frame, once per frame
```

Viewports are a platform feature: on macOS a dragged-out window is a real NSWindow, and
offscreen mode has none. Keep viewport calls behind `!imgui::is_offscreen()` if a program
has to work in both modes.

## 6. Fonts

At init the shim adds a font in this order:

1. `IGS_FONT=/path/to/font.ttf` in the environment, if the file is readable;
2. a list of system fonts (Arial, Verdana, DejaVu, Liberation, Segoe UI, …);
3. nothing at all — Dear ImGui's built-in bitmap font.

`IGS_FONT_BUILTIN=1` skips both and keeps the built-in font, which is what you want for a
byte-for-byte reproducible screenshot on another machine. `imgui::load_font(path, size)`
adds another font at runtime and returns false (with `imgui::error()` set) if the file
cannot be read; the previously loaded font stays current, so a failed load is not fatal.

DPI: `imgui::dpi_scale()` reports the window's pixel density, `display_width()` is the
size in *points* (what windows are laid out in), and the render target is the size in
*pixels*. On a retina display the same demo lays out identically and renders sharper.

## 7. Offscreen rendering and screenshots

```goose
imgui::init_offscreen(1280, 720);   // no window, no display, no input
while imgui::frame() { ... ; imgui::end_frame(); }
imgui::screenshot("frame.png");     // reads the target back and writes a PNG
```

In offscreen mode the platform backend is not started, the drawing space is exactly the
target's pixels, and `DeltaTime` is a fixed 1/60 so animations are reproducible. Input
functions answer "no button", the clipboard has no owner, and viewports are disabled —
everything a headless run should do.

The PNG writer is part of the shim: per-scanline filters (choosing the best of the five by
the standard heuristic) and a small fixed-Huffman deflate with a hash-chain matcher. It
needs no image or compression library, produces the same bytes on every machine, and turns
a 2.5 MB raw frame into an 90 KB file.

`scripts/screenshots.sh` is the whole pipeline: build each demo, run it for thirty frames
with `--shot`, and check the file is not empty.

## 8. Sharp edges

* **Widgets that write through a pointer need a real array.** `imgui::slider("x", v[0], …)`
  on a struct field is fine (the shim is careful about alignment), but the array must have
  room for the components asked for: three for `color_edit(…, 3)`, `n` for `slider_n`.
* **Same-label widgets need unique IDs.** Use `"##suffix"` in the label, as in ImGui.
* **`input_text` needs a NUL-terminated buffer** with room for the terminator; a
  `imgui::text_buffer(n)` has exactly `n` bytes, so a string of `n` characters is truncated
  to `n - 1`. `imgui::text_of` and `imgui::set_text` handle the terminator for you.
* **`text()` takes one string.** Build the line with `str("a ", value)`; the C API is
  variadic and the binding is not.
* **Scrolling, cursor and window queries answer for the window being built.** The binding
  tracks whether a window is open and answers 0 outside one rather than reading through a
  null current window.
* **A window that quits must still be closed**: `imgui::quit()` is checked at the top of
  the next `frame()`, and every `begin_*` has its matching `end_*` via `defer`.
* **`let x = array[i]` copies the element.** To change one in place — a node being
  dragged, a row whose checkbox was clicked — take a reference: `let x = &array[i]`.
  Writing to the copy compiles, runs, and changes nothing, which is exactly the kind of
  bug that looks like a widget doing nothing. The two cases that need it in the examples
  are `node_graph`'s drag and inspector, and `system_monitor`'s process rows.
* **The same goes for a slice of a fixed array field**: `p.name` passed to C writes
  through only when `p` is a place (an index or a reference), because a field read from a
  copied struct is a value.

## 9. A program with C of its own

`examples/system_monitor` reads the machine it runs on, and that means system calls the
Goose side cannot make. Its C is one file, compiled with the program by a sidecar beside
the root file (docs/packages.md §3):

```
examples/system_monitor/main.goose    extern fn sys_sample(); ...  -- what it may call
examples/system_monitor/main.build    c_sources = ["sysinfo.c"];
examples/system_monitor/sysinfo.c     mach/sysctl/libproc on macOS, /proc on Linux
```

`sys_sample()` refreshes everything and walks the process list; `sys_process(i, name, ...)`
fills 40-byte names and the CPU rate of the top rows. The CPU rate is a delta of each
pid's CPU time against the previous sample, which is why the monitor calls `sys_sample`
once per frame rather than once per redraw.

A `u8[:]` parameter arrives in C as `{data, len}` and a `T&` as a pointer, the same rules
as the binding's own shim, so the store helpers there (`memcpy` per element) are the right
pattern here too: a field of a packed struct is not aligned, and the last element is the
last element.

## 10. Working on the package

```sh
sh scripts/run_tests.sh            # bindings check, JIT checks, native checks
sh scripts/screenshots.sh          # rebuild the examples and their screenshots
python3 scripts/generate_bindings.py --check
clang-format -i native/goose_imgui_shim.cpp native/goose_imgui_internal.cpp \
                 native/goose_imgui_shim.h native/goose_imgui_internal.h
```

`native/cimgui/` is vendored and never formatted or edited: it is regenerated by
dear_bindings from the Dear ImGui release named in `native/cimgui/imgui/imgui.h`.

Running a demo with a real window is the check the tests cannot do:

```sh
goose build examples/showcase/main.goose && ./examples/showcase/main
```

The window opens, the demo runs until you close it, and input, clipboard, DPI and
viewports are all live.
