// examples/system_monitor/main.goose — a live system monitor of this machine.
//
// Nothing on screen is invented: CPU load, memory in use, network throughput,
// free disk, load average, uptime and the process table all come from the
// operating system, through sysinfo.c (compiled with the program by
// main.build: mach host statistics, sysctl and libproc on macOS, /proc on
// Linux). Frame time and frames per second are measured by the binding. Where
// a probe is unavailable the monitor says so instead of drawing a number.
//
// It is the example to read for rolling plots, gauges drawn with the draw list,
// a resizable two-column layout, a virtual-feeling process table and a log.
//
//     goose build examples/system_monitor/main.goose
//     ./examples/system_monitor/main
//     ./examples/system_monitor/main --shot screenshots/system_monitor.png --frames 30

import imgui from "../..";
import imgui.raw;
import support from "../support";
import std;
import math;
import os;

// sysinfo.c, compiled with this program (main.build). Each of these reads the
// machine, not a table: sys_sample refreshes them all and is the only call that
// walks the process list.
extern fn sys_sample() -> bool;
extern fn sys_cpu_usage() -> f64;                              // 0..1, since the last sample
extern fn sys_mem_used() -> u64;                               // bytes
extern fn sys_mem_total() -> u64;                              // bytes
extern fn sys_load_average(index: i64) -> f64;                 // 0, 1 or 2 minutes
extern fn sys_uptime() -> f64;                                 // seconds
extern fn sys_disk(path: const u8[:], free: u64&, total: u64&) -> bool;
extern fn sys_net_bytes(rx: u64&, tx: u64&) -> bool;           // cumulative bytes
extern fn sys_process_count() -> i64;
extern fn sys_process(i: i64, name: u8[:], cpu: f64&, mem: u64&, threads: i64&) -> bool;

let HISTORY = 160;
let ROWS = 14;             // what the table shows
let GIGABYTE = 1073741824.0;

struct Process {
    name: u8[..40],
    cpu: f64,
    memory: u64,
    threads: i64,
    selected: bool,
}

struct Monitor {
    cpu_history: f32[..HISTORY],
    memory_history: f32[..HISTORY],
    network_history: f32[..HISTORY],
    cpu: f64,             // 0..100
    memory: f64,          // 0..100
    memory_used: f64,     // GB
    memory_total: f64,    // GB
    network: f64,         // kbit/s, received plus sent
    net_rx: u64,          // cumulative bytes at the previous sample
    disk_free: f64,       // GB
    disk_total: f64,      // GB
    load: f64,
    uptime: f64,
    threads: i64,
    processes_seen: i64,
    sampling_ok: bool,
    paused: bool,
    dark: bool,
    seconds: f64,
    frames_seen: u64,
    log: u8[..120][..200],   // 200 lines of up to 120 bytes
    log_count: i64,
    processes: Process[>..],   // a growable field comes last
}

// One decimal, so a quotient of two byte counts reads as "5.8 GB" instead of
// as the shortest round-trip form of the division.
fn one_decimal(value: f64) -> f64 {
    return round(value * 10.0) / 10.0;
}

fn push_history(history: f32[:], value: f64) {
    for i in 1..history.len {
        history[i - 1] = history[i];
    }
    history[history.len - 1] = value as f32;
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

// One trip to the operating system: everything the panels show, refreshed.
fn sample(m: Monitor&, dt: f64) {
    if m.paused { return; }
    m.seconds += dt;
    m.frames_seen += 1;

    let ok = sys_sample();
    if !m.sampling_ok && ok { log_line(m, "system probes online"); }
    if m.sampling_ok && !ok { log_line(m, "system probes stopped answering"); }
    m.sampling_ok = ok;
    if !ok { return; }

    m.cpu = clamp(sys_cpu_usage() * 100.0, 0.0, 100.0);
    m.memory_total = sys_mem_total() / GIGABYTE;
    m.memory_used = sys_mem_used() / GIGABYTE;
    m.memory = if m.memory_total > 0.0 {
        clamp(m.memory_used / m.memory_total * 100.0, 0.0, 100.0)
    } else {
        0.0
    };
    m.load = sys_load_average(0);
    m.uptime = sys_uptime();

    // Network is cumulative, so the rate needs the previous reading.
    var rx: u64 = 0;
    var tx: u64 = 0;
    if sys_net_bytes(rx, tx) {
        let total = rx + tx;
        if m.net_rx > 0 && total >= m.net_rx && dt > 0.0 {
            // bytes/second to kbit/s, which is what an interface reports.
            m.network = (total - m.net_rx) / dt * 8.0 / 1000.0;
        }
        m.net_rx = total;
    }

    var free: u64 = 0;
    var total: u64 = 0;
    if sys_disk("/", free, total) {
        m.disk_free = free / GIGABYTE;
        m.disk_total = total / GIGABYTE;
    }

    push_history(m.cpu_history, m.cpu);
    push_history(m.memory_history, m.memory);
    push_history(m.network_history, m.network);
    refresh_processes(m);
}

// The process table is the process list of the machine, busiest first, which is
// what sysinfo.c keeps: the top rows of it, refreshed with every sample.
fn refresh_processes(m: Monitor&) {
    let count = min(sys_process_count(), ROWS);
    m.processes_seen = sys_process_count();
    var threads = 0;
    for i in 0..count {
        if i >= m.processes.len {
            m.processes.push(Process { name: [0; 40], cpu: 0.0, memory: 0,
                                       threads: 0, selected: false });
        }
        // A reference, so the row is the array's own element; `let p = ...`
        // would copy it and every assignment below would be dropped.
        let p = &m.processes[i];
        // The name is filled in a local array and copied in: a fixed array
        // field of a packed struct is a value, and handing a slice of it to C
        // would hand over a copy.
        var name: u8[..40] = [0; 40];
        var cpu = 0.0;
        var memory: u64 = 0;
        var count_threads: i64 = 0;
        if sys_process(i, name, cpu, memory, count_threads) {
            for j in 0..p.name.len { p.name[j] = name[j]; }
            p.cpu = cpu * 100.0;
            p.memory = memory;
            p.threads = count_threads;
        } else {
            p.name[0] = 0;
        }
        threads += p.threads;
    }
    for i in count..m.processes.len {
        m.processes[i].name[0] = 0;
    }
    m.threads = threads;
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
    if !m.sampling_ok {
        imgui::text_colored(1.0, 0.75, 0.4, 1.0,
                            "no system probes on this platform: showing frame timing only");
    }
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

    imgui::text_muted(str("memory ", one_decimal(m.memory_used), " of ",
                          one_decimal(m.memory_total), " GB",
                          "   load ", one_decimal(m.load), "   up ",
                          one_decimal(m.uptime / 3600.0), " h"));

    imgui::separator_text("history");
    imgui::text_muted("cpu, last 160 samples, percent");
    imgui::plot_lines("##cpu", m.cpu_history, 0.0, 100.0, width, 54.0);
    imgui::text_muted("memory, percent");
    imgui::plot_lines("##memory", m.memory_history, 0.0, 100.0, width, 38.0);
    // The ceiling follows the data, so an idle link still shows its shape.
    let peak = max(peer_ceiling(m), 100.0);
    imgui::text_muted(str("network, kbit/s, peak ", peak as i64));
    imgui::plot_lines("##network", m.network_history, 0.0, peak, width, 38.0);

    imgui::separator_text("counters");
    stat_row("network", str(m.network as i64, " kbit/s"), clamp(m.network / 10000.0, 0.0, 1.0));
    let used = if m.disk_total > 0.0 { 1.0 - m.disk_free / m.disk_total } else { 0.0 };
    stat_row("disk used", str(one_decimal(m.disk_total - m.disk_free), " of ",
                              one_decimal(m.disk_total), " GB"),
             used);
    stat_row("threads", str(m.threads), clamp(m.threads / 400.0, 0.0, 1.0));
    let frame_ms = imgui::delta_time() * 1000.0;
    stat_row("frame", str(frame_ms, " ms"), clamp(frame_ms / 16.7, 0.0, 1.0));
}

fn peak_of(values: const f32[:]) -> f64 {
    var peak = 0.0;
    for i in 0..values.len { peak = max(peak, values[i]); }
    return peak;
}

// A plot ceiling a little above the peak, so a spike does not touch the top.
fn peer_ceiling(m: Monitor&) -> f64 {
    return one_decimal(peak_of(m.network_history) * 1.15);
}

fn process_table(m: Monitor&, width: f64) {
    imgui::separator_text(str("processes, busiest ", min(m.processes_seen, ROWS), " of ",
                              m.processes_seen));
    let flags = imgui::TABLE_BORDERS | imgui::TABLE_ROW_BG | imgui::TABLE_RESIZABLE;
    if imgui::begin_table("processes", 4, flags) {
        imgui::table_setup_column("name", imgui::WIDTH_STRETCH);
        imgui::table_setup_column("cpu", imgui::WIDTH_FIXED, 70.0);
        imgui::table_setup_column("memory", imgui::WIDTH_FIXED, 84.0);
        imgui::table_setup_column("threads", imgui::WIDTH_FIXED, 66.0);
        imgui::table_headers_row();
        for i in 0..m.processes.len {
            let p = &m.processes[i];
            if p.name[0] == 0 { continue; }
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
            imgui::text(str(p.memory / 1048576, " MB"));
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
        memory_used: 0.0,
        memory_total: 0.0,
        network: 0.0,
        net_rx: 0,
        disk_free: 0.0,
        disk_total: 0.0,
        load: 0.0,
        uptime: 0.0,
        threads: 0,
        processes_seen: 0,
        sampling_ok: false,
        log: [[0; 120]; 200],
        log_count: 0,
        processes: [],
        paused: false,
        dark: true,
        seconds: 0.0,
        frames_seen: 0,
    };
    log_line(m, "monitor started");
    log_line(m, str("probes: ", imgui::driver(), " on this machine, 160 samples of history"));
    // Two samples before the first frame: the second one has a previous reading
    // to difference against, so CPU and network start at real rates instead of
    // at zero. The gap is the monitor's own sample spacing.
    sample(m, 1.0 / 60.0);
    // Fill the plot with real samples taken a few milliseconds apart, so the
    // window opens with a history instead of a flat line. Same probes, same
    // maths, only a shorter interval than the frame loop uses.
    for i in 0..80 {
        sleep_ms(12);
        sample(m, 0.012);
    }
    log_line(m, str(m.processes_seen, " processes, ", one_decimal(m.memory_total),
                    " GB of memory"));
    log_line(m, "select a process to see it named here");

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
