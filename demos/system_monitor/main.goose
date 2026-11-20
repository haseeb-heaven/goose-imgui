// demos/system_monitor/main.goose — a live system monitor.
//
// Everything on screen is drawn from real numbers where they exist (frame
// time, frames per second, frame count) and from a deterministic synthetic
// load otherwise, so the demo looks the same on every machine and animates
// while it runs. It is the demo to read for rolling plots, gauges drawn with
// the draw list, a resizable two-column layout and a scrolling log.
//
//     goose build demos/system_monitor/main.goose
//     ./demos/system_monitor/main
//     ./demos/system_monitor/main --shot screenshots/system_monitor.png --frames 30

import imgui from "../..";
import imgui.raw;
import support from "../support";
import std;
import math;
import os;

let HISTORY = 160;
let PROCESSES = 7;

struct Process {
    name: u8[..32],
    cpu: f64,
    memory: f64,
    threads: i64,
    selected: bool,
}

struct Monitor {
    cpu_history: f32[..HISTORY],
    memory_history: f32[..HISTORY],
    network_history: f32[..HISTORY],
    cpu: f64,
    memory: f64,
    network: f64,
    disk: f64,
    paused: bool,
    dark: bool,
    seconds: f64,
    frames_seen: u64,
    log: u8[..120][..200],   // 200 lines of up to 120 bytes
    log_count: i64,
    processes: Process[>..],   // a growable field comes last
}

fn push_history(history: f32[:], value: f64) {
    for i in 1..history.len {
        history[i - 1] = history[i];
    }
    history[history.len - 1] = value as f32;
}

// A smooth pseudo-random walk: a sum of sines with unrelated periods, which
// looks like load without needing a random number generator or state.
fn wave(t: f64, a: f64, b: f64, c: f64) -> f64 {
    let v = 0.5 + 0.3 * sin(t * a) + 0.12 * sin(t * b + 1.7) + 0.08 * sin(t * c + 3.1);
    return clamp(v, 0.0, 1.0);
}

// The log keeps the newest 200 lines in a fixed array, oldest first.
fn log_line(m: Monitor&, text: const u8[:]) {
    if m.log_count == m.log.len {
        for i in 1..m.log.len { m.log[i - 1] = m.log[i]; }
        m.log_count = m.log.len - 1;
    }
    let n = min(text.len, m.log[0].len - 1);
    for i in 0..n { m.log[m.log_count][i] = text[i]; }
    m.log[m.log_count][n] = 0;
    m.log_count += 1;
}

fn sample(m: Monitor&, dt: f64) {
    if m.paused { return; }
    m.seconds += dt;
    m.frames_seen += 1;
    m.cpu = wave(m.seconds, 0.9, 2.3, 5.1) * 100.0;
    m.memory = 38.0 + 22.0 * wave(m.seconds * 4.0, 0.5, 1.3, 3.1);
    m.network = wave(m.seconds * 0.7, 1.3, 3.7, 0.9) * 940.0;
    m.disk = wave(m.seconds * 0.3, 0.41, 1.1, 2.9) * 520.0;
    push_history(m.cpu_history, m.cpu);
    push_history(m.memory_history, m.memory);
    push_history(m.network_history, m.network);

    for i in 0..m.processes.len {
        let p = m.processes[i];
        let phase = (i as f64) * 1.37;
        p.cpu = clamp(p.cpu * 0.86 + wave(m.seconds + phase, 1.1, 2.7, 6.3) * 22.0, 0.0, 100.0);
        p.memory = clamp(p.memory + (wave(m.seconds + phase, 0.23, 0.9, 1.9) - 0.5) * 3.0, 4.0, 512.0);
    }
}

// --- drawing helpers -----------------------------------------------------

// A ring gauge: a full circle for scale and an arc for the value, drawn with
// the window's own draw list so it sits inline with the widgets.
fn gauge(label: const u8[:], fraction: f64, text: const u8[:], radius: f64) {
    let list = imgui::window_draw_list();
    let pos = imgui::cursor_screen_pos();
    let center_x = pos[0] + radius + 6.0;
    let center_y = pos[1] + radius + 6.0;
    let size = radius * 2.0;
    imgui::dummy(size + 12.0, size + 12.0);

    imgui::draw_circle(list, center_x, center_y, radius, imgui::rgba(34, 40, 50, 255));

    // The value arc: short segments from twelve o'clock, clockwise, the colour
    // moving from blue to amber to red as the load rises.
    let value = clamp(fraction, 0.0, 1.0);
    let segments = 48;
    let filled = (value * segments) as i64;
    let colour = if value > 0.85 {
        imgui::rgba(240, 110, 110, 255)
    } else if value > 0.65 {
        imgui::rgba(240, 190, 110, 255)
    } else {
        imgui::rgba(110, 200, 240, 255)
    };
    // The value arc, as thick bezier pieces of at most a right angle each: the
    // draw list's own curve primitive keeps it smooth at any radius.
    let r = radius - 1.0;
    var drawn = 0.0;
    while drawn < value * 6.283185307179586 - 0.0001 {
        let sweep = min(1.5707963267948966, value * 6.283185307179586 - drawn);
        arc(list, center_x, center_y, r, drawn - 1.5707963267948966,
            drawn + sweep - 1.5707963267948966, colour, 11.0);
        drawn += sweep;
    }

    // The value in the middle, measured so it is centred whatever it says.
    let measured = imgui::calc_text_size(text);
    imgui::draw_text(list, center_x - measured[0] * 0.5, center_y - measured[1] * 0.5,
                     imgui::rgba(235, 240, 250, 255), text);
    imgui::text_muted(label);
}

// One bezier piece of a circle: the control points sit on the tangents, at the
// distance that makes a cubic bezier follow the arc to within a pixel.
fn arc(list: u64, cx: f64, cy: f64, r: f64, from: f64, to: f64, colour: u32, thickness: f64) {
    let sweep = to - from;
    let k = (4.0 / 3.0) * tan(sweep / 4.0) * r;
    let x0 = cx + cos(from) * r;
    let y0 = cy + sin(from) * r;
    let x3 = cx + cos(to) * r;
    let y3 = cy + sin(to) * r;
    let x1 = x0 - sin(from) * k;
    let y1 = y0 + cos(from) * k;
    let x2 = x3 + sin(to) * k;
    let y2 = y3 - cos(to) * k;
    imgui::draw_curve(list, x0, y0, x1, y1, x2, y2, x3, y3, colour, thickness);
}

fn stat_row(name: const u8[:], value: const u8[:], fraction: f64) {
    imgui::text(name);
    imgui::same_line(120.0);
    imgui::text_colored(0.85, 0.9, 1.0, 1.0, value);
    imgui::same_line(220.0);
    imgui::push_style_color(imgui::col_plot_histogram(), imgui::rgba(110, 200, 240, 255));
    imgui::progress(clamp(fraction, 0.0, 1.0), 130.0, 6.0, "");
    imgui::pop_style_color();
}

// --- panels --------------------------------------------------------------

fn overview(m: Monitor&, width: f64) {
    imgui::separator_text("load");
    let third = (width - 32.0) / 3.0;
    if imgui::begin_child("gauge-cpu", third, 132.0) {
        gauge("cpu", m.cpu / 100.0, str(m.cpu as i64, "%"), 38.0);
        imgui::end_child();
    }
    imgui::same_line();
    if imgui::begin_child("gauge-memory", third, 132.0) {
        gauge("memory", m.memory / 100.0, str(m.memory as i64, "%"), 38.0);
        imgui::end_child();
    }
    imgui::same_line();
    if imgui::begin_child("gauge-frames", third, 132.0) {
        let fps = imgui::fps();
        gauge("frames", clamp(fps / 120.0, 0.0, 1.0), str(fps as i64, " fps"), 38.0);
        imgui::end_child();
    }

    imgui::separator_text("history");
    imgui::text_muted("cpu, last 160 samples");
    imgui::plot_lines("##cpu", m.cpu_history, 0.0, 100.0, width, 54.0);
    imgui::plot_lines("##memory", m.memory_history, 0.0, 100.0, width, 38.0);
    imgui::text_muted("network, kb/s");
    imgui::plot_lines("##network", m.network_history, 0.0, 1000.0, width, 38.0);

    imgui::separator_text("throughput");
    stat_row("network", str(m.network as i64, " kb/s"), m.network / 1000.0);
    stat_row("disk", str(m.disk as i64, " kb/s"), m.disk / 1000.0);
    let frame_ms = imgui::delta_time() * 1000.0;
    stat_row("frame", str(frame_ms, " ms"), clamp(frame_ms / 16.7, 0.0, 1.0));
}

fn process_table(m: Monitor&, width: f64) {
    imgui::separator_text("processes");
    let flags = imgui::TABLE_BORDERS | imgui::TABLE_ROW_BG | imgui::TABLE_RESIZABLE;
    if imgui::begin_table("processes", 4, flags) {
        imgui::table_setup_column("name", imgui::WIDTH_STRETCH);
        imgui::table_setup_column("cpu", imgui::WIDTH_FIXED, 70.0);
        imgui::table_setup_column("memory", imgui::WIDTH_FIXED, 84.0);
        imgui::table_setup_column("threads", imgui::WIDTH_FIXED, 66.0);
        imgui::table_headers_row();
        for i in 0..m.processes.len {
            let p = m.processes[i];
            imgui::table_next_row();
            imgui::table_next_column();
            if imgui::selectable(p.name[0..text_len(p.name)], p.selected,
                                 imgui::SELECTABLE_SPAN_ALL_COLUMNS) {
                p.selected = !p.selected;
                log_line(m, str("selected ", p.name[0..text_len(p.name)]));
            }
            imgui::table_next_column();
            let kb = p.cpu / 100.0;
            if kb > 0.85 {
                imgui::text_colored(1.0, 0.55, 0.5, 1.0, str(p.cpu as i64, "%"));
            } else {
                imgui::text(str(p.cpu as i64, "%"));
            }
            imgui::table_next_column();
            imgui::text(str(p.memory as i64, " MB"));
            imgui::table_next_column();
            imgui::text(str(p.threads));
        }
        imgui::end_table();
    }

    imgui::separator_text("log");
    let height = max(imgui::content_avail()[1] - 8.0, 60.0);
    if imgui::begin_child("log", 0.0, height, imgui::BORDERS) {
        for i in 0..m.log_count {
            imgui::text_muted(m.log[i][0..text_len(m.log[i])]);
        }
        // Only keep the view at the newest line when it was already there.
        if imgui::scroll_max_y() > 0.0 && imgui::scroll_y() >= imgui::scroll_max_y() - 4.0 {
            imgui::set_scroll_here_y(1.0);
        }
        imgui::end_child();
    }
}

fn text_len(buf: const u8[:]) -> i64 {
    var n = 0;
    while n < buf.len && buf[n] != 0 { n += 1; }
    return n;
}

fn main() {
    var options = support::parse("goose-imgui | system monitor", 980, 640);
    if !support::begin(options) { return; }
    defer imgui::shutdown();
    imgui::dark_theme();

    var m = Monitor {
        cpu_history: [0.0; HISTORY],
        memory_history: [0.0; HISTORY],
        network_history: [0.0; HISTORY],
        cpu: 0.0,
        memory: 0.0,
        network: 0.0,
        disk: 0.0,
        log: [[0; 120]; 200],
        log_count: 0,
        processes: [],
        paused: false,
        dark: true,
        seconds: 0.0,
        frames_seen: 0,
    };
    // A few seconds of history, so the first frame already shows a plot.
    m.seconds = 0.0;
    for i in 0..HISTORY {
        m.seconds += 0.02;
        push_history(m.cpu_history, wave(m.seconds, 0.9, 2.3, 5.1) * 100.0);
        push_history(m.memory_history, 38.0 + 22.0 * wave(m.seconds * 4.0, 0.5, 1.3, 3.1));
        push_history(m.network_history, wave(m.seconds * 0.7, 1.3, 3.7, 0.9) * 940.0);
    }
    let names = ["radiant", "walker", "networkd", "audio", "render", "script", "indexer"];
    for i in 0..PROCESSES {
        var p = Process { name: [0; 32], cpu: 0.0, memory: 0.0, threads: 0, selected: false };
        let name = names[i];
        for j in 0..name.len { p.name[j] = name[j]; }
        p.cpu = 4.0 + i * 6.0;
        p.memory = 48.0 + i * 24.0;
        p.threads = 2 + i * 3;
        m.processes.push(p);
    }
    log_line(m, "monitor started");
    log_line(m, "sampling frame time, load and process table");
    log_line(m, "7 processes, 3 gauges, 160 samples of history");
    log_line(m, "select a process to see it named here");
    // One sample before the first frame, so the gauges start at a real value.
    sample(m, 1.0 / 60.0);

    imgui::set_next_window_pos(8.0, 8.0, imgui::ALWAYS);
    imgui::set_next_window_size(options.width - 16.0, options.height - 16.0, imgui::ALWAYS);

    var frame = 0;
    while imgui::frame() {
        frame += 1;
        sample(m, imgui::delta_time());

        imgui::set_next_window_pos(8.0, 8.0, imgui::ALWAYS);
        imgui::set_next_window_size(options.width - 16.0, options.height - 16.0, imgui::ALWAYS);
        if imgui::begin_window("goose-imgui | system monitor", imgui::NONE) {
            if imgui::begin_menu_bar() {
                if imgui::begin_menu("Monitor") {
                    if imgui::menu_item("Clear log") {
                        m.log_count = 0;
                        log_line(m, "log cleared");
                    }
                    if imgui::menu_item_toggle("Pause sampling", m.paused) {}
                    imgui::separator();
                    if imgui::menu_item("Quit", "Esc", false) { imgui::quit(); }
                    imgui::end_menu();
                }
                if imgui::begin_menu("View") {
                    if imgui::menu_item_toggle("Dark theme", m.dark) {}
                    imgui::end_menu();
                }
                imgui::end_menu_bar();
            }

            if m.paused {
                imgui::text_colored(1.0, 0.75, 0.4, 1.0, "paused");
                imgui::same_line();
            }
            imgui::text_muted(str("frame ", m.frames_seen, "  ", imgui::driver(), "  ",
                                  imgui::version()));

            let available = imgui::content_avail();
            let left = available[0] * 0.55 - 8.0;
            if imgui::begin_child("overview", left, 0.0) {
                overview(m, left - 16.0);
                imgui::end_child();
            }
            imgui::same_line();
            if imgui::begin_child("details", 0.0, 0.0) {
                process_table(m, available[0] * 0.45 - 24.0);
                imgui::end_child();
            }
            imgui::end_window();
        }
        if imgui::key_pressed(raw::key_escape) { imgui::quit(); }
        imgui::end_frame();
        if support::finished(options, frame) { break; }
    }
}
