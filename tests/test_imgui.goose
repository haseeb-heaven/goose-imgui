// tests/test_imgui.goose — the package's own checks.
//
// Run them with:
//
//     goose run tests/test_imgui.goose        (in-process, JIT)
//     goose build tests/test_imgui.goose && ./tests/test_imgui   (native)
//
// They render offscreen through SDL_GPU, so they need a GPU but no display,
// and they exit non-zero when an assertion fails: scripts/run_tests.sh uses
// that as the package's gate. Nothing here sleeps or waits on a window, so
// the whole file runs in well under a second.

import imgui from "../";
import imgui.raw;
import imgui.src.widgets;
import os;

var failures = 0;
var checks = 0;

fn check(ok: bool, what: const u8[:]) {
    checks += 1;
    if !ok {
        failures += 1;
        print("FAIL  ", what);
    }
}

fn check_eq(actual: i64, expected: i64, what: const u8[:]) {
    if actual != expected { print("      ", what, ": got ", actual, ", want ", expected); }
    check(actual == expected, what);
}

// --- the pieces that are Goose-side only ---------------------------------

fn test_buffers() {
    var buf = imgui::text_buffer(16);
    check_eq(buf.len, 16, "text_buffer has the capacity asked for");
    imgui::set_text(buf, "goose");
    check_eq(imgui::text_of(buf).len, 5, "text_of reads the text back");
    check(imgui::text_of(buf) == "goose", "text_of matches what set_text wrote");
    imgui::set_text(buf, "0123456789abcdefghij");  // longer than the buffer
    check_eq(imgui::text_of(buf).len, 15, "set_text truncates to capacity minus the NUL");

    var fixed: u8[..8] = [];
    fixed.resize(8, 0);
    widgets::text_set(fixed, "abc");
    check(widgets::text_value(fixed) == "abc", "widgets::text_set/text_value round-trip");

    let items = widgets::joined_z(["red", "green", "blue"]);
    check_eq(items.len, 16, "joined_z appends a NUL per item and one more");
    check_eq(widgets::count_z(items), 4, "count_z counts the terminators");
    check(items[0] == 'r', "joined_z keeps the first item first");
}

fn test_history() {
    var h = widgets::History { values: [0.0; 128], count: 0 };
    for i in 0..5 { widgets::push(h, i); }
    let values = widgets::values(h);
    check_eq(values.len, 5, "history holds what was pushed");
    check(values[4] == 4.0, "history keeps the newest value last");
    for i in 0..200 { widgets::push(h, 200.0); }
    check_eq(widgets::values(h).len, 128, "history caps at its capacity");
    check(widgets::values(h)[127] == 200.0, "history scrolls rather than overflowing");
}

fn test_colors() {
    check_eq(imgui::rgba(255, 0, 0, 255), 0xFF0000FF, "rgba packs R low and A high");
    check_eq(imgui::rgba(0, 255, 0, 0), 0x0000FF00, "rgba masks components");
}

// --- the context and the GPU --------------------------------------------

fn test_context() {
    check(!imgui::ready(), "no context before init");
    check(imgui::init_offscreen(640, 400), "offscreen context starts");
    check(imgui::ready(), "ready() after init");
    check(imgui::error().len == 0, "no error after a clean init");
    check(!imgui::init_offscreen(640, 400), "a second context is refused");
    check(imgui::error().len > 0, "the refused second init says why");
    check_eq(imgui::frame_count() as i64, 0, "no frames have ended yet");

    let v = imgui::version();
    check(v.len >= 5 && v[0] == '1', "version() names the Dear ImGui version");
    let d = imgui::driver();
    check(d == "metal" || d == "vulkan" || d == "direct3d12", "driver() names a known backend");
    check_eq(imgui::display_width(), 640, "display width is the offscreen size");
    check_eq(imgui::display_height(), 400, "display height is the offscreen size");
    check_eq(imgui::dpi_scale() as i64, 1, "an offscreen target is at scale 1");
    check(imgui::sdl_device() != 0, "an SDL_GPU device exists");
}

fn test_frames_and_layout() {
    let before = imgui::frame_count();
    check(imgui::frame(), "frame() starts a frame");
    imgui::set_next_window_pos(20.0, 20.0, imgui::ALWAYS);
    imgui::set_next_window_size(300.0, 200.0, imgui::ALWAYS);
    if imgui::begin_window("layout", imgui::NO_TITLE_BAR | imgui::NO_RESIZE) {
        let avail = imgui::content_avail();
        // 300 wide less the style's window padding of 10 each side.
        check(avail[0] > 270.0 && avail[0] < 300.0, "content_avail is the padded content width");
        check(avail[1] > 170.0 && avail[1] < 200.0, "content_avail is the padded content height");

        let size = imgui::calc_text_size("MMMM");
        let small = imgui::calc_text_size("M");
        check(size[0] > small[0], "calc_text_size grows with the text");
        check(size[1] > 0.0, "calc_text_size reports a line height");

        let start = imgui::cursor_screen_pos();
        imgui::dummy(40.0, 10.0);
        let after = imgui::cursor_screen_pos();
        check(after[1] > start[1], "dummy() advances the cursor down");
    }
    imgui::end_window();
    imgui::end_frame();
    check_eq(imgui::frame_count() as i64, before as i64 + 1, "frame_count() counts ended frames");
}

fn test_draw_data() {
    check(imgui::frame(), "frame() for the draw-data check");
    // An explicit size, so the window is already big enough to hold its
    // content on the frame it is first drawn in.
    imgui::set_next_window_size(260.0, 140.0, imgui::ALWAYS);
    if imgui::begin_window("draw", imgui::NO_TITLE_BAR | imgui::NO_RESIZE) {
        let dl = imgui::window_draw_list();
        check(dl != 0, "window_draw_list() returns a draw list");
        imgui::draw_rect_filled(dl, 10.0, 10.0, 100.0, 60.0, imgui::rgba(220, 60, 90, 255), 4.0);
        imgui::draw_line(dl, 0.0, 0.0, 60.0, 60.0, imgui::rgba(255, 255, 255, 128), 2.0);
        imgui::draw_circle(dl, 120.0, 40.0, 18.0, imgui::rgba(90, 200, 255, 255));
        imgui::text("vertices");
    }
    imgui::end_window();
    imgui::end_frame();
    // The metrics describe the frame Render() just produced, so they are read
    // after end_frame, not before it.
    check(imgui::metrics_render_vertices() > 0, "the frame produced vertices");
    check(imgui::metrics_active_windows() >= 1, "a window was active");
}

fn test_screenshot() {
    check(imgui::frame(), "frame() for the screenshot");
    imgui::set_next_window_size(240.0, 120.0, imgui::ALWAYS);
    if imgui::begin_window("shot", imgui::NO_TITLE_BAR) {
        imgui::text("goose-imgui");
    }
    imgui::end_window();
    imgui::end_frame();
    let path = "/tmp/goose-imgui-selftest.png";
    check(imgui::screenshot(path), "screenshot() writes a file");
    check(file_exists(path), "the screenshot file exists");
    var png: u8[>..] = [];
    check(read_file(path, png), "the screenshot file reads back");
    check(png.len > 1000, "the screenshot is more than a header");
    check(png.len > 8 && png[0] == 0x89 && png[1] == 'P' && png[2] == 'N' && png[3] == 'G',
          "the screenshot is a PNG");
    check_eq((png[16] as i64) << 24 | (png[17] as i64) << 16 | (png[18] as i64) << 8 | png[19],
             640, "the PNG's IHDR width is the render target width");
    check_eq((png[20] as i64) << 24 | (png[21] as i64) << 16 | (png[22] as i64) << 8 | png[23],
             400, "the PNG's IHDR height is the render target height");
    delete_file(path);
}

fn test_fonts() {
    // The default font is always there; a missing file must fail cleanly
    // rather than abort, and drawing must carry on.
    check(!imgui::load_font("/nonexistent/font.ttf", 16.0), "a missing font file is refused");
    check(imgui::frame(), "frame() after the refused font load");
    imgui::set_next_window_size(240.0, 120.0, imgui::ALWAYS);
    if imgui::begin_window("fonts") { imgui::text("still drawing"); }
    imgui::end_window();
    imgui::end_frame();
    check(imgui::metrics_render_vertices() > 0, "text still draws after a refused font load");
    var w: i32 = 0;
    var h: i32 = 0;
    let info = raw::igs_atlas_info(w, h);
    check(w > 0 && h > 0, "the font atlas has a texture");
    check((info & 0x00FFFFFFFFFFFFFF) != 0, "the atlas texture has a GPU handle");
}

fn test_widgets() {
    check(imgui::frame(), "frame() for the widget pass");
    var changed = false;
    var amount = 0.5;
    var count: i64 = 3;
    var flag = true;
    var text = imgui::text_buffer(32);
    imgui::set_text(text, "typed");
    if imgui::begin_window("widgets", imgui::ALWAYS_AUTO_RESIZE) {
        changed = imgui::button("press me");
        if imgui::slider("amount", amount, 0.0, 1.0) { changes_nothing(); }
        if imgui::slider("count", count, 0, 10) { changes_nothing(); }
        if imgui::checkbox("flag", flag) { changes_nothing(); }
        widgets::text_field("text", text);
        imgui::combo("pick", count, ["one", "two", "three"]);
        if imgui::begin_table("table", 2) {
            imgui::table_setup_column("name");
            imgui::table_setup_column("value");
            imgui::table_headers_row();
            imgui::table_next_row();
            imgui::table_next_column();
            imgui::text("a");
            imgui::table_next_column();
            imgui::text("1");
            imgui::end_table();
        }
        if imgui::tree_node("node") { imgui::text("leaf"); imgui::tree_pop(); }
        imgui::plot_lines("plot", [1.0; 8]);
    }
    imgui::end_window();
    imgui::end_frame();
    check(!changed, "an unclicked button reports false");
}

fn changes_nothing() {}

// --- packed fields, vectors and the canvas -------------------------------

// Goose packs structs, so a fixed array inside one starts at whatever byte the
// fields before it add up to: `colour` here sits one byte past a 32 byte name.
// A widget that writes past the end of such an array corrupts `tail`, which is
// what this test is for: it is the bug the colour widgets had, where three
// components were treated as four and the fourth write landed on the guard.
struct Packed {
    name: u8[..32],
    colour: f64[..3],
    tail: f64,
}

fn test_packed_fields() {
    var p = Packed { name: [0; 32], colour: [0.25, 0.5, 0.75], tail: 7.5 };
    var curve: f32[..8] = [0.0, 1.0, 4.0, 9.0, 16.0, 25.0, 36.0, 49.0];
    check(imgui::frame(), "frame() for the packed-field pass");
    // An explicit size, so the window is big enough to hold its content on the
    // frame it is first drawn in.
    imgui::set_next_window_size(280.0, 220.0, imgui::ALWAYS);
    if imgui::begin_window("packed", imgui::NO_TITLE_BAR) {
        if imgui::color_edit("tint", p.colour[0], 3) { changes_nothing(); }
        if imgui::slider_n("offset", p.colour[1], 2, 0.0, 1.0) { changes_nothing(); }
        if imgui::drag("one", p.colour[2], 0.01) { changes_nothing(); }
        imgui::plot_lines("curve", curve, 0.0, 50.0, 120.0, 40.0);
        if imgui::begin_table("widths", 2) {
            imgui::table_setup_column("a", imgui::WIDTH_FIXED, 60.0);
            imgui::table_setup_column("b", imgui::WIDTH_STRETCH);
            imgui::table_next_row();
            imgui::table_next_column();
            imgui::text("x");
            imgui::table_next_column();
            imgui::text("y");
            imgui::end_table();
        }
        imgui::same_line(80.0);
        imgui::text("offset line");
        if imgui::combo_z("pick", curve_index, "one\0two\0three\0") { changes_nothing(); }
        // Canvas primitives: a rounded rectangle with a thickness, and text at
        // a size other than the UI font's.
        let list = imgui::window_draw_list();
        let at = imgui::cursor_screen_pos();
        imgui::draw_rect(list, at[0], at[1], at[0] + 90.0, at[1] + 40.0,
                         imgui::rgba(200, 220, 255, 255), 6.0, 2.0);
        imgui::draw_text_sized(list, at[0] + 6.0, at[1] + 6.0, 11.0,
                               imgui::rgba(240, 240, 240, 255), "sized text");
        imgui::dummy(90.0, 40.0);
    }
    imgui::end_window();
    imgui::end_frame();

    check(p.tail == 7.5, "a colour edit leaves the bytes after the array alone");
    check_eq(p.colour[2] as i64, 0, "a drag leaves the last component alone");
    check(abs(p.colour[0] - 0.25) < 0.001, "a colour edit keeps the value it was given");
    check(imgui::metrics_render_vertices() > 0, "the canvas drew something");
}

var curve_index: i64 = 0;

fn test_input_state() {
    // Nothing is pressed when there is no window to press it in, and the calls
    // have to be safe offscreen: a canvas asks them every frame.
    check(!imgui::mouse_down(raw::mouse_button_left), "no button is down offscreen");
    check(!imgui::mouse_clicked(raw::mouse_button_left), "nothing was clicked offscreen");
    check(!imgui::mouse_released(raw::mouse_button_left), "nothing was released offscreen");
    check(!imgui::mouse_dragging(raw::mouse_button_left), "nothing is being dragged");
    check(!imgui::want_mouse(), "nothing wants the pointer offscreen");
    let wheel = imgui::mouse_wheel();
    check(wheel[0] == 0.0 && wheel[1] == 0.0, "no wheel movement offscreen");
    let delta = imgui::mouse_delta();
    check(delta[0] == 0.0 && delta[1] == 0.0, "no pointer movement offscreen");
    // The clipboard needs a platform layer: offscreen it is a no-op rather
    // than a crash.
    imgui::set_clipboard("copied");
    check_eq(imgui::clipboard().len, 0, "no clipboard owner offscreen");
}

fn test_scrolling() {
    check(imgui::frame(), "frame() for the scroll pass");
    imgui::set_next_window_size(200.0, 140.0, imgui::ALWAYS);
    var max_y = -1.0;
    var at = -1.0;
    if imgui::begin_window("scroll") {
        // Scrolling is per window, so it is read and set while that window is
        // the current one.
        if imgui::begin_child("inner", 0.0, 80.0, imgui::BORDERS, imgui::NO_SCROLLBAR) {
            for i in 0..40 {
                imgui::text(str("line ", i));
            }
            imgui::end_child();
        }
        max_y = imgui::scroll_max_y();
        at = imgui::scroll_y();
        imgui::set_scroll_here_y(1.0);
        imgui::end_window();
    }
    imgui::end_frame();
    check(max_y >= 0.0, "the scroll range of a window can be read");
    check(at >= 0.0, "the scroll position of a window can be read");
}

// The block-scoped helpers: a trailing block binds the helper's extra type
// argument, so `window("x") { ... }` has to open a window *and* run the body.
fn test_closures() {
    check(imgui::frame(), "frame() for the closure pass");
    imgui::set_next_window_size(260.0, 180.0, imgui::ALWAYS);
    var windows = 0;
    var rows = 0;
    var sections = 0;
    var children = 0;
    imgui::window("closures") {
        windows += 1;
        widgets::section("closures section") {
            sections += 1;
            imgui::text("inside a section");
        }
    }
    imgui::window("closures flags", imgui::NO_TITLE_BAR) {
        windows += 1;
        imgui::table("closure table", 2) {
            rows += 1;
            imgui::table_next_row();
            imgui::table_next_column();
            imgui::text("cell");
        }
        imgui::child("closure child", 120.0, 40.0) {
            children += 1;
            imgui::text("inside");
        }
    }
    imgui::end_frame();
    check_eq(windows, 2, "a block-scoped window runs its body once");
    check_eq(rows, 1, "a block-scoped table runs its body once");
    check_eq(children, 1, "a block-scoped child runs its body once");
    check_eq(sections, 1, "widgets::section runs its body once");
}

fn test_restart() {
    imgui::shutdown();
    check(!imgui::ready(), "shutdown clears the context");
    check(imgui::init_offscreen(320, 200), "a context can be created again");
    check_eq(imgui::display_width(), 320, "the new context has its own size");
    imgui::shutdown();
}

fn main() {
    print("goose-imgui self-test");
    test_buffers();
    test_history();
    test_colors();
    test_context();
    test_frames_and_layout();
    test_draw_data();
    test_screenshot();
    test_fonts();
    test_widgets();
    test_packed_fields();
    test_input_state();
    test_scrolling();
    test_closures();
    test_restart();

    if failures > 0 {
        print("FAILED ", failures, " of ", checks, " checks");
        exit(1);
    }
    print("ok: ", checks, " checks passed");
}
