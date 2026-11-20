// goose-imgui: Dear ImGui for the Goose programming language.
//
// This is the module a program imports (`import imgui;`): the window and frame
// loop over SDL3 + SDL_GPU, the widgets, text, tables, trees, popups, menus,
// docking and canvas primitives, with Goose's own shapes at the boundary.
//
// Shape of the API, and why:
//   * Text parameters are `const u8[:]`, so `"Hello"` and `str("n = ", n)`
//     both work. Nothing is NUL-terminated by the caller and nothing is
//     allocated by them: the shim copies into a C string for the one call.
//   * Value widgets take Goose's `f64`/`i64` (what a literal is), not
//     Dear ImGui's `float`/`int`, so `var gain = 1.0;` is a slider target
//     without a cast.
//   * A scope is explicit: `begin_window`/`end_window` pairs, or the
//     `window("Title") { ... }` form, which ends the window with `defer`
//     however the block exits. `return` inside the block returns from your
//     own function, as a block in Goose always does.
//   * Raw pointers and handles are `u64` and only appear where they must
//     (a draw list, a texture). A `DrawList` value is a plain `u64`.
//
// The full Dear ImGui surface, mechanically bound, is in `raw.goose`
// (`import imgui.raw;`); composite widgets are in src/widgets.goose
// (`import imgui.src.widgets;`).

namespace imgui;

import std;
import raw;
import src.widgets;

// --- flags re-exported under short names --------------------------------
// (The whole set, with Dear ImGui's own spelling in snake_case, is raw's.)

let NONE: i32 = 0;
let NO_TITLE_BAR: i32 = 1024 - 1023;          // raw::window_flags_no_title_bar
let NO_RESIZE: i32 = raw::window_flags_no_resize;
let NO_MOVE: i32 = raw::window_flags_no_move;
let NO_SCROLLBAR: i32 = raw::window_flags_no_scrollbar;
let NO_SCROLL_WITH_MOUSE: i32 = raw::window_flags_no_scroll_with_mouse;
let NO_COLLAPSE: i32 = raw::window_flags_no_collapse;
let ALWAYS_AUTO_RESIZE: i32 = raw::window_flags_always_auto_resize;
let NO_BACKGROUND: i32 = raw::window_flags_no_background;
let NO_SAVED_SETTINGS: i32 = raw::window_flags_no_saved_settings;
let MENU_BAR: i32 = raw::window_flags_menu_bar;
let NO_TITLE_BAR_AND_MENU: i32 = NO_TITLE_BAR | MENU_BAR;
let HORIZONTAL_SCROLLBAR: i32 = raw::window_flags_horizontal_scrollbar;

let ALWAYS: i32 = raw::cond_always;
let ONCE: i32 = raw::cond_once;
let FIRST_USE_EVER: i32 = raw::cond_first_use_ever;

let AUTO_RESIZE: i32 = raw::table_flags_sizing_stretch_prop;
let TABLE_BORDERS: i32 = raw::table_flags_borders | raw::table_flags_row_bg |
                          raw::table_flags_borders_inner_h | raw::table_flags_borders_outer_h |
                          raw::table_flags_borders_inner_v | raw::table_flags_borders_outer_v;
let TABLE_ROW_BG: i32 = raw::table_flags_row_bg;
let TABLE_RESIZABLE: i32 = raw::table_flags_resizable;
let TABLE_SCROLL_Y: i32 = raw::table_flags_scroll_y;
let TABLE_SIZING_FIXED_FIT: i32 = raw::table_flags_sizing_fixed_fit;
let WIDTH_STRETCH: i32 = raw::table_column_flags_width_stretch;
let WIDTH_FIXED: i32 = raw::table_column_flags_width_fixed;

let BORDERS: i32 = raw::child_flags_borders;
let CHILD_RESIZE_X: i32 = raw::child_flags_resize_x;
let CHILD_RESIZE_Y: i32 = raw::child_flags_resize_y;

let TAB_BAR_DEFAULT: i32 = 0;
let TAB_ITEM_SET_SELECTED: i32 = raw::tab_item_flags_set_selected;

let INPUT_CHARS_DECIMAL: i32 = raw::input_text_flags_chars_decimal;
let INPUT_CHARS_HEXADECIMAL: i32 = raw::input_text_flags_chars_hexadecimal;
let INPUT_CHARS_UPPERCASE: i32 = raw::input_text_flags_chars_uppercase;
let INPUT_ENTER_RETURNS_TRUE: i32 = raw::input_text_flags_enter_returns_true;
let INPUT_READ_ONLY: i32 = raw::input_text_flags_read_only;
let INPUT_ALLOW_TAB_INPUT: i32 = raw::input_text_flags_allow_tab_input;

let SLIDER_ALWAYS_CLAMP: i32 = raw::slider_flags_always_clamp;
let SLIDER_LOGARITHMIC: i32 = raw::slider_flags_logarithmic;
let SLIDER_NO_INPUT: i32 = raw::slider_flags_no_input;

let SELECTABLE_SPAN_ALL_COLUMNS: i32 = raw::selectable_flags_span_all_columns;
let SELECTABLE_ALLOW_DOUBLE_CLICK: i32 = raw::selectable_flags_allow_double_click;

let TREE_DEFAULT_OPEN: i32 = raw::tree_node_flags_default_open;
let TREE_SPAN_AVAIL_WIDTH: i32 = raw::tree_node_flags_span_avail_width;
let TREE_LEAF: i32 = raw::tree_node_flags_leaf;

let POPUP_NONE: i32 = 0;
let HOVERED_NONE: i32 = 0;
let HOVERED_DELAY_NORMAL: i32 = raw::hovered_flags_delay_normal;

// --- lifecycle ----------------------------------------------------------

// Opens a window and a GPU device: Metal on macOS, Vulkan on Linux, D3D12 or
// Vulkan on Windows, through SDL_GPU.
fn init(title: const u8[:], width: i64, height: i64) -> bool {
    return raw::igs_init(title, width, height, 0);
}

// flags: 1 full screen, 2 hidden (a window that renders but is not shown).
fn init(title: const u8[:], width: i64, height: i64, flags: i64) -> bool {
    return raw::igs_init(title, width, height, flags);
}

// Draws into a window and on a device the program already owns (an SDL3
// `SDL_Window*` and `SDL_GPUDevice*`, as u64). This is the hook for a program
// that creates its SDL3 window itself, or one built alongside goose_gfx's own
// SDL_GPU layer. The shim never destroys what it did not create.
fn attach(window: u64, device: u64) -> bool {
    return raw::igs_attach(window, device);
}

// A device and an offscreen RGBA8 render target, no visible window: for tests
// and for tools that only render to files.
fn init_offscreen(width: i64, height: i64) -> bool {
    return raw::igs_init_offscreen(width, height);
}

fn shutdown() {
    raw::igs_shutdown();
}

fn ready() -> bool {
    return raw::igs_ready();
}

// Why the last call that failed did, as text.
fn error() -> u8[>..] {
    var text: u8[>..] = [];
    text.resize(1024, 0);
    let n = raw::igs_error_into(text);
    text.resize(min(n, 1024));
    return text;
}

// The GPU backend in use: "vulkan", "metal" or "direct3d12".
fn driver() -> u8[>..] {
    var name: u8[>..] = [];
    name.resize(64, 0);
    let n = raw::igs_driver_into(name);
    name.resize(min(n, 64));
    return name;
}

// The Dear ImGui version this package was built against, e.g. "1.93.0".
fn version() -> u8[>..] {
    var v: u8[>..] = [];
    v.resize(32, 0);
    let n = raw::igs_version_into(v);
    v.resize(min(n, 32));
    return v;
}

fn sdl_window() -> u64 {
    return raw::igs_sdl_window();
}

fn sdl_device() -> u64 {
    return raw::igs_sdl_device();
}

fn is_offscreen() -> bool {
    return raw::igs_is_offscreen();
}

// How many frames have been ended since init.
fn frame_count() -> u64 {
    return raw::igs_frame_count();
}

// Pixels per display point: 2 on a Retina-class display.
fn dpi_scale() -> f32 {
    return raw::igs_dpi_scale();
}

fn dark_theme() {
    raw::igs_style_colors(true);
}

fn light_theme() {
    raw::igs_style_colors(false);
}

// The colour a frame starts from, before ImGui draws.
fn set_clear_color(r: f64, g: f64, b: f64) {
    raw::igs_set_clear_color(r as f32, g as f32, b as f32, 1.0);
}

fn set_clear_color(r: f64, g: f64, b: f64, a: f64) {
    raw::igs_set_clear_color(r as f32, g as f32, b as f32, a as f32);
}

// Loads a TrueType font as the UI font. init() already picks one of the
// system's fonts when there is one; this replaces it.
fn load_font(path: const u8[:], size_px: f64) -> bool {
    return raw::igs_load_font(path, size_px as f32);
}

// --- frames -------------------------------------------------------------

// Starts a frame. False means the program should stop: the window was closed,
// or quit() was called. Use it as a loop condition: `while imgui::frame() {`.
fn frame() -> bool {
    return raw::igs_new_frame();
}

// Ends the frame and shows it (or, offscreen, leaves it in the render target
// for screenshot()).
fn end_frame() {
    raw::igs_end_frame();
}

fn quit() {
    raw::igs_request_quit();
}

fn should_close() -> bool {
    return raw::igs_should_close();
}

// Seconds the last frame took.
// The system clipboard, when a platform layer is driving one: offscreen mode
// has no clipboard owner, so both calls do nothing there.
fn set_clipboard(text: const u8[:]) {
    raw::igs_set_clipboard(text);
}

fn clipboard() -> u8[>..] {
    var text: u8[..4096] = [0; 4096];
    let n = raw::igs_clipboard_into(text);
    var out: u8[>..] = [];
    for i in 0..n { out.push(text[i]); }
    return out;
}

fn delta_time() -> f32 {
    return raw::igs_delta_time();
}

fn fps() -> f32 {
    return raw::igs_io_fps();
}

// Seconds since the context started.
fn time() -> f64 {
    return raw::igs_get_time();
}

// The render target's size in pixels.
fn display_width() -> i64 {
    return raw::igs_display_width();
}

fn display_height() -> i64 {
    return raw::igs_display_height();
}

fn display_size() -> f32[2] {
    return [raw::igs_display_width(), raw::igs_display_height()];
}

// Reads the last frame back from the GPU and writes it as a PNG. Works in
// every mode; the file holds the frame most recently ended.
fn screenshot(path: const u8[:]) -> bool {
    return raw::igs_screenshot(path);
}

// --- windows ------------------------------------------------------------

// How many windows are open. Everything that asks Dear ImGui about "the
// current window" (scrolling, for one) needs one, and the C API would be
// reading through a null pointer without it, so the binding keeps the count
// and answers such questions itself while no window is open.
var window_depth: i64 = 0;

fn begin_window(title: const u8[:]) -> bool {
    return begin_window(title, 0);
}

// Dear ImGui requires the matching End() even when Begin() returns false: a
// collapsed or clipped window still pushes and pops the window stack. Since
// callers write `if begin_window(...) { ...; end_window(); }`, the close
// happens here instead, in the case the caller does not reach.
fn begin_window(title: const u8[:], flags: i64) -> bool {
    let open = raw::igs_begin(title, 0, flags as i32);
    if open {
        window_depth += 1;
    } else {
        raw::igs_end();
    }
    return open;
}

// A window with a close button whose state lives in `open`.
fn begin_window_open(title: const u8[:], open: bool&, flags: i64) -> bool {
    let shown = raw::igs_begin_open(title, open, flags);
    if shown {
        window_depth += 1;
    } else {
        raw::igs_end();
    }
    return shown;
}

fn end_window() {
    if window_depth > 0 { window_depth -= 1; }
    raw::igs_end();
}

// A window whose scope is the block:
//
//     imgui::window("Settings") {
//         imgui::text("hello");
//     }
//
// The block is a compile-time function value, so it is passed as the extra
// type argument `F` and called here; Goose does not count it among a call's
// argument positions (docs/reference.md §"Function values"). That is why
// these helpers declare no `body` parameter of their own.
fn window<F>(title: const u8[:]) {
    if begin_window(title, 0) {
        defer end_window();
        F();
    }
}

fn window<F>(title: const u8[:], flags: i64) {
    if begin_window(title, flags) {
        defer end_window();
        F();
    }
}

// A child region. Like Begin(), BeginChild() needs its EndChild() even when it
// returns false -- a child scrolled or clipped out of view still enters the
// window stack -- so this closes it whenever the caller will not reach its own
// `end_child()`. Without that, an offscreen child leaks one stack level every
// frame and Dear ImGui starts reporting "Missing End()".
fn begin_child(id: const u8[:], width: f64, height: f64) -> bool {
    return begin_child(id, width, height, 0, 0);
}

fn begin_child(id: const u8[:], width: f64, height: f64, flags: i64) -> bool {
    return begin_child(id, width, height, flags, 0);
}

// The full form: child flags (a border, a resize grip) and window flags (no
// scrollbar, no scrolling with the wheel) for a region that draws itself.
fn begin_child(id: const u8[:], width: f64, height: f64, child_flags: i64,
               window_flags: i64) -> bool {
    let open = raw::igs_begin_child(id, width as f32, height as f32, child_flags as i32,
                                    window_flags as i32);
    if !open { raw::igs_end_child(); }
    return open;
}

fn end_child() {
    raw::igs_end_child();
}

// A child region whose scope is the block, with no flags.
fn child<F>(id: const u8[:], width: f64, height: f64) {
    if begin_child(id, width, height) {
        defer end_child();
        F();
    }
}

fn child<F>(id: const u8[:], width: f64, height: f64, flags: i64) {
    if begin_child(id, width, height, flags) {
        defer end_child();
        F();
    }
}

fn set_next_window_pos(x: f64, y: f64, cond: i64) {
    raw::igs_set_next_window_pos(x as f32, y as f32, cond as i32);
}

fn set_next_window_pos(x: f64, y: f64, cond: i64, pivot_x: f64, pivot_y: f64) {
    raw::igs_set_next_window_pos_pivot(x as f32, y as f32, cond as i32, pivot_x as f32,
                                       pivot_y as f32);
}

// Collapses the next window to its title bar (or expands it again).
fn set_next_window_collapsed(collapsed: bool, cond: i64) {
    raw::igs_set_next_window_collapsed(collapsed, cond as i32);
}

fn set_next_window_size(x: f64, y: f64, cond: i64) {
    raw::igs_set_next_window_size(x as f32, y as f32, cond as i32);
}

fn set_next_item_width(width: f64) {
    raw::igs_set_next_item_width(width as f32);
}

// The size of the window's content area, in pixels.
fn content_avail() -> f32[2] {
    var w: f32 = 0.0;
    var h: f32 = 0.0;
    raw::igs_get_content_region_avail(w, h);
    return [w, h];
}

fn cursor_pos() -> f32[2] {
    var x: f32 = 0.0;
    var y: f32 = 0.0;
    raw::igs_get_cursor_pos(x, y);
    return [x, y];
}

fn cursor_screen_pos() -> f32[2] {
    var x: f32 = 0.0;
    var y: f32 = 0.0;
    raw::igs_get_cursor_screen_pos(x, y);
    return [x, y];
}

fn item_rect_size() -> f32[2] {
    var w: f32 = 0.0;
    var h: f32 = 0.0;
    raw::igs_get_item_rect_size(w, h);
    return [w, h];
}

fn calc_text_size(text: const u8[:]) -> f32[2] {
    var w: f32 = 0.0;
    var h: f32 = 0.0;
    raw::igs_calc_text_size(text, w, h);
    return [w, h];
}

fn text_line_height() -> f64 {
    return raw::igs_get_text_line_height();
}

fn frame_height() -> f64 {
    return raw::igs_get_frame_height();
}

// --- text ---------------------------------------------------------------

fn text(s: const u8[:]) {
    raw::igs_text(s);
}

fn text_colored(r: f64, g: f64, b: f64, a: f64, s: const u8[:]) {
    raw::igs_text_colored(r as f32, g as f32, b as f32, a as f32, s);
}

fn text_muted(s: const u8[:]) {
    raw::igs_text_disabled(s);
}

fn text_wrapped(s: const u8[:]) {
    raw::igs_text_wrapped(s);
}

fn label(name: const u8[:], value: const u8[:]) {
    raw::igs_label_text(name, value);
}

fn bullet(s: const u8[:]) {
    raw::igs_bullet_text(s);
}

// A tooltip on the item just submitted, once the mouse rests on it.
fn tooltip(s: const u8[:]) {
    raw::igs_tooltip(s);
}

fn separator_text(s: const u8[:]) {
    raw::igs_separator_text(s);
}

// A section title: the text and a rule under it.
fn heading(s: const u8[:]) {
    raw::igs_text(s);
    raw::igs_separator();
}

// --- layout -------------------------------------------------------------

fn spacing() {
    raw::igs_spacing();
}

fn same_line() {
    raw::igs_same_line();
}

// Starts the next item at an offset from the left edge of the content area,
// which is how a column of labels and a column of values line up.
fn same_line(offset: f64) {
    raw::igs_same_line_ex(offset as f32, -1.0);
}

fn new_line() {
    raw::igs_new_line();
}

fn separator() {
    raw::igs_separator();
}

fn dummy(width: f64, height: f64) {
    raw::igs_dummy(width as f32, height as f32);
}

fn indent() {
    raw::igs_indent();
}

fn unindent() {
    raw::igs_unindent();
}

fn begin_group() {
    raw::igs_begin_group();
}

fn end_group() {
    raw::igs_end_group();
}

fn begin_disabled(disabled: bool) {
    raw::igs_begin_disabled(disabled);
}

fn end_disabled() {
    raw::igs_end_disabled();
}

// --- buttons and toggles ------------------------------------------------

fn button(label: const u8[:]) -> bool {
    return raw::igs_button(label);
}

fn button(label: const u8[:], width: f64, height: f64) -> bool {
    return raw::igs_button_ex(label, width as f32, height as f32);
}

fn small_button(label: const u8[:]) -> bool {
    return raw::igs_small_button(label);
}

fn invisible_button(id: const u8[:], width: f64, height: f64) -> bool {
    return raw::igs_invisible_button(id, width as f32, height as f32, 0);
}

fn checkbox(label: const u8[:], value: bool&) -> bool {
    return raw::igs_checkbox(label, value);
}

fn radio_button(label: const u8[:], value: i64&, button_index: i64) -> bool {
    return raw::igs_radio_i64(label, value, button_index);
}

// --- sliders and drags (f64 and i64) ------------------------------------

fn slider(label: const u8[:], value: f64&, lo: f64, hi: f64) -> bool {
    return raw::igs_slider_f64(label, value, lo, hi);
}

fn slider(label: const u8[:], value: f64&, lo: f64, hi: f64, fmt: const u8[:]) -> bool {
    return raw::igs_slider_f64_fmt(label, value, lo, hi, fmt);
}

fn slider(label: const u8[:], value: i64&, lo: i64, hi: i64) -> bool {
    return raw::igs_slider_i64(label, value, lo, hi);
}

fn slider_angle(label: const u8[:], radians: f64&, lo_deg: f64, hi_deg: f64) -> bool {
    return raw::igs_slider_angle(label, radians, lo_deg, hi_deg);
}

fn drag(label: const u8[:], value: f64&, speed: f64) -> bool {
    return raw::igs_drag_f64_speed(label, value, speed);
}

fn drag(label: const u8[:], value: f64&, speed: f64, lo: f64, hi: f64) -> bool {
    return raw::igs_drag_f64(label, value, speed, lo, hi);
}

fn drag(label: const u8[:], value: i64&, speed: f64, lo: i64, hi: i64) -> bool {
    return raw::igs_drag_i64(label, value, speed, lo, hi);
}

fn input(label: const u8[:], value: f64&, step: f64, step_fast: f64) -> bool {
    return raw::igs_input_f64(label, value, step, step_fast);
}

fn input(label: const u8[:], value: i64&, step: i64, step_fast: i64) -> bool {
    return raw::igs_input_i64(label, value, step, step_fast);
}

// Two to four components, from the first of `n` values: `slider_n("xy", v[0], 2, 0.0, 1.0)`.
fn slider_n(label: const u8[:], value: f64&, n: i64, lo: f64, hi: f64) -> bool {
    return raw::igs_slider_f64_n(label, value, n, lo, hi);
}

fn drag_n(label: const u8[:], value: f64&, n: i64, speed: f64, lo: f64, hi: f64) -> bool {
    return raw::igs_drag_f64_n(label, value, n, speed, lo, hi);
}

fn input_n(label: const u8[:], value: f64&, n: i64) -> bool {
    return raw::igs_input_f64_n(label, value, n);
}

// --- colours ------------------------------------------------------------

// n is 3 for RGB or 4 for RGBA; the values are 0..1.
fn color_edit(label: const u8[:], value: f64&, n: i64) -> bool {
    return raw::igs_color_edit(label, value, n);
}

fn color_picker(label: const u8[:], value: f64&, n: i64) -> bool {
    return raw::igs_color_picker(label, value, n);
}

fn color_button(id: const u8[:], value: f64&) -> bool {
    return raw::igs_color_button(id, value);
}

// An ImGui packed colour (0xAABBGGRR), as the style colours and the drawing
// functions use.
fn color_u32(index: i32) -> u32 {
    return raw::igs_get_color_u32(index);
}

fn col_plot_lines() -> i32 {
    return raw::col_plot_lines;
}

fn col_plot_histogram() -> i32 {
    return raw::col_plot_histogram;
}

fn col_separator() -> i32 {
    return raw::col_separator;
}

fn col_text() -> i32 {
    return raw::col_text;
}

fn col_text_disabled() -> i32 {
    return raw::col_text_disabled;
}

fn col_button() -> i32 {
    return raw::col_button;
}

fn col_frame_bg() -> i32 {
    return raw::col_frame_bg;
}

fn col_window_bg() -> i32 {
    return raw::col_window_bg;
}

fn col_header() -> i32 {
    return raw::col_header;
}

fn push_style_color(index: i32, color: u32) {
    raw::igs_push_style_color(index, color);
}

fn pop_style_color() {
    raw::igs_pop_style_color();
}

// --- text input ---------------------------------------------------------

// A fixed-capacity text input. `buf` is the program's own byte array; the
// bytes up to the first NUL are the text. See widgets::text_field for the
// grow-once-then-edit form the examples use.
fn input_text(label: const u8[:], buf: u8[:], flags: i64) -> bool {
    return raw::igs_input_text(label, buf, flags);
}

fn input_text(label: const u8[:], buf: u8[:]) -> bool {
    return raw::igs_input_text(label, buf, 0);
}

fn input_text_with_hint(label: const u8[:], hint: const u8[:], buf: u8[:], flags: i64) -> bool {
    return raw::igs_input_text_with_hint(label, hint, buf, flags);
}

fn input_text_multiline(label: const u8[:], buf: u8[:], width: f64, height: f64, flags: i64) -> bool {
    return raw::igs_input_text_multiline_sized(label, buf, width as f32, height as f32, flags);
}

// A text buffer of `capacity` bytes, the state a text field needs.
fn text_buffer(capacity: i64) -> u8[>..] {
    var buf: u8[>..] = [];
    buf.resize(max(capacity, 2), 0);
    return buf;
}

// The text in a buffer: the bytes before its first NUL.
fn text_of(buf: u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    for i in 0..buf.len {
        if buf[i] == 0 { break; }
        out.push(buf[i]);
    }
    return out;
}

// Replaces the text in a buffer, keeping it NUL-terminated.
fn set_text(buf: u8[>..]&, s: const u8[:]) {
    let n = min(s.len, max(buf.len - 1, 0));
    for i in 0..n { buf[i] = s[i]; }
    buf[n] = 0;
}

// --- combo, progress, lists ---------------------------------------------

// A combo box over `items`, one string per element; `current` is the index.
fn combo(label: const u8[:], current: i64&, items: const u8[:][:]) -> bool {
    return raw::igs_combo(label, current, widgets::joined_z(items));
}

// The same combo from a NUL separated list, "one\0two\0three\0": no
// temporary array and no copying, so a large or fixed list costs nothing.
fn combo_z(label: const u8[:], current: i64&, items: const u8[:]) -> bool {
    return raw::igs_combo(label, current, items);
}

// Opening a modal is opening a popup under the name BeginPopupModal looks for.

fn progress(fraction: f64, width: f64, height: f64, overlay: const u8[:]) {
    raw::igs_progress_bar(fraction, width as f32, height as f32, overlay);
}

fn selectable(label: const u8[:]) -> bool {
    return raw::igs_selectable(label);
}

fn selectable(label: const u8[:], selected: bool, flags: i64) -> bool {
    return raw::igs_selectable_ex(label, selected, flags as i32, 0.0, 0.0);
}

// --- trees, collapsing headers, tabs ------------------------------------

fn tree_node(label: const u8[:]) -> bool {
    return raw::igs_tree_node(label);
}

fn tree_node(label: const u8[:], flags: i64) -> bool {
    return raw::igs_tree_node_ex(label, flags as i32);
}

fn tree_pop() {
    raw::igs_tree_pop();
}

fn collapsing_header(label: const u8[:]) -> bool {
    return raw::igs_collapsing_header(label, 0);
}

fn collapsing_header(label: const u8[:], flags: i64) -> bool {
    return raw::igs_collapsing_header(label, flags as i32);
}

fn begin_tab_bar(id: const u8[:]) -> bool {
    return raw::igs_begin_tab_bar(id, 0);
}

fn begin_tab_item(label: const u8[:]) -> bool {
    return raw::igs_begin_tab_item(label, 0, 0);
}

fn begin_tab_item(label: const u8[:], flags: i64) -> bool {
    return raw::igs_begin_tab_item(label, 0, flags as i32);
}

fn end_tab_item() {
    raw::igs_end_tab_item();
}

fn end_tab_bar() {
    raw::igs_end_tab_bar();
}

// --- tables -------------------------------------------------------------

fn begin_table(id: const u8[:], columns: i64) -> bool {
    return raw::igs_begin_table(id, columns as i32, 0);
}

fn begin_table(id: const u8[:], columns: i64, flags: i64) -> bool {
    return raw::igs_begin_table(id, columns as i32, flags as i32);
}

fn table_setup_column(name: const u8[:]) {
    raw::igs_table_setup_column(name, 0);
}

fn table_setup_column(name: const u8[:], flags: i64) {
    raw::igs_table_setup_column(name, flags as i32);
}

// With a starting width (or a weight, for a stretching column).
fn table_setup_column(name: const u8[:], flags: i64, width: f64) {
    raw::igs_table_setup_column_ex(name, flags as i32, width as f32, 0);
}

// --- scrolling ----------------------------------------------------------

// Scrolling is a property of the window being built, so these answer 0 and do
// nothing outside one rather than reading through a missing current window.
fn scroll_y() -> f64 {
    if window_depth == 0 { return 0.0; }
    return raw::igs_get_scroll_y();
}

fn scroll_max_y() -> f64 {
    if window_depth == 0 { return 0.0; }
    return raw::igs_get_scroll_max_y();
}

// Scrolls so the current position is at `ratio` of the visible height: 0 for
// the top, 1 for the bottom.
fn set_scroll_here_y(ratio: f64) {
    if window_depth == 0 { return; }
    raw::igs_set_scroll_here_y(ratio as f32);
}

fn table_headers_row() {
    raw::igs_table_headers_row();
}

fn table_next_row() {
    raw::igs_table_next_row();
}

fn table_next_column() -> bool {
    return raw::igs_table_next_column();
}

fn end_table() {
    raw::igs_end_table();
}

// A table whose scope is the block, with no flags.
fn table<F>(id: const u8[:], columns: i64) {
    if begin_table(id, columns) {
        defer end_table();
        F();
    }
}

fn table<F>(id: const u8[:], columns: i64, flags: i64) {
    if begin_table(id, columns, flags) {
        defer end_table();
        F();
    }
}

// --- popups and menus ---------------------------------------------------

fn open_popup(id: const u8[:]) {
    raw::igs_open_popup(id, 0);
}

// Opening a modal is opening a popup under the name BeginPopupModal looks for.
fn open_popup_modal(name: const u8[:]) {
    raw::igs_open_popup(name, 0);
}

fn begin_popup(id: const u8[:]) -> bool {
    return raw::igs_begin_popup(id, 0);
}

fn begin_popup_modal(name: const u8[:]) -> bool {
    return raw::igs_begin_popup_modal(name, 0, 0);
}

fn end_popup() {
    raw::igs_end_popup();
}

fn close_current_popup() {
    raw::igs_close_current_popup();
}

fn begin_menu_bar() -> bool {
    return raw::igs_begin_menu_bar();
}

fn end_menu_bar() {
    raw::igs_end_menu_bar();
}

fn begin_menu(label: const u8[:]) -> bool {
    return raw::igs_begin_menu(label);
}

fn end_menu() {
    raw::igs_end_menu();
}

fn menu_item(label: const u8[:]) -> bool {
    return raw::igs_menu_item(label);
}

fn menu_item(label: const u8[:], shortcut: const u8[:], selected: bool) -> bool {
    return raw::igs_menu_item_ex(label, shortcut, selected, true);
}

fn menu_item_toggle(label: const u8[:], selected: bool&) -> bool {
    return raw::igs_menu_item_toggle(label, selected);
}

fn begin_tooltip() -> bool {
    return raw::igs_begin_tooltip();
}

fn begin_item_tooltip() -> bool {
    return raw::igs_begin_item_tooltip();
}

fn end_tooltip() {
    raw::igs_end_tooltip();
}

// --- images and textures ------------------------------------------------

// Uploads RGBA8 bytes as a texture; a zero handle on failure.
fn texture(width: i64, height: i64, rgba: const u8[:]) -> u64 {
    return raw::igs_texture_create(width, height, rgba);
}

fn update_texture(texture: u64, width: i64, height: i64, rgba: const u8[:]) -> bool {
    return raw::igs_texture_update(texture, width, height, rgba);
}

fn release_texture(texture: u64) {
    raw::igs_texture_release(texture);
}

fn image(texture: u64, width: f64, height: f64) {
    raw::igs_image(texture, width as f32, height as f32);
}

fn image_button(id: const u8[:], texture: u64, width: f64, height: f64) -> bool {
    return raw::igs_image_button(id, texture, width as f32, height as f32);
}

// --- plots --------------------------------------------------------------

// The values are f32 because the plot is drawn from that array unchanged:
// keep the history in a `f32[N]` and pass a slice of it.
fn plot_lines(label: const u8[:], values: const f32[:]) {
    raw::igs_plot_lines(label, values);
}

fn plot_lines(label: const u8[:], values: const f32[:], lo: f64, hi: f64, width: f64,
              height: f64) {
    raw::igs_plot_lines_scaled(label, values, lo as f32, hi as f32, width as f32, height as f32);
}

fn plot_histogram(label: const u8[:], values: const f32[:], lo: f64, hi: f64, width: f64,
                  height: f64) {
    raw::igs_plot_histogram(label, values, lo as f32, hi as f32, width as f32, height as f32);
}

// --- canvas (ImDrawList) ------------------------------------------------
// A draw list is a u64 handle; the primitives take plain floats so a Goose
// program needs no vector type to draw one.

fn window_draw_list() -> u64 {
    return raw::igs_get_window_draw_list();
}

fn draw_rect_filled(list: u64, x0: f64, y0: f64, x1: f64, y1: f64, color: u32) {
    raw::igs_draw_list_add_rect_filled(list, x0 as f32, y0 as f32, x1 as f32, y1 as f32, color,
                                       0.0);
}

fn draw_rect_filled(list: u64, x0: f64, y0: f64, x1: f64, y1: f64, color: u32, rounding: f64) {
    raw::igs_draw_list_add_rect_filled(list, x0 as f32, y0 as f32, x1 as f32, y1 as f32, color,
                                       rounding as f32);
}

fn draw_rect(list: u64, x0: f64, y0: f64, x1: f64, y1: f64, color: u32, rounding: f64,
             thickness: f64) {
    raw::igs_draw_list_add_rect(list, x0 as f32, y0 as f32, x1 as f32, y1 as f32, color,
                                rounding as f32, thickness as f32);
}

fn draw_line(list: u64, x0: f64, y0: f64, x1: f64, y1: f64, color: u32, thickness: f64) {
    raw::igs_draw_list_add_line(list, x0 as f32, y0 as f32, x1 as f32, y1 as f32, color,
                                thickness as f32);
}

fn draw_circle(list: u64, cx: f64, cy: f64, radius: f64, color: u32) {
    raw::igs_draw_list_add_circle_filled(list, cx as f32, cy as f32, radius as f32, color);
}

fn draw_circle_outline(list: u64, cx: f64, cy: f64, radius: f64, color: u32, thickness: f64) {
    raw::igs_draw_list_add_circle(list, cx as f32, cy as f32, radius as f32, color,
                                  thickness as f32);
}

fn draw_triangle(list: u64, x0: f64, y0: f64, x1: f64, y1: f64, x2: f64, y2: f64, color: u32) {
    raw::igs_draw_list_add_triangle_filled(list, x0 as f32, y0 as f32, x1 as f32, y1 as f32,
                                           x2 as f32, y2 as f32, color);
}

fn draw_curve(list: u64, x0: f64, y0: f64, x1: f64, y1: f64, x2: f64, y2: f64, x3: f64, y3: f64,
              color: u32, thickness: f64) {
    raw::igs_draw_list_add_bezier_cubic(list, x0 as f32, y0 as f32, x1 as f32, y1 as f32,
                                        x2 as f32, y2 as f32, x3 as f32, y3 as f32, color,
                                        thickness as f32);
}

// Draws text at an explicit pixel size, which is how a zooming canvas keeps
// its labels in proportion with everything else it draws.
fn draw_text_sized(list: u64, x: f64, y: f64, size: f64, color: u32, s: const u8[:]) {
    raw::igs_draw_list_add_text_sized(list, x as f32, y as f32, size as f32, color, s);
}

fn draw_text(list: u64, x: f64, y: f64, color: u32, s: const u8[:]) {
    raw::igs_draw_list_add_text(list, x as f32, y as f32, color, s);
}

// Packs 0..255 components into the 0xAABBGGRR an ImU32 colour is.
fn rgba(r: i64, g: i64, b: i64, a: i64) -> u32 {
    let rr = (r & 255) as u32;
    let gg = (g & 255) as u32;
    let bb = (b & 255) as u32;
    let aa = (a & 255) as u32;
    return rr | (gg << 8) | (bb << 16) | (aa << 24);
}

// --- input --------------------------------------------------------------

fn is_item_hovered() -> bool {
    return raw::igs_is_item_hovered(0);
}

fn is_item_hovered(flags: i64) -> bool {
    return raw::igs_is_item_hovered(flags as i32);
}

fn mouse_pos() -> f32[2] {
    var x: f32 = 0.0;
    var y: f32 = 0.0;
    raw::igs_io_get_mouse_pos(x, y);
    return [x, y];
}

// A key by Dear ImGui's key index, e.g. raw::key_enter.
fn mouse_delta() -> f32[2] {
    var x: f32 = 0.0;
    var y: f32 = 0.0;
    raw::igs_io_mouse_delta(x, y);
    return [x, y];
}

// Wheel movement this frame, (vertical, horizontal).
fn mouse_wheel() -> f32[2] {
    var x: f32 = 0.0;
    var y: f32 = 0.0;
    raw::igs_io_mouse_wheel(x, y);
    return [x, y];
}

// `button` is raw::mouse_button_left, _right or _middle.
fn mouse_down(button: i32) -> bool {
    return raw::igs_mouse_down(button);
}

fn mouse_clicked(button: i32) -> bool {
    return raw::igs_mouse_clicked(button);
}

fn mouse_released(button: i32) -> bool {
    return raw::igs_mouse_released(button);
}

fn mouse_dragging(button: i32) -> bool {
    return raw::igs_mouse_dragging(button, 0.0);
}

// Whether a widget is holding the pointer, so a canvas on the same frame
// should leave the click alone.
fn want_mouse() -> bool {
    return raw::igs_io_want_mouse();
}

fn want_keyboard() -> bool {
    return raw::igs_io_want_keyboard();
}

fn key_down(key: i32) -> bool {
    return raw::igs_is_key_down(key);
}

fn key_pressed(key: i32) -> bool {
    return raw::igs_is_key_pressed(key);
}

fn key_pressed(key: i32, repeat: bool) -> bool {
    return raw::igs_is_key_pressed_ex(key, repeat);
}

fn key_released(key: i32) -> bool {
    return raw::igs_is_key_released(key);
}

fn is_key_down(key: i32) -> bool {
    return key_down(key);
}

fn is_key_pressed(key: i32) -> bool {
    return key_pressed(key);
}

fn is_key_released(key: i32) -> bool {
    return key_released(key);
}

fn metrics_render_vertices() -> i64 {
    return raw::igs_io_metrics_render_vertices();
}

fn metrics_active_windows() -> i64 {
    return raw::igs_io_metrics_active_windows();
}

// --- docking ------------------------------------------------------------

// A dockspace over the whole viewport, returned as its id.
fn dockspace_over_viewport() -> u32 {
    return raw::igs_dockspace_over_viewport(0.0, 0.0, 0);
}

fn dockspace_over_viewport(flags: i64) -> u32 {
    return raw::igs_dockspace_over_viewport(0.0, 0.0, flags as i32);
}

fn dockspace_id(name: const u8[:]) -> u32 {
    return raw::igs_dockspace_id(name);
}

fn dockspace(id: u32, width: f64, height: f64, flags: i64) -> u32 {
    return raw::igs_dockspace(id, 0.0, 0.0, width as f32, height as f32, flags as i32);
}

// Rebuilds a fixed workspace under `root` (a dockspace id): 1 for a left
// column, 2 a right column and 3 a bottom strip; 0 is a plain three-column
// layout. Call before the windows it holds, once, on the first frame.
fn dock_build(root: u32, width: f64, height: f64, layout: i64) -> bool {
    return raw::igs_internal_dock_build(root, width as f32, height as f32, layout);
}

fn dock_window(title: const u8[:], slot: i64) {
    raw::igs_internal_dock_window(title, slot);
}

fn dock_finish() {
    raw::igs_internal_dock_finish();
}

fn enable_viewports(on: bool) {
    raw::igs_internal_enable_viewports(on);
}

fn render_platform_windows() {
    raw::igs_internal_render_platform_windows();
}
