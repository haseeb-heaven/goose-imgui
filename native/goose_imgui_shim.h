/* goose_imgui_shim.h — the hand-written half of goose-imgui's C ABI.
 *
 * Every declaration here has a `// goose:` line directly above it giving the
 * Goose signature that scripts/generate_bindings.py emits into raw.goose.
 * That makes this header the single place a signature is written down: the C
 * and the Goose side cannot drift, and the generator fails if a hand-written
 * symbol collides with one it generated from the Dear ImGui metadata
 * (in which case the hand-written one wins and the generated one is dropped).
 *
 * The implementations are in goose_imgui_shim.cpp (C API only) and
 * goose_imgui_internal.cpp (the docking builder, which lives in
 * imgui_internal.h). */

#ifndef IMGUI_GOOSE_SHIM_H
#define IMGUI_GOOSE_SHIM_H

#include <stdint.h>

#include "igs_api.h" /* igs_u8s, igs_f32s, and the generated wrappers */

#ifdef __cplusplus
extern "C" {
#endif

/* --- lifecycle ---------------------------------------------------------- */
// goose: fn igs_init(title: const u8[:], width: i64, height: i64, flags: i64) -> bool
bool igs_init(igs_u8s title, int64_t width, int64_t height, int64_t flags);
// goose: fn igs_attach(window: u64, device: u64) -> bool
bool igs_attach(uint64_t window, uint64_t device);
// goose: fn igs_init_offscreen(width: i64, height: i64) -> bool
bool igs_init_offscreen(int64_t width, int64_t height);
// goose: fn igs_shutdown()
void igs_shutdown(void);
// goose: fn igs_ready() -> bool
bool igs_ready(void);
// goose: fn igs_sdl_window() -> u64
uint64_t igs_sdl_window(void);
// goose: fn igs_sdl_device() -> u64
uint64_t igs_sdl_device(void);
// goose: fn igs_render_target_texture() -> u64
uint64_t igs_render_target_texture(void);
// goose: fn igs_is_offscreen() -> bool
bool igs_is_offscreen(void);
// goose: fn igs_frame_count() -> u64
uint64_t igs_frame_count(void);
// goose: fn igs_dpi_scale() -> f32
float igs_dpi_scale(void);
// goose: fn igs_driver_into(out: u8[:]) -> i64
int64_t igs_driver_into(igs_u8s out);
// goose: fn igs_error_into(out: u8[:]) -> i64
int64_t igs_error_into(igs_u8s out);
// goose: fn igs_version_into(out: u8[:]) -> i64
int64_t igs_version_into(igs_u8s out);
// goose: fn igs_style_colors(dark: bool)
void igs_style_colors(bool dark);
// goose: fn igs_set_clear_color(r: f32, g: f32, b: f32, a: f32)
void igs_set_clear_color(float r, float g, float b, float a);

/* --- frame -------------------------------------------------------------- */
/* Ask the IO what it thinks the display is; for troubleshooting a frame that
 * renders nothing. */
// goose: fn igs_io_display_size(w: f32&, h: f32&, dt: f32&)
void igs_io_display_size(float *w, float *h, float *dt);
// goose: fn igs_new_frame() -> bool
bool igs_new_frame(void);
// goose: fn igs_end_frame()
void igs_end_frame(void);
// goose: fn igs_request_quit()
void igs_request_quit(void);
// goose: fn igs_should_close() -> bool
bool igs_should_close(void);
/* Clipboard, through whichever backend is driving: copy out of a window and
 * paste into an input field both go through the platform layer. */
// goose: fn igs_set_clipboard(text: const u8[:])
void igs_set_clipboard(igs_u8s text);
// goose: fn igs_clipboard_into(out: u8[:]) -> i64
int64_t igs_clipboard_into(igs_u8s out);
// goose: fn igs_delta_time() -> f32
float igs_delta_time(void);
// goose: fn igs_display_width() -> i64
int64_t igs_display_width(void);
// goose: fn igs_display_height() -> i64
int64_t igs_display_height(void);
// goose: fn igs_screenshot(path: const u8[:]) -> bool
bool igs_screenshot(igs_u8s path);

/* --- fonts -------------------------------------------------------------- */
// goose: fn igs_load_font(path: const u8[:], size_px: f32) -> bool
bool igs_load_font(igs_u8s path, float size_px);
/* The font atlas as the backend sees it: size, status and texture handle.
 * For troubleshooting a font that loads but does not draw. */
// goose: fn igs_atlas_info(width: i32&, height: i32&) -> u64
uint64_t igs_atlas_info(int32_t *width, int32_t *height);
// goose: fn igs_atlas_dump(path: const u8[:]) -> bool
bool igs_atlas_dump(igs_u8s path);

/* --- text --------------------------------------------------------------- */
// goose: fn igs_text(s: const u8[:])
void igs_text(igs_u8s s);
// goose: fn igs_text_colored(r: f32, g: f32, b: f32, a: f32, s: const u8[:])
void igs_text_colored(float r, float g, float b, float a, igs_u8s s);
// goose: fn igs_text_disabled(s: const u8[:])
void igs_text_disabled(igs_u8s s);
// goose: fn igs_text_wrapped(s: const u8[:])
void igs_text_wrapped(igs_u8s s);
// goose: fn igs_label_text(label: const u8[:], value: const u8[:])
void igs_label_text(igs_u8s label, igs_u8s value);
// goose: fn igs_bullet_text(s: const u8[:])
void igs_bullet_text(igs_u8s s);
// goose: fn igs_tooltip(s: const u8[:])
void igs_tooltip(igs_u8s s);
// goose: fn igs_separator_text(s: const u8[:])
void igs_separator_text(igs_u8s s);

/* --- text input with a caller-owned buffer ------------------------------ */
// goose: fn igs_input_text(label: const u8[:], buf: u8[:], flags: i64) -> bool
bool igs_input_text(igs_u8s label, igs_u8s buf, int64_t flags);
// goose: fn igs_input_text_with_hint(label: const u8[:], hint: const u8[:], buf: u8[:], flags: i64) -> bool
bool igs_input_text_with_hint(igs_u8s label, igs_u8s hint, igs_u8s buf, int64_t flags);
// goose: fn igs_input_text_multiline_sized(label: const u8[:], buf: u8[:], w: f32, h: f32, flags: i64) -> bool
bool igs_input_text_multiline_sized(igs_u8s label, igs_u8s buf, float w, float h, int64_t flags);

/* --- value widgets: the C parameter is a pointer, Goose's T& ------------
 * The widgets work on Goose's default literal types, i64 and f64, and
 * convert to Dear ImGui's int and float. A multi-component widget takes a
 * pointer to the first of `n` doubles, which `v[0]` is for a Goose array. */
// goose: fn igs_checkbox(label: const u8[:], v: bool&) -> bool
bool igs_checkbox(igs_u8s label, bool *v);
// goose: fn igs_slider_f64(label: const u8[:], v: f64&, lo: f64, hi: f64) -> bool
bool igs_slider_f64(igs_u8s label, double *v, double lo, double hi);
// goose: fn igs_slider_f64_fmt(label: const u8[:], v: f64&, lo: f64, hi: f64, fmt: const u8[:]) -> bool
bool igs_slider_f64_fmt(igs_u8s label, double *v, double lo, double hi, igs_u8s fmt);
// goose: fn igs_slider_i64(label: const u8[:], v: i64&, lo: i64, hi: i64) -> bool
bool igs_slider_i64(igs_u8s label, int64_t *v, int64_t lo, int64_t hi);
// goose: fn igs_slider_angle(label: const u8[:], v: f64&, lo: f64, hi: f64) -> bool
bool igs_slider_angle(igs_u8s label, double *v, double lo, double hi);
// goose: fn igs_drag_f64(label: const u8[:], v: f64&, speed: f64, lo: f64, hi: f64) -> bool
bool igs_drag_f64(igs_u8s label, double *v, double speed, double lo, double hi);
// goose: fn igs_drag_f64_speed(label: const u8[:], v: f64&, speed: f64) -> bool
bool igs_drag_f64_speed(igs_u8s label, double *v, double speed);
// goose: fn igs_drag_i64(label: const u8[:], v: i64&, speed: f64, lo: i64, hi: i64) -> bool
bool igs_drag_i64(igs_u8s label, int64_t *v, double speed, int64_t lo, int64_t hi);
// goose: fn igs_input_f64(label: const u8[:], v: f64&, step: f64, step_fast: f64) -> bool
bool igs_input_f64(igs_u8s label, double *v, double step, double step_fast);
// goose: fn igs_input_i64(label: const u8[:], v: i64&, step: i64, step_fast: i64) -> bool
bool igs_input_i64(igs_u8s label, int64_t *v, int64_t step, int64_t step_fast);
// goose: fn igs_slider_f64_n(label: const u8[:], v: f64&, n: i64, lo: f64, hi: f64) -> bool
bool igs_slider_f64_n(igs_u8s label, double *v, int64_t n, double lo, double hi);
// goose: fn igs_drag_f64_n(label: const u8[:], v: f64&, n: i64, speed: f64, lo: f64, hi: f64) -> bool
bool igs_drag_f64_n(igs_u8s label, double *v, int64_t n, double speed, double lo, double hi);
// goose: fn igs_input_f64_n(label: const u8[:], v: f64&, n: i64) -> bool
bool igs_input_f64_n(igs_u8s label, double *v, int64_t n);
// goose: fn igs_color_edit(label: const u8[:], v: f64&, n: i64) -> bool
bool igs_color_edit(igs_u8s label, double *v, int64_t n);
// goose: fn igs_color_picker(label: const u8[:], v: f64&, n: i64) -> bool
bool igs_color_picker(igs_u8s label, double *v, int64_t n);
// goose: fn igs_color_button(desc: const u8[:], v: f64&) -> bool
bool igs_color_button(igs_u8s desc, double *v);

/* --- combo boxes, radio buttons, menus, progress ------------------------ */
// goose: fn igs_combo(label: const u8[:], current: i64&, items: const u8[:]) -> bool
bool igs_combo(igs_u8s label, int64_t *current, igs_u8s items);
// goose: fn igs_radio_i64(label: const u8[:], v: i64&, button: i64) -> bool
bool igs_radio_i64(igs_u8s label, int64_t *v, int64_t button);
// goose: fn igs_menu_item_toggle(label: const u8[:], selected: bool&) -> bool
bool igs_menu_item_toggle(igs_u8s label, bool *selected);
// goose: fn igs_progress_bar(fraction: f64, w: f32, h: f32, overlay: const u8[:])
void igs_progress_bar(double fraction, float w, float h, igs_u8s overlay);

/* --- textures and images ------------------------------------------------ */
// goose: fn igs_texture_create(w: i64, h: i64, rgba: const u8[:]) -> u64
uint64_t igs_texture_create(int64_t w, int64_t h, igs_u8s rgba);
// goose: fn igs_texture_update(tex: u64, w: i64, h: i64, rgba: const u8[:]) -> bool
bool igs_texture_update(uint64_t tex, int64_t w, int64_t h, igs_u8s rgba);
// goose: fn igs_texture_release(tex: u64)
void igs_texture_release(uint64_t tex);
// goose: fn igs_image(tex: u64, w: f32, h: f32)
void igs_image(uint64_t tex, float w, float h);
// goose: fn igs_image_ex(tex: u64, w: f32, h: f32, u0: f32, v0: f32, u1: f32, v1: f32)
void igs_image_ex(uint64_t tex, float w, float h, float u0, float v0, float u1, float v1);
// goose: fn igs_image_button(id: const u8[:], tex: u64, w: f32, h: f32) -> bool
bool igs_image_button(igs_u8s id, uint64_t tex, float w, float h);

/* --- IO and style ------------------------------------------------------- */
// goose: fn igs_io_fps() -> f32
float igs_io_fps(void);
// goose: fn igs_io_set_fps(fps: f32)
void igs_io_set_fps(float fps);
// goose: fn igs_io_get_mouse_pos(x: f32&, y: f32&)
void igs_io_get_mouse_pos(float *x, float *y);
/* Pointer state and what wants the pointer: what a canvas needs to tell a
 * drag from a hover, and to leave the window alone when a widget has focus. */
// goose: fn igs_io_mouse_delta(x: f32&, y: f32&)
void igs_io_mouse_delta(float *x, float *y);
// goose: fn igs_io_mouse_wheel(x: f32&, y: f32&)
void igs_io_mouse_wheel(float *x, float *y);
// goose: fn igs_mouse_down(button: i64) -> bool
bool igs_mouse_down(int64_t button);
// goose: fn igs_mouse_clicked(button: i64) -> bool
bool igs_mouse_clicked(int64_t button);
// goose: fn igs_mouse_released(button: i64) -> bool
bool igs_mouse_released(int64_t button);
// goose: fn igs_mouse_dragging(button: i64, threshold: f64) -> bool
bool igs_mouse_dragging(int64_t button, double threshold);
// goose: fn igs_io_want_mouse() -> bool
bool igs_io_want_mouse(void);
// goose: fn igs_io_want_keyboard() -> bool
bool igs_io_want_keyboard(void);
// goose: fn igs_io_set_mouse_pos(x: f32, y: f32)
void igs_io_set_mouse_pos(float x, float y);
// goose: fn igs_io_metrics_render_vertices() -> i64
int64_t igs_io_metrics_render_vertices(void);
// goose: fn igs_io_metrics_render_indices() -> i64
int64_t igs_io_metrics_render_indices(void);
// goose: fn igs_io_metrics_active_windows() -> i64
int64_t igs_io_metrics_active_windows(void);
// goose: fn igs_style_set_window_rounding(v: f32)
void igs_style_set_window_rounding(float v);
// goose: fn igs_style_set_frame_rounding(v: f32)
void igs_style_set_frame_rounding(float v);
// goose: fn igs_style_set_window_padding(x: f32, y: f32)
void igs_style_set_window_padding(float x, float y);
// goose: fn igs_style_set_frame_padding(x: f32, y: f32)
void igs_style_set_frame_padding(float x, float y);
// goose: fn igs_style_set_item_spacing(x: f32, y: f32)
void igs_style_set_item_spacing(float x, float y);
// goose: fn igs_style_set_scrollbar_size(v: f32)
void igs_style_set_scrollbar_size(float v);

/* --- docking ----------------------------------------------------------- */
// goose: fn igs_dockspace_over_viewport(top: f32, bottom: f32, flags: i64) -> u32
uint32_t igs_dockspace_over_viewport(float top, float bottom, int64_t flags);
// goose: fn igs_dockspace_id(name: const u8[:]) -> u32
uint32_t igs_dockspace_id(igs_u8s name);
// goose: fn igs_dockspace(id: u32, x: f32, y: f32, w: f32, h: f32, flags: i64) -> u32
uint32_t igs_dockspace(uint32_t id, float x, float y, float w, float h, int64_t flags);

/* --- canvas primitives (node graphs, custom widgets) -------------------- */
/* Text at a size other than the UI font's, for a canvas that zooms: a node
 * editor drawing at 60% wants its labels at 60% too. */
// goose: fn igs_draw_list_add_text_sized(list: u64, x: f32, y: f32, size: f32, col: u32, text: const u8[:])
void igs_draw_list_add_text_sized(uint64_t list, float x, float y, float size, uint32_t col,
                                  igs_u8s text);
// goose: fn igs_draw_list_add_text(list: u64, x: f32, y: f32, col: u32, text: const u8[:])
void igs_draw_list_add_text(uint64_t list, float x, float y, uint32_t col, igs_u8s text);
// goose: fn igs_draw_list_add_rect_filled(list: u64, x0: f32, y0: f32, x1: f32, y1: f32, col: u32, rounding: f32)
void igs_draw_list_add_rect_filled(uint64_t list, float x0, float y0, float x1, float y1,
                                   uint32_t col, float rounding);
// goose: fn igs_draw_list_add_rect(list: u64, x0: f32, y0: f32, x1: f32, y1: f32, col: u32, rounding: f32, thickness: f32)
void igs_draw_list_add_rect(uint64_t list, float x0, float y0, float x1, float y1, uint32_t col,
                            float rounding, float thickness);
// goose: fn igs_draw_list_add_circle_filled(list: u64, cx: f32, cy: f32, r: f32, col: u32)
void igs_draw_list_add_circle_filled(uint64_t list, float cx, float cy, float r, uint32_t col);
// goose: fn igs_draw_list_add_circle(list: u64, cx: f32, cy: f32, r: f32, col: u32, thickness: f32)
void igs_draw_list_add_circle(uint64_t list, float cx, float cy, float r, uint32_t col,
                              float thickness);
// goose: fn igs_draw_list_add_line(list: u64, x0: f32, y0: f32, x1: f32, y1: f32, col: u32, thickness: f32)
void igs_draw_list_add_line(uint64_t list, float x0, float y0, float x1, float y1, uint32_t col,
                            float thickness);
// goose: fn igs_draw_list_add_bezier_cubic(list: u64, x0: f32, y0: f32, x1: f32, y1: f32, x2: f32, y2: f32, x3: f32, y3: f32, col: u32, thickness: f32)
void igs_draw_list_add_bezier_cubic(uint64_t list, float x0, float y0, float x1, float y1, float x2,
                                    float y2, float x3, float y3, uint32_t col, float thickness);
// goose: fn igs_draw_list_add_triangle_filled(list: u64, x0: f32, y0: f32, x1: f32, y1: f32, x2: f32, y2: f32, col: u32)
void igs_draw_list_add_triangle_filled(uint64_t list, float x0, float y0, float x1, float y1,
                                       float x2, float y2, uint32_t col);

/* --- plots -------------------------------------------------------------- */
// goose: fn igs_plot_lines(label: const u8[:], values: const f32[:])
void igs_plot_lines(igs_u8s label, igs_f32s values);
// goose: fn igs_plot_lines_scaled(label: const u8[:], values: const f32[:], lo: f32, hi: f32, w: f32, h: f32)
void igs_plot_lines_scaled(igs_u8s label, igs_f32s values, float lo, float hi, float w, float h);
// goose: fn igs_plot_histogram(label: const u8[:], values: const f32[:], lo: f32, hi: f32, w: f32, h: f32)
void igs_plot_histogram(igs_u8s label, igs_f32s values, float lo, float hi, float w, float h);

/* --- windows, ids, misc ------------------------------------------------- */
// goose: fn igs_begin_open(name: const u8[:], p_open: bool&, flags: i64) -> bool
bool igs_begin_open(igs_u8s name, bool *p_open, int64_t flags);
// goose: fn igs_set_next_window_pos_pivot(x: f32, y: f32, cond: i64, px: f32, py: f32)
void igs_set_next_window_pos_pivot(float x, float y, int64_t cond, float px, float py);

/* A closable window's open flag, owned by the shim: Goose cannot take the
 * address of its own bool, and a window's `p_open` has to outlive the call. */
// goose: fn igs_open_cell_new(initial: bool) -> u64
uint64_t igs_open_cell_new(bool initial);
// goose: fn igs_open_cell_get(cell: u64) -> bool
bool igs_open_cell_get(uint64_t cell);
// goose: fn igs_open_cell_set(cell: u64, value: bool)
void igs_open_cell_set(uint64_t cell, bool value);
// goose: fn igs_open_cell_free(cell: u64)
void igs_open_cell_free(uint64_t cell);

#ifdef __cplusplus
}
#endif

#endif /* IMGUI_GOOSE_SHIM_H */
