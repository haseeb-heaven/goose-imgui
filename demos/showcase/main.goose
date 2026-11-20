// demos/showcase/main.goose — every corner of the binding, in one window.
//
// One tab per corner of Dear ImGui: controls, layout, text, data, canvas and
// dialogs. It is the demo to run when you want to know what this binding
// exposes and how a call looks.
//
//     goose build demos/showcase/main.goose
//     ./demos/showcase/main                                       # window
//     ./demos/showcase/main --shot screenshots/showcase.png --frames 30
//     ./demos/showcase/main --size 1280x800 --frames 3             # offscreen only

import imgui from "../..";
import imgui.raw;
import support from "../support";
import std;
import math;
import os;

struct State {
    enabled: bool,
    radio: i64,
    volume: f64,
    count: i64,
    angle: f64,
    speed: f64,
    volume_2d: f64[..2],
    color: f64[..3],
    name: u8[..64],
    path: u8[..256],
    combo: i64,
    text_long: u8[..512],
    tab: i64,
    show_dialog: bool,
    show_about: bool,
    texture: u64,
}

let ITEMS: const u8[:] = "Warm default\0Soft dark\0High contrast\0Nord\0Solarized\0";

// --- controls ------------------------------------------------------------

fn tab_controls(s: State&) {
    let available = imgui::content_avail();
    let half = available[0] * 0.5 - 8.0;
    if imgui::begin_child("controls-left", half, 0.0) {
        controls_left(s);
        imgui::end_child();
    }
    imgui::same_line();
    if imgui::begin_child("controls-right", 0.0, 0.0) {
        controls_right(s);
        imgui::end_child();
    }
}

fn controls_left(s: State&) {
    imgui::separator_text("buttons");
    if imgui::button("Save") { imgui::set_clipboard("saved"); }
    imgui::same_line();
    if imgui::button("Cancel") {}
    imgui::same_line();
    if imgui::small_button("small") {}
    imgui::same_line();
    imgui::begin_disabled(true);
    imgui::button("disabled");
    imgui::end_disabled();

    imgui::separator_text("toggles");
    if imgui::checkbox("enabled", s.enabled) {}
    imgui::same_line();
    if imgui::checkbox("2D mode", s.enabled) {}
    imgui::radio_button("low", s.radio, 0);
    imgui::same_line();
    imgui::radio_button("medium", s.radio, 1);
    imgui::same_line();
    imgui::radio_button("high", s.radio, 2);

    imgui::separator_text("numbers");
    imgui::set_next_item_width(200.0);
    if imgui::slider("volume", s.volume, 0.0, 1.0) {}
    imgui::set_next_item_width(200.0);
    if imgui::slider("count", s.count, 0, 100) {}
    imgui::set_next_item_width(200.0);
    if imgui::slider_angle("angle", s.angle, -180.0, 180.0) {}
    imgui::set_next_item_width(200.0);
    if imgui::drag("speed", s.speed, 0.01) {}
    imgui::set_next_item_width(200.0);
    if imgui::slider_n("offset", s.volume_2d[0], 2, -50.0, 50.0) {}
}

fn controls_right(s: State&) {
    imgui::separator_text("colour");
    imgui::set_next_item_width(200.0);
    if imgui::color_edit("tint", s.color[0], 3) {}

    imgui::separator_text("text");
    imgui::set_next_item_width(200.0);
    if imgui::input_text_with_hint("##name", "project name", s.name, 0) {}
    imgui::set_next_item_width(200.0);
    if imgui::input_text_with_hint("##path", "output folder", s.path, 0) {}

    imgui::separator_text("choices");
    imgui::set_next_item_width(200.0);
    if imgui::combo_z("theme", s.combo, ITEMS) {}
    imgui::same_line();
    if imgui::button("popup") { imgui::open_popup("controls-popup"); }
    if imgui::begin_popup("controls-popup") {
        imgui::text("A popup, closed by clicking outside it.");
        if imgui::button("close") { imgui::close_current_popup(); }
        imgui::end_popup();
    }

    imgui::separator_text("progress");
    let fraction = 0.5 + 0.5 * sin(imgui::time() * 1.5);
    imgui::progress(fraction, 200.0, 0.0, str((fraction * 100.0) as i64, "%"));
    imgui::progress(0.35, 200.0, 0.0, "35%");
}

// --- layout --------------------------------------------------------------

fn tab_layout(s: State&) {
    imgui::separator_text("table");
    if imgui::begin_table("processes", 4, imgui::TABLE_BORDERS | imgui::TABLE_RESIZABLE) {
        imgui::table_setup_column("process", imgui::WIDTH_STRETCH);
        imgui::table_setup_column("cpu", 0);
        imgui::table_setup_column("memory", 0);
        imgui::table_setup_column("state", 0);
        imgui::table_headers_row();
        let names: const u8[:][4] = ["radiant", "walker", "network", "audio"];
        for i in 0..4 {
            imgui::table_next_row();
            imgui::table_next_column();
            imgui::text(names[i]);
            imgui::table_next_column();
            imgui::text(str((3 + i * 7), ".", i, "%"));
            imgui::table_next_column();
            imgui::text(str((64 + i * 24), " MB"));
            imgui::table_next_column();
            if i % 2 == 0 { imgui::text_colored(0.5, 0.9, 0.6, 1.0, "running"); }
            else { imgui::text_colored(0.9, 0.85, 0.5, 1.0, "idle"); }
        }
        imgui::end_table();
    }

    imgui::separator_text("trees");
    if imgui::tree_node("scene") {
        if imgui::tree_node("level 1") {
            imgui::text("light");
            imgui::text("prop");
            imgui::tree_pop();
        }
        if imgui::tree_node("level 2") { imgui::text("actor"); imgui::tree_pop(); }
        imgui::tree_pop();
    }
    if imgui::collapsing_header("advanced") {
        imgui::text("collapsing headers hide detail until asked for");
        if imgui::slider("detail", s.volume, 0.0, 1.0) {}
    }

    imgui::separator_text("group and indent");
    imgui::indent();
    imgui::text("indented text");
    imgui::begin_group();
    imgui::text("inside a group");
    if imgui::button("group button") {}
    imgui::end_group();
    imgui::unindent();
}

// --- text ----------------------------------------------------------------

fn tab_text(s: State&) {
    imgui::heading("headings");
    imgui::label("label", "a value beside a name");
    imgui::text("plain text");
    imgui::text_colored(1.0, 0.6, 0.3, 1.0, "coloured text");
    imgui::text_muted("muted text, for annotations");
    imgui::bullet("a bullet");
    imgui::bullet("another bullet");
    imgui::separator();
    imgui::text_wrapped(str("Wrapped text measures the column it is in and breaks between ",
                            "words, so a long description fits a narrow panel without ",
                            "being cut off at the edge."));
    imgui::separator_text("tooltips");
    if imgui::button("hover me") {}
    if imgui::is_item_hovered() { imgui::tooltip("a tooltip from is_item_hovered"); }
    imgui::text(str("window: ", imgui::display_width(), "x", imgui::display_height(), " at ",
                    imgui::fps(), " fps"));
    imgui::text(str("text line height is ", imgui::text_line_height(), " px"));
    let size = imgui::calc_text_size("measured");
    imgui::text(str("this string measures ", size[0], "x", size[1]));
}

// --- data ----------------------------------------------------------------

fn make_texture() -> u64 {
    var pixels: u8[>..] = [];
    for y in 0..64 {
        for x in 0..64 {
            let checker = ((x / 8) + (y / 8)) % 2;
            pixels.push(if checker == 0 { 40 } else { 200 });
            pixels.push(if checker == 0 { 70 } else { 120 });
            pixels.push(if checker == 0 { 120 } else { 60 });
            pixels.push(255);
        }
    }
    return imgui::texture(64, 64, pixels);
}

fn tab_data(s: State&) {
    imgui::separator_text("plots");
    var wave: f32[..128] = [0.0; 128];
    for i in 0..128 {
        wave[i] = (sin(i * 0.12 + imgui::time()) * 0.5 + 0.5) as f32;
    }
    imgui::plot_lines("signal", wave, 0.0, 1.0, 300.0, 60.0);
    var histogram: f32[..32] = [0.0; 32];
    for i in 0..32 {
        histogram[i] = (abs(sin(i * 0.7)) * 40.0) as f32;
    }
    imgui::plot_histogram("histogram", histogram, 0.0,
                          max(histogram_peak(histogram), 1.0), 300.0, 60.0);

    imgui::separator_text("texture");
    if s.texture != 0 {
        imgui::image(s.texture, 64.0, 64.0);
        imgui::same_line();
        imgui::begin_group();
        imgui::text("a texture this binding uploaded:");
        imgui::text_muted("checker RGBA, 64x64, generated at start-up");
        if imgui::image_button("reload", s.texture, 32.0, 32.0) {
            imgui::update_texture(s.texture, 64, 64, checker_pixels());
        }
        imgui::end_group();
    }

    imgui::separator_text("selectables");
    for i in 0..4 {
        let label = str("item ", i);
        if imgui::selectable(label) { s.count = i; }
    }
}

fn histogram_peak(values: const f32[:]) -> f64 {
    var peak = 0.0;
    for i in 0..values.len {
        if values[i] > peak { peak = values[i]; }
    }
    return peak;
}

fn checker_pixels() -> u8[>..] {
    var pixels: u8[>..] = [];
    for y in 0..64 {
        for x in 0..64 {
            let checker = ((x / 8) + (y / 8)) % 2;
            pixels.push(if checker == 0 { 40 } else { 200 });
            pixels.push(if checker == 0 { 70 } else { 120 });
            pixels.push(if checker == 0 { 120 } else { 60 });
            pixels.push(255);
        }
    }
    return pixels;
}

// --- canvas --------------------------------------------------------------

fn tab_canvas(s: State&) {
    imgui::separator_text("draw list");
    let list = imgui::window_draw_list();
    let origin = imgui::cursor_screen_pos();
    let width = 420.0;
    let height = 220.0;
    let t = imgui::time() as f32;

    imgui::draw_rect_filled(list, origin[0], origin[1], origin[0] + width, origin[1] + height,
                            imgui::rgba(24, 28, 34, 255), 10.0);
    imgui::draw_rect(list, origin[0], origin[1], origin[0] + width, origin[1] + height,
                     imgui::rgba(70, 120, 180, 255), 10.0, 2.0);
    // A grid.
    var i = 1;
    while i < 10 {
        let x = origin[0] + width * (i / 10.0);
        imgui::draw_line(list, x, origin[1], x, origin[1] + height, imgui::rgba(40, 48, 60, 255), 1.0);
        let y = origin[1] + height * (i / 10.0);
        imgui::draw_line(list, origin[0], y, origin[0] + width, y, imgui::rgba(40, 48, 60, 255), 1.0);
        i += 1;
    }
    // A moving wave, drawn as a bezier chain.
    let segments = 24;
    var segment = 0;
    while segment < segments {
        let x0 = origin[0] + width * (segment / segments);
        let x1 = origin[0] + width * ((segment + 1) / segments);
        let y0 = origin[1] + height * 0.5 + sin(t + segment * 0.45) * height * 0.3;
        let y1 = origin[1] + height * 0.5 + sin(t + (segment + 1) * 0.45) * height * 0.3;
        imgui::draw_curve(list, x0, y0, x0 + 6.0, y0, x1 - 6.0, y1, x1, y1,
                          imgui::rgba(90, 200, 255, 255), 2.5);
        segment += 1;
    }
    // Circles and a triangle.
    let pulse = 10.0 + 4.0 * sin(t * 2.0);
    imgui::draw_circle(list, origin[0] + 60.0, origin[1] + 60.0, pulse,
                       imgui::rgba(255, 170, 90, 255));
    imgui::draw_circle_outline(list, origin[0] + 140.0, origin[1] + 60.0, 18.0,
                               imgui::rgba(150, 255, 170, 255), 2.0);
    imgui::draw_triangle(list, origin[0] + 200.0, origin[1] + 40.0, origin[0] + 230.0,
                         origin[1] + 90.0, origin[0] + 170.0, origin[1] + 90.0,
                         imgui::rgba(255, 110, 140, 255));
    imgui::draw_text(list, origin[0] + 20.0, origin[1] + height - 30.0,
                     imgui::rgba(220, 230, 240, 255), "drawn with the draw list");
    imgui::dummy(width, height);
}

// --- dialogs -------------------------------------------------------------

fn tab_dialogs(s: State&) {
    imgui::text("Popups, modals and menus, the three ways Dear ImGui asks a question.");
    if imgui::button("open a modal") { s.show_dialog = true; }
    imgui::same_line();
    if imgui::button("about") { s.show_about = true; }

    if imgui::begin_menu_bar() {
        if imgui::begin_menu("File") {
            if imgui::menu_item("Open", "Ctrl+O", false) {}
            if imgui::menu_item("Save", "Ctrl+S", false) {}
            imgui::separator();
            if imgui::menu_item("Quit", "Alt+F4", false) { imgui::quit(); }
            imgui::end_menu();
        }
        if imgui::begin_menu("Edit") {
            if imgui::menu_item("Undo", "Ctrl+Z", false) {}
            if imgui::menu_item_toggle("Enabled", s.enabled) {}
            imgui::end_menu();
        }
        imgui::end_menu_bar();
    }

    if s.show_dialog {
        imgui::open_popup_modal("dialog");
    }
    s.show_dialog = false;
    if imgui::begin_popup_modal("dialog") {
        imgui::text("This is a modal: the window behind it is inert until it closes.");
        imgui::separator();
        if imgui::button("OK") { imgui::close_current_popup(); }
        imgui::same_line();
        if imgui::button("Cancel") { imgui::close_current_popup(); }
        imgui::end_popup();
    }

    if s.show_about {
        imgui::open_popup_modal("about");
    }
    s.show_about = false;
    if imgui::begin_popup_modal("about") {
        imgui::heading("goose-imgui");
        imgui::text(str("Dear ImGui ", imgui::version(), " through a Goose binding."));
        imgui::text(str("driver: ", imgui::driver()));
        if imgui::button("Close") { imgui::close_current_popup(); }
        imgui::end_popup();
    }
}

// --- the window ----------------------------------------------------------

fn draw(s: State&, options: support::Options&) {
    if imgui::begin_window("goose-imgui showcase", imgui::NONE) {
        let tabs = ["Controls", "Layout", "Text", "Data", "Canvas", "Dialogs"];
        if imgui::begin_tab_bar("tabs") {
            for i in 0..6 {
                if imgui::begin_tab_item(tabs[i]) {
                    if i == 0 { tab_controls(s); }
                    else if i == 1 { tab_layout(s); }
                    else if i == 2 { tab_text(s); }
                    else if i == 3 { tab_data(s); }
                    else if i == 4 { tab_canvas(s); }
                    else { tab_dialogs(s); }
                    imgui::end_tab_item();
                }
            }
            imgui::end_tab_bar();
        }
        imgui::end_window();
    }
    imgui::text_muted(str("goose-imgui | ", imgui::version(), " | ", imgui::driver(),
                          " | vertices ", imgui::metrics_render_vertices()));
}

fn main() {
    var s = State {
        enabled: true,
        radio: 1,
        volume: 0.65,
        count: 12,
        angle: 0.5,
        speed: 1.25,
        volume_2d: [10.0, -20.0],
        color: [0.35, 0.65, 0.95],
        name: [0; 64],
        path: [0; 256],
        combo: 0,
        text_long: [0; 512],
        tab: 0,
        show_dialog: false,
        show_about: false,
        texture: 0,
    };
    var options = support::parse("goose-imgui | showcase", 880, 470);
    if !support::begin(options) { return; }
    defer imgui::shutdown();
    s.texture = make_texture();
    defer imgui::release_texture(s.texture);
    imgui::dark_theme();
    var frame = 0;
    while imgui::frame() {
        frame += 1;
        imgui::set_next_window_pos(8.0, 8.0, imgui::ALWAYS);
        imgui::set_next_window_size(options.width - 16.0, options.height - 16.0, imgui::ALWAYS);
        draw(s, options);
        imgui::end_frame();
        if support::finished(options, frame) { break; }
    }
}
