// widgets: the composite helpers over imgui's widgets.
//
// These are the pieces a real application writes once and then reuses: a
// labelled text field with its own buffer, a scrolling value history for a
// plot, a docking workspace, and the zero-separated item list a combo box
// takes. They sit in the package's `src/` directory, so a program imports
// them with `import imgui.src.widgets;`.
//
// Everything here is built from raw's extern fns, so this module does not
// depend on imgui.goose (which imports it).

namespace widgets;

import std;
import raw;

// --- item lists ---------------------------------------------------------

// The list a combo box takes: every item, then a NUL, then one more NUL.
// `combo("colours", index, ["red", "green", "blue"])`.
fn joined_z(items: const u8[:][:]) -> u8[>..] {
    var out: u8[>..] = [];
    for it in items {
        out.append(it);
        out.push(0);
    }
    out.push(0);
    return out;
}

fn count_z(list: const u8[:]) -> i64 {
    var n = 0;
    for i in 0..list.len {
        if list[i] == 0 { n += 1; }
    }
    return n;
}

// --- text fields --------------------------------------------------------

// A text field whose buffer the caller owns. Returns true when the text
// changed this frame. `buf` must have room for the text plus a NUL.
fn text_field(label: const u8[:], buf: u8[:]) -> bool {
    return raw::igs_input_text(label, buf, 0);
}

fn text_field(label: const u8[:], buf: u8[:], flags: i64) -> bool {
    return raw::igs_input_text(label, buf, flags);
}

fn text_field_hinted(label: const u8[:], hint: const u8[:], buf: u8[:], flags: i64) -> bool {
    return raw::igs_input_text_with_hint(label, hint, buf, flags);
}

fn text_area(label: const u8[:], buf: u8[:], width: f64, height: f64) -> bool {
    return raw::igs_input_text_multiline_sized(label, buf, width as f32, height as f32, 0);
}

// The text in a fixed buffer: the bytes before its first NUL.
fn text_value(buf: u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    for i in 0..buf.len {
        if buf[i] == 0 { break; }
        out.push(buf[i]);
    }
    return out;
}

// Replaces the text in a fixed buffer, NUL-terminated.
fn text_set(buf: u8[:], s: const u8[:]) {
    let n = min(s.len, max(buf.len - 1, 0));
    for i in 0..n { buf[i] = s[i]; }
    buf[n] = 0;
}

// --- a value history for plots ------------------------------------------
// The plot functions draw from a contiguous f32 array, so the history is one:
// it fills up, then scrolls, one element per frame at worst.

struct History {
    values: f32[128],
    count: i64,
    capacity: i64 = 128,
}

fn push(history: History&, value: f32) {
    let cap = min(max(history.capacity, 1), 128);
    if history.count < cap {
        history.values[history.count] = value;
        history.count += 1;
        return;
    }
    for i in 1..cap { history.values[i - 1] = history.values[i]; }
    history.values[cap - 1] = value;
}

fn values(history: const History&) -> const f32[:] {
    let cap = min(max(history.capacity, 1), 128);
    let n = min(history.count, cap);
    return history.values[0..n];
}

fn plot(history: const History&, label: const u8[:], lo: f64, hi: f64, width: f64, height: f64) {
    raw::igs_plot_lines_scaled(label, values(history), lo as f32, hi as f32, width as f32,
                               height as f32);
}

fn reset(history: History&) {
    history.count = 0;
}

// --- a docking workspace ------------------------------------------------
// The first frame builds the layout, the ones after just draw the dockspace.
// The window names are the ones the program submits.

struct Workspace {
    id: u32,
    built: bool,
}

fn workspace(name: const u8[:], width: f64, height: f64) -> Workspace {
    var ws = Workspace { id: raw::igs_dockspace_id(name), built: false };
    raw::igs_dockspace(ws.id, 0.0, 0.0, width as f32, height as f32, 0);
    if !ws.built {
        ws.built = raw::igs_internal_dock_build(ws.id, width as f32, height as f32, 0);
    }
    raw::igs_internal_dock_finish();
    return ws;
}

fn dock(window: const u8[:], slot: i64) {
    raw::igs_internal_dock_window(window, slot);
}

// --- small composite widgets --------------------------------------------

// A toggle that looks like a tab: pressed style while `active`.
fn toggle(label: const u8[:], active: bool) -> bool {
    if active {
        raw::igs_push_style_color(raw::col_button, raw::igs_get_color_u32(raw::col_button_active));
        defer raw::igs_pop_style_color();
        return raw::igs_button(label);
    }
    return raw::igs_button(label);
}

// A label and a value on one line, right-aligned within `width`.
fn stat(label: const u8[:], value: const u8[:], width: f64) {
    raw::igs_text(label);
    var lw: f32 = 0.0;
    var lh: f32 = 0.0;
    var vw: f32 = 0.0;
    var vh: f32 = 0.0;
    raw::igs_calc_text_size(label, lw, lh);
    raw::igs_calc_text_size(value, vw, vh);
    let gap = width - lw - vw;
    if gap > 0.0 { raw::igs_dummy(gap as f32, 0.0); }
    raw::igs_same_line();
    raw::igs_text(value);
}

// A vertical gradient-free header: a title, a rule, and the content indented.
// The block is the extra type argument (§"Function values"), not a parameter.
fn section<F>(title: const u8[:]) {
    raw::igs_separator_text(title);
    raw::igs_indent();
    defer raw::igs_unindent();
    F();
}
