// examples/node_graph/main.goose — a node graph editor on a custom canvas.
//
// The canvas is drawn entirely with the draw list: a grid that follows the
// view, rounded node cards with title bars and ports, and bezier links with a
// pulse travelling along them. The interaction is real: drag a node with the
// left button, drag the background to pan, scroll to zoom, click a node to
// inspect it in the side panel, press A to add one and Delete to remove one.
//
//     goose build examples/node_graph/main.goose
//     ./examples/node_graph/main
//     ./examples/node_graph/main --shot screenshots/node_graph.png --frames 30

import imgui from "../..";
import imgui.raw;
import support from "../support";
import std;
import math;
import os;

let NODE_WIDTH = 172.0;
let NODE_HEIGHT = 78.0;
let PORT_RADIUS = 4.5;

// kind: 0 input, 1 process, 2 output. The colour follows the kind, so the
// graph reads without labels.
struct Node {
    title: u8[..40],
    x: f64,
    y: f64,
    kind: i64,
}

struct Link {
    from: i64,
    to: i64,
}

// Nodes and links live in fixed arrays with a count: two growable fields
// cannot share a struct, and a graph editor's size is bounded anyway.
let MAX_NODES = 64;
let MAX_LINKS = 128;

struct Graph {
    nodes: Node[..MAX_NODES],
    links: Link[..MAX_LINKS],
    node_count: i64,
    link_count: i64,
    pan: f64[..2],
    zoom: f64,
    selected: i64,
    dragging: i64,
    panning: bool,
    status: u8[..160],
    new_title: u8[..40],
    dark: bool,
}

fn text_len(buf: const u8[:]) -> i64 {
    var n = 0;
    while n < buf.len && buf[n] != 0 { n += 1; }
    return n;
}

fn title_of(node: Node&) -> const u8[:] {
    return node.title[0..text_len(node.title)];
}

fn set_title(node: Node&, text: const u8[:]) {
    let n = min(text.len, node.title.len - 1);
    for i in 0..n { node.title[i] = text[i]; }
    node.title[n] = 0;
}

fn say(g: Graph&, text: const u8[:]) {
    let n = min(text.len, g.status.len - 1);
    for i in 0..n { g.status[i] = text[i]; }
    g.status[n] = 0;
}

fn add_node(g: Graph&, title: const u8[:], x: f64, y: f64, kind: i64) -> i64 {
    if g.node_count >= g.nodes.len { return -1; }
    var node = Node { title: [0; 40], x: x, y: y, kind: kind };
    set_title(node, title);
    g.nodes[g.node_count] = node;
    g.node_count += 1;
    return g.node_count - 1;
}

fn link(g: Graph&, from: i64, to: i64) {
    if g.link_count >= g.links.len { return; }
    g.links[g.link_count] = Link { from: from, to: to };
    g.link_count += 1;
}

fn remove_node(g: Graph&, index: i64) {
    if index < 0 || index >= g.node_count { return; }
    for i in index + 1..g.node_count {
        g.nodes[i - 1] = g.nodes[i];
    }
    g.node_count -= 1;
    // Links to the removed node go with it, and the ones after it move down.
    var kept: Link[..MAX_LINKS] = [Link { from: 0, to: 0 }; MAX_LINKS];
    var kept_count = 0;
    for i in 0..g.link_count {
        let l = g.links[i];
        if l.from == index || l.to == index { continue; }
        var from = l.from;
        var to = l.to;
        if from > index { from -= 1; }
        if to > index { to -= 1; }
        kept[kept_count] = Link { from: from, to: to };
        kept_count += 1;
    }
    g.links = kept;
    g.link_count = kept_count;
    g.selected = -1;
}

fn kind_colour(kind: i64) -> u32 {
    if kind == 0 { return imgui::rgba(96, 190, 240, 255); }
    if kind == 1 { return imgui::rgba(120, 220, 150, 255); }
    return imgui::rgba(240, 170, 110, 255);
}

fn kind_name(kind: i64) -> const u8[:] {
    if kind == 0 { return "input"; }
    if kind == 1 { return "process"; }
    return "output";
}

// --- canvas --------------------------------------------------------------

// Where a node sits in graph space, and where its ports are.
fn port_out(node: Node&) -> f64[2] {
    return [node.x + NODE_WIDTH, node.y + NODE_HEIGHT * 0.5];
}

fn port_in(node: Node&) -> f64[2] {
    return [node.x, node.y + NODE_HEIGHT * 0.5];
}

fn to_screen(origin: f32[2], g: Graph&, x: f64, y: f64) -> f64[2] {
    return [origin[0] + g.pan[0] + x * g.zoom, origin[1] + g.pan[1] + y * g.zoom];
}

fn to_graph(origin: f32[2], g: Graph&, x: f32, y: f32) -> f64[2] {
    return [(x - origin[0] - g.pan[0]) / g.zoom, (y - origin[1] - g.pan[1]) / g.zoom];
}

fn draw_grid(list: u64, origin: f32[2], g: Graph&, width: f64, height: f64) {
    let step = 28.0 * g.zoom;
    if step < 8.0 { return; }
    let offset_x = (origin[0] + g.pan[0]) % step;
    let offset_y = (origin[1] + g.pan[1]) % step;
    let line = imgui::rgba(44, 50, 62, 255);
    let major = imgui::rgba(58, 66, 82, 255);
    var i = 0;
    while i * step + offset_x < width {
        let x = origin[0] + i * step + offset_x;
        let colour = if (i % 4) == 0 { major } else { line };
        imgui::draw_line(list, x, origin[1], x, origin[1] + height, colour, 1.0);
        i += 1;
    }
    var j = 0;
    while j * step + offset_y < height {
        let y = origin[1] + j * step + offset_y;
        let colour = if (j % 4) == 0 { major } else { line };
        imgui::draw_line(list, origin[0], y, origin[0] + width, y, colour, 1.0);
        j += 1;
    }
}

fn draw_link(list: u64, origin: f32[2], g: Graph&, l: Link, index: i64, time: f64) {
    if l.from < 0 || l.from >= g.node_count || l.to < 0 || l.to >= g.node_count { return; }
    let a = port_out(g.nodes[l.from]);
    let b = port_in(g.nodes[l.to]);
    let p0 = to_screen(origin, g, a[0], a[1]);
    let p3 = to_screen(origin, g, b[0], b[1]);
    let reach = max((p3[0] - p0[0]) * 0.45, 40.0);
    let p1x = p0[0] + reach;
    let p1y = p0[1];
    let p2x = p3[0] - reach;
    let p2y = p3[1];
    imgui::draw_curve(list, p0[0], p0[1], p1x, p1y, p2x, p2y, p3[0], p3[1],
                      imgui::rgba(120, 135, 160, 255), 2.0);

    // A pulse travelling the link, so a still frame still shows the flow.
    let t = ((time * 0.35 + index * 0.21) % 1.0);
    let point = bezier(p0[0], p0[1], p1x, p1y, p2x, p2y, p3[0], p3[1], t);
    imgui::draw_circle(list, point[0], point[1], 3.5, imgui::rgba(140, 220, 255, 255));
}

fn bezier(x0: f64, y0: f64, x1: f64, y1: f64, x2: f64, y2: f64, x3: f64, y3: f64,
          t: f64) -> f64[2] {
    let u = 1.0 - t;
    let a = u * u * u;
    let b = 3.0 * u * u * t;
    let c = 3.0 * u * t * t;
    let d = t * t * t;
    return [a * x0 + b * x1 + c * x2 + d * x3, a * y0 + b * y1 + c * y2 + d * y3];
}

fn draw_node(list: u64, origin: f32[2], g: Graph&, index: i64, hovered: bool) {
    let node = g.nodes[index];
    let p = to_screen(origin, g, node.x, node.y);
    let w = NODE_WIDTH * g.zoom;
    let h = NODE_HEIGHT * g.zoom;
    let selected = index == g.selected;
    let rounding = 7.0;

    imgui::draw_rect_filled(list, p[0] + 2.0, p[1] + 3.0, p[0] + w + 2.0, p[1] + h + 3.0,
                            imgui::rgba(12, 14, 18, 120), rounding);
    imgui::draw_rect_filled(list, p[0], p[1], p[0] + w, p[1] + h, imgui::rgba(38, 44, 56, 255),
                            rounding);
    // Title bar in the node's kind colour.
    imgui::draw_rect_filled(list, p[0], p[1], p[0] + w, p[1] + 26.0 * g.zoom,
                            kind_colour(node.kind), rounding);
    imgui::draw_rect_filled(list, p[0], p[1] + 18.0 * g.zoom, p[0] + w, p[1] + 26.0 * g.zoom,
                            kind_colour(node.kind), 0.0);
    let border = if selected {
        imgui::rgba(255, 255, 255, 235)
    } else if hovered {
        imgui::rgba(160, 200, 240, 255)
    } else {
        imgui::rgba(70, 80, 96, 255)
    };
    imgui::draw_rect(list, p[0], p[1], p[0] + w, p[1] + h, border, rounding, if selected { 2.0 } else { 1.0 });

    if g.zoom > 0.35 {
        // Text follows the zoom, so a card keeps its proportions.
        let font_size = 15.0 * g.zoom;
        imgui::draw_text_sized(list, p[0] + 9.0 * g.zoom, p[1] + 5.0 * g.zoom, font_size,
                               imgui::rgba(20, 24, 30, 255), title_of(g.nodes[index]));
        imgui::draw_text_sized(list, p[0] + 9.0 * g.zoom, p[1] + 32.0 * g.zoom, font_size * 0.85,
                               imgui::rgba(175, 185, 200, 255), kind_name(node.kind));
        // A fake value line, so the card looks like it carries data.
        imgui::draw_rect_filled(list, p[0] + 10.0, p[1] + 52.0 * g.zoom,
                                p[0] + w - 10.0, p[1] + 58.0 * g.zoom,
                                imgui::rgba(28, 33, 42, 255), 3.0);
        imgui::draw_rect_filled(list, p[0] + 10.0, p[1] + 52.0 * g.zoom,
                                p[0] + 10.0 + (w - 20.0) * (0.25 + 0.6 * node.kind / 2.0),
                                p[1] + 58.0 * g.zoom, kind_colour(node.kind), 3.0);
    }

    let in_port = to_screen(origin, g, node.x, node.y + NODE_HEIGHT * 0.5);
    let out_port = to_screen(origin, g, node.x + NODE_WIDTH, node.y + NODE_HEIGHT * 0.5);
    imgui::draw_circle(list, in_port[0], in_port[1], PORT_RADIUS, kind_colour(node.kind));
    imgui::draw_circle(list, out_port[0], out_port[1], PORT_RADIUS, imgui::rgba(230, 235, 245, 255));
}

fn hit_test(g: Graph&, origin: f32[2], mouse: f32[2]) -> i64 {
    let point = to_graph(origin, g, mouse[0], mouse[1]);
    var i = g.node_count - 1;
    while i >= 0 {
        let node = g.nodes[i];
        if point[0] >= node.x && point[0] <= node.x + NODE_WIDTH &&
           point[1] >= node.y && point[1] <= node.y + NODE_HEIGHT {
            return i;
        }
        i -= 1;
    }
    return -1;
}

fn canvas(g: Graph&, width: f64, height: f64) {
    let flags = imgui::NO_SCROLLBAR | imgui::NO_SCROLL_WITH_MOUSE;
    if !imgui::begin_child("canvas", width, height, imgui::BORDERS, flags) {
        return;
    }
    defer imgui::end_child();

    let list = imgui::window_draw_list();
    let origin = imgui::cursor_screen_pos();
    draw_grid(list, origin, g, width, height);

    // The background button is what the pointer lands on when it misses every
    // node: it makes the canvas hoverable without stealing the node drags.
    imgui::invisible_button("##canvas-surface", width, height);
    let hovered = imgui::is_item_hovered() && !imgui::want_mouse();
    let mouse = imgui::mouse_pos();
    let delta = imgui::mouse_delta();
    let wheel = imgui::mouse_wheel();
    let time = imgui::time();

    // Zooming looks at the pointer: the point under it stays under it.
    if hovered && wheel[0] != 0.0 {
        let before = to_graph(origin, g, mouse[0], mouse[1]);
        g.zoom = clamp(g.zoom * (1.0 + wheel[0] as f64 * 0.12), 0.35, 2.5);
        let after = to_graph(origin, g, mouse[0], mouse[1]);
        g.pan[0] += (after[0] - before[0]) * g.zoom;
        g.pan[1] += (after[1] - before[1]) * g.zoom;
    }

    // Pan with the middle button, or with the left button on empty space.
    if hovered && imgui::mouse_clicked(raw::mouse_button_left) && hit_test(g, origin, mouse) < 0 {
        g.panning = true;
        g.dragging = -1;
        g.selected = -1;
    }
    if imgui::mouse_clicked(raw::mouse_button_middle) && hovered { g.panning = true; }
    if g.panning {
        g.pan[0] += delta[0];
        g.pan[1] += delta[1];
        if !imgui::mouse_down(raw::mouse_button_left) && !imgui::mouse_down(raw::mouse_button_middle) {
            g.panning = false;
        }
    }

    // Links first, so nodes sit on top of them.
    for i in 0..g.link_count {
        draw_link(list, origin, g, g.links[i], i, time);
    }

    let hover_node = if hovered { hit_test(g, origin, mouse) } else { -1 };
    if hovered && imgui::mouse_clicked(raw::mouse_button_left) && hover_node >= 0 {
        g.selected = hover_node;
        g.dragging = hover_node;
        say(g, str("dragging ", title_of(g.nodes[hover_node])));
    }
    if g.dragging >= 0 {
        if imgui::mouse_down(raw::mouse_button_left) && g.dragging < g.node_count {
            // A reference, not a copy: `let node = g.nodes[i]` would move a
            // struct into a local and drop the change at the end of the block.
            let node = &g.nodes[g.dragging];
            node.x += delta[0] / g.zoom;
            node.y += delta[1] / g.zoom;
        } else {
            g.dragging = -1;
        }
    }

    for i in 0..g.node_count {
        draw_node(list, origin, g, i, i == hover_node);
    }

    if g.node_count == 0 {
        imgui::draw_text(list, origin[0] + 24.0, origin[1] + 24.0, imgui::rgba(150, 160, 175, 255),
                         "press A to add a node");
    }
}

// --- side panel ----------------------------------------------------------

fn fit(g: Graph&, width: f64, height: f64) {
    if g.node_count == 0 { return; }
    var min_x = 1e30;
    var min_y = 1e30;
    var max_x = -1e30;
    var max_y = -1e30;
    for i in 0..g.node_count {
        let n = g.nodes[i];
        min_x = min(min_x, n.x);
        min_y = min(min_y, n.y);
        max_x = max(max_x, n.x + NODE_WIDTH);
        max_y = max(max_y, n.y + NODE_HEIGHT);
    }
    let graph_width = max(max_x - min_x, 1.0);
    let graph_height = max(max_y - min_y, 1.0);
    // Fitting shrinks to at most 0.75: below that the labels stop being
    // readable, and the user can zoom out further by hand if they want to.
    g.zoom = clamp(min((width - 24.0) / graph_width, (height - 24.0) / graph_height), 0.75, 1.5);
    g.pan[0] = (width - graph_width * g.zoom) * 0.5 - min_x * g.zoom;
    g.pan[1] = (height - graph_height * g.zoom) * 0.5 - min_y * g.zoom;
}

fn inspector(g: Graph&) {
    imgui::separator_text("graph");
    imgui::text(str(g.node_count, " nodes, ", g.link_count, " links"));
    if imgui::slider("zoom", g.zoom, 0.35, 2.5) {}
    if imgui::button("fit to view") { say(g, "fitted the whole graph"); }
    imgui::same_line();
    if imgui::button("reset zoom") {
        g.zoom = 1.0;
        g.pan[0] = 0.0;
        g.pan[1] = 0.0;
    }

    imgui::separator_text("add");
    imgui::set_next_item_width(150.0);
    if imgui::input_text_with_hint("##new-title", "node title", g.new_title,
                                   imgui::INPUT_ENTER_RETURNS_TRUE) {
        let name = g.new_title[0..text_len(g.new_title)];
        if name.len > 0 {
            let x = 40.0 - g.pan[0] / g.zoom + g.node_count * 12.0;
            let y = 40.0 - g.pan[1] / g.zoom + g.node_count * 18.0;
            let added = add_node(g, name, x, y, 1);
            say(g, str("added ", name));
            g.selected = added;
        }
        g.new_title[0] = 0;
    }
    if imgui::button("input") {
        add_node(g, "source", 60.0 + g.node_count * 24.0, 60.0, 0);
        say(g, "added an input node");
    }
    imgui::same_line();
    if imgui::button("process") {
        add_node(g, "transform", 120.0 + g.node_count * 24.0, 160.0, 1);
        say(g, "added a process node");
    }
    imgui::same_line();
    if imgui::button("output") {
        add_node(g, "sink", 180.0 + g.node_count * 24.0, 260.0, 2);
        say(g, "added an output node");
    }

    imgui::separator_text("selected");
    if g.selected < 0 || g.selected >= g.node_count {
        imgui::text_muted("click a node to inspect it");
    } else {
        // A reference, so the widgets below edit the node itself.
        let node = &g.nodes[g.selected];
        imgui::text(str("node ", g.selected, " | ", kind_name(node.kind)));
        imgui::set_next_item_width(180.0);
        if imgui::input_text("##title", node.title, 0) {}
        if imgui::drag("x", node.x, 1.0) {}
        imgui::set_next_item_width(180.0);
        if imgui::drag("y", node.y, 1.0) {}
        let kinds: const u8[:] = "input\0process\0output\0";
        if imgui::combo_z("kind", node.kind, kinds) {}
        if imgui::button("delete") { remove_node(g, g.selected); say(g, "node removed"); }
        imgui::same_line();
        if imgui::button("clone") {
            let copy = add_node(g, title_of(node), node.x + 32.0, node.y + 32.0, node.kind);
            say(g, str("cloned into node ", copy));
        }
    }

    imgui::separator_text("keys");
    imgui::text_muted("A  add node");
    imgui::text_muted("Delete  remove selected");
    imgui::text_muted("F  fit to view");
    imgui::text_muted("Esc  quit");
    imgui::separator();
    imgui::text_wrapped(g.status[0..text_len(g.status)]);
}

// --- window --------------------------------------------------------------

// The canvas is the window less the side panel, its padding and its
// scrollbar-less border: fit into what is really left.
fn canvas_width(options: support::Options&) -> f64 {
    return options.width - 316.0;
}

fn canvas_height(options: support::Options&) -> f64 {
    return options.height - 118.0;
}

fn seed(g: Graph&) {
    let a = add_node(g, "camera", 30.0, 130.0, 0);
    let b = add_node(g, "denoise", 230.0, 30.0, 1);
    let c = add_node(g, "tone map", 230.0, 250.0, 1);
    let d = add_node(g, "composite", 430.0, 140.0, 1);
    let e = add_node(g, "display", 610.0, 140.0, 2);
    link(g, a, b);
    link(g, a, c);
    link(g, b, d);
    link(g, c, d);
    link(g, d, e);
    say(g, "5 nodes seeded: drag one, or scroll to zoom");
}

fn main() {
    var options = support::parse("goose-imgui | node graph", 1000, 620);
    if !support::begin(options) { return; }
    defer imgui::shutdown();
    imgui::dark_theme();

    var g = Graph {
        nodes: [Node { title: [0; 40], x: 0.0, y: 0.0, kind: 0 }; MAX_NODES],
        links: [Link { from: 0, to: 0 }; MAX_LINKS],
        node_count: 0,
        link_count: 0,
        pan: [0.0, 0.0],
        zoom: 1.0,
        selected: 2,
        dragging: -1,
        panning: false,
        status: [0; 160],
        new_title: [0; 40],
        dark: true,
    };
    seed(g);
    // Fit the seeded graph into the canvas the first frame will draw.
    fit(g, canvas_width(options), canvas_height(options));

    imgui::set_next_window_pos(8.0, 8.0, imgui::ALWAYS);
    imgui::set_next_window_size(options.width - 16.0, options.height - 16.0, imgui::ALWAYS);

    var frame = 0;
    while imgui::frame() {
        frame += 1;
        imgui::set_next_window_pos(8.0, 8.0, imgui::ALWAYS);
        imgui::set_next_window_size(options.width - 16.0, options.height - 16.0, imgui::ALWAYS);
        if imgui::begin_window("goose-imgui | node graph", imgui::NONE) {
            let available = imgui::content_avail();
            let panel = 240.0;
            if imgui::begin_child("panel", panel, 0.0, imgui::BORDERS) {
                inspector(g);
                imgui::end_child();
            }
            imgui::same_line();
            canvas(g, available[0] - panel - 12.0, available[1]);
            imgui::end_window();
        }

        // Keyboard: the canvas is focused by being in the window.
        if !imgui::want_keyboard() {
            if imgui::key_pressed(raw::key_a) {
                add_node(g, "node", 100.0 + g.node_count * 28.0, 120.0, 1);
                say(g, "added a node with A");
            }
            if imgui::key_pressed(raw::key_delete) && g.selected >= 0 {
                remove_node(g, g.selected);
                say(g, "removed the selected node");
            }
            if imgui::key_pressed(raw::key_f) {
                fit(g, canvas_width(options), canvas_height(options));
                say(g, "fitted the graph to the view");
            }
        }
        if imgui::key_pressed(raw::key_escape) { imgui::quit(); }
        imgui::end_frame();
        if support::finished(options, frame) { break; }
    }
}
