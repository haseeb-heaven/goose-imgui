// examples/calculator/main.goose — a scientific/programmer calculator.
//
// A complete little application rather than a widget gallery: an expression
// field with a real recursive-descent evaluator, a keypad, a tape of past
// results, a bit view for programming work and a light/dark theme toggle.
//
//     goose build examples/calculator/main.goose
//     ./examples/calculator/main
//
//     ./examples/calculator/main --shot screenshots/calculator.png --frames 30
//
// The second form renders offscreen, captures a real frame to PNG and exits;
// that is how screenshots/calculator.png was produced.

import imgui from "../..";
import imgui.raw;
import support from "../support";
import std;
import math;
import os;

// --- expression evaluator ------------------------------------------------
//
// or -> shift -> sum -> product -> unary -> power -> primary, loosest first.
// Numbers are decimal, 0x hexadecimal, 1e3 scientific; the named constants
// are pi and e and the one-argument functions are the math module's.

struct Parser {
    text: const u8[:],
    pos: i64,
    ok: bool,
}

fn at(p: Parser&) -> u8 {
    if p.pos < 0 || p.pos >= p.text.len { return 0; }
    return p.text[p.pos];
}

fn skip(p: Parser&) {
    while p.pos < p.text.len && (p.text[p.pos] == ' ' || p.text[p.pos] == '\t') { p.pos += 1; }
}

fn eat(p: Parser&, c: u8) -> bool {
    skip(p);
    if at(p) == c {
        p.pos += 1;
        return true;
    }
    return false;
}

// Matches `word` only when it is not the prefix of a longer name, so "or" is
// not read out of "order".
fn eat_word(p: Parser&, word: const u8[:]) -> bool {
    skip(p);
    if p.pos + word.len > p.text.len { return false; }
    for i in 0..word.len {
        if p.text[p.pos + i] != word[i] { return false; }
    }
    let after = p.text[p.pos + word.len];
    if after == 'a' && word.len == 2 && word == "or" { return false; }
    p.pos += word.len;
    return true;
}

fn digit_value(c: u8) -> i64 {
    if c >= '0' && c <= '9' { return c - '0'; }
    if c >= 'a' && c <= 'f' { return c - 'a' + 10; }
    if c >= 'A' && c <= 'F' { return c - 'A' + 10; }
    return -1;
}

recursive fn parse_value(p: Parser&) -> f64 {
    skip(p);
    let c = at(p);
    if c == '(' {
        p.pos += 1;
        let v = parse_or(p);
        if !eat(p, ')') { p.ok = false; }
        return v;
    }
    if c >= 'a' && c <= 'z' { return parse_name(p); }
    // 0x12ab
    if c == '0' && p.pos + 1 < p.text.len && (p.text[p.pos + 1] == 'x' || p.text[p.pos + 1] == 'X') {
        p.pos += 2;
        var value: i64 = 0;
        var digits = 0;
        while p.pos < p.text.len {
            let nibble = digit_value(p.text[p.pos]);
            if nibble < 0 { break; }
            value = value * 16 + nibble;
            p.pos += 1;
            digits += 1;
        }
        if digits == 0 { p.ok = false; }
        return value;
    }
    var value = 0.0;
    var seen = false;
    var fraction = false;
    var scale = 0.1;
    while p.pos < p.text.len {
        let d = p.text[p.pos];
        let digit = digit_value(d);
        if digit >= 0 && digit < 10 {
            if fraction {
                value += digit * scale;
                scale *= 0.1;
            } else {
                value = value * 10.0 + digit;
            }
            seen = true;
            p.pos += 1;
        } else if d == '.' && !fraction {
            fraction = true;
            seen = true;
            p.pos += 1;
        } else if (d == 'e' || d == 'E') && seen {
            p.pos += 1;
            var sign = 1.0;
            if at(p) == '-' {
                sign = -1.0;
                p.pos += 1;
            } else if at(p) == '+' {
                p.pos += 1;
            }
            var exponent = 0.0;
            while at(p) >= '0' && at(p) <= '9' {
                exponent = exponent * 10.0 + (at(p) - '0');
                p.pos += 1;
            }
            return value * pow(10.0, sign * exponent);
        } else {
            break;
        }
    }
    if !seen { p.ok = false; }
    return value;
}

recursive fn parse_name(p: Parser&) -> f64 {
    var name: u8[8] = [0; 8];
    var n = 0;
    while p.pos < p.text.len && p.text[p.pos] >= 'a' && p.text[p.pos] <= 'z' && n < 7 {
        name[n] = p.text[p.pos];
        p.pos += 1;
        n += 1;
    }
    let word = name[0..n];
    if word == "pi" { return 3.141592653589793; }
    if word == "e" { return 2.718281828459045; }
    let arg = parse_unary(p);
    if word == "sin" { return sin(arg); }
    if word == "cos" { return cos(arg); }
    if word == "tan" { return tan(arg); }
    if word == "asin" { return asin(arg); }
    if word == "acos" { return acos(arg); }
    if word == "atan" { return atan(arg); }
    if word == "sqrt" { return sqrt(arg); }
    if word == "log" { return log(arg); }
    if word == "log2" { return log2(arg); }
    if word == "exp" { return exp(arg); }
    if word == "abs" { return abs(arg); }
    if word == "floor" { return floor(arg); }
    if word == "ceil" { return ceil(arg); }
    if word == "round" { return round(arg); }
    p.ok = false;
    return 0.0;
}

recursive fn parse_power(p: Parser&) -> f64 {
    let base = parse_value(p);
    if eat(p, '^') { return pow(base, parse_unary(p)); }
    return base;
}

recursive fn parse_unary(p: Parser&) -> f64 {
    skip(p);
    if at(p) == '-' {
        p.pos += 1;
        return -parse_unary(p);
    }
    if at(p) == '+' {
        p.pos += 1;
        return parse_unary(p);
    }
    if at(p) == '~' {
        p.pos += 1;
        let inverted: i64 = ~(parse_unary(p) as i64);
        return inverted;
    }
    return parse_power(p);
}

recursive fn parse_product(p: Parser&) -> f64 {
    var value = parse_unary(p);
    loop {
        skip(p);
        let c = at(p);
        if c == '*' {
            p.pos += 1;
            value = value * parse_unary(p);
        } else if c == '/' {
            p.pos += 1;
            let divisor = parse_unary(p);
            if divisor == 0.0 {
                p.ok = false;
                return 0.0;
            }
            value = value / divisor;
        } else if c == '%' {
            p.pos += 1;
            value = value % parse_unary(p);
        } else {
            return value;
        }
    }
}

recursive fn parse_sum(p: Parser&) -> f64 {
    var value = parse_product(p);
    loop {
        skip(p);
        let c = at(p);
        if c == '+' {
            p.pos += 1;
            value = value + parse_product(p);
        } else if c == '-' {
            p.pos += 1;
            value = value - parse_product(p);
        } else {
            return value;
        }
    }
}

recursive fn parse_shift(p: Parser&) -> f64 {
    var value = parse_sum(p) as i64;
    loop {
        skip(p);
        if eat_word(p, "<<") {
            value = value << (parse_sum(p) as i64);
        } else if eat_word(p, ">>") {
            value = value >> (parse_sum(p) as i64);
        } else if eat_word(p, "and") {
            value = value & (parse_sum(p) as i64);
        } else if eat_word(p, "or") {
            value = value | (parse_sum(p) as i64);
        } else if eat_word(p, "xor") {
            value = value ^ (parse_sum(p) as i64);
        } else {
            return value;
        }
    }
}

recursive fn parse_or(p: Parser&) -> f64 {
    return parse_shift(p);
}

fn evaluate(text: const u8[:]) -> f64, bool {
    var p = Parser { text: text, pos: 0, ok: true };
    let value = parse_or(p);
    skip(p);
    if p.pos < p.text.len { p.ok = false; }
    return value, p.ok;
}

// --- formatting ----------------------------------------------------------

fn format_value(out: u8[>..]&, value: f64) {
    if value != value {
        out.append("nan");
        return;
    }
    let rounded = round(value);
    if abs(value - rounded) < 1e-12 && abs(value) < 1e15 {
        format(out, rounded as i64);
        return;
    }
    format(out, value);
}

fn format_hex(out: u8[>..]&, value: i64) {
    out.append("0x");
    var digits: u8[>..] = [];
    var v = value;
    if v < 0 { v = -v; out.insert_at(0, '-'); }
    if v == 0 { digits.push('0'); }
    while v != 0 {
        let nibble = (v & 15) as u8;
        if nibble < 10 {
            digits.push(nibble + '0');
        } else {
            digits.push(nibble - 10 + 'A');
        }
        v = v >> 4;
    }
    for i in 0..digits.len {
        out.push(digits[digits.len - 1 - i]);
    }
}

// --- state ---------------------------------------------------------------

let TAPE_CAPACITY = 64;

struct Entry {
    expression: u8[..120],
    result: u8[..48],
}

struct Calc {
    expression: u8[..256],
    result: f64,
    error: bool,
    hex_view: bool,
    dark: bool,
    tape: Entry[>..],   // a growable field, so it has to come last
}

fn text_len(buf: const u8[:]) -> i64 {
    var n = 0;
    while n < buf.len && buf[n] != 0 { n += 1; }
    return n;
}

fn expression_text(c: Calc&) -> const u8[:] {
    return c.expression[0..text_len(c.expression)]
}

fn set_expression(c: Calc&, text: const u8[:]) {
    let n = min(text.len, c.expression.len - 1);
    for i in 0..n { c.expression[i] = text[i]; }
    c.expression[n] = 0;
}

fn insert(c: Calc&, text: const u8[:]) {
    let n = expression_text(c).len;
    let room = max(c.expression.len - n - 1, 0);
    let count = min(text.len, room);
    for i in 0..count { c.expression[n + i] = text[i]; }
    c.expression[n + count] = 0;
}

fn backspace(c: Calc&) {
    let n = expression_text(c).len;
    if n > 0 { c.expression[n - 1] = 0; }
}

fn clear(c: Calc&) {
    c.expression[0] = 0;
    c.result = 0.0;
    c.error = false;
}

fn push_tape(c: Calc&, expression: const u8[:], value: f64) {
    var entry = Entry { expression: [0; 120], result: [0; 48] };
    let n = min(expression.len, entry.expression.len - 1);
    for i in 0..n { entry.expression[i] = expression[i]; }
    var shown: u8[>..] = [];
    format_value(shown, value);
    let m = min(shown.len, entry.result.len - 1);
    for i in 0..m { entry.result[i] = shown[i]; }
    c.tape.push(entry);
    if c.tape.len > TAPE_CAPACITY { remove_at(c.tape, 0); }
}

fn commit(c: Calc&) {
    let text = expression_text(c);
    if text.len == 0 { return; }
    let value, ok = evaluate(text);
    if !ok {
        c.error = true;
        return;
    }
    c.result = value;
    c.error = false;
    push_tape(c, text, value);
}

// --- the window ----------------------------------------------------------

fn press(c: Calc&, label: const u8[:]) {
    if label == "=" {
        commit(c);
    } else if label == "C" {
        clear(c);
    } else if label == "<x" {
        backspace(c);
    } else if label == "AC" {
        clear(c);
    } else if label == "( )" {
        insert(c, "()");
    } else if label == "x^2" {
        insert(c, "^2");
    } else {
        insert(c, label);
    }
}

fn cell(c: Calc&, label: const u8[:], width: f64) {
    imgui::table_next_column();
    if imgui::button(label, width, 34.0) { press(c, label); }
}

// One keypad row: five cells, so a row reads like the calculator it draws.
fn key_row(c: Calc&, a: const u8[:], b: const u8[:], d: const u8[:], e: const u8[:],
           f: const u8[:], width: f64) {
    imgui::table_next_row();
    cell(c, a, width);
    cell(c, b, width);
    cell(c, d, width);
    cell(c, e, width);
    cell(c, f, width);
}

fn wide_key(c: Calc&, label: const u8[:], width: f64) {
    if imgui::button(label, width, 30.0) { press(c, label); }
}

fn keypad(c: Calc&) {
    let width = max(imgui::content_avail()[0] / 5.0 - 6.0, 20.0);
    if imgui::begin_table("keypad", 5, imgui::TABLE_ROW_BG) {
        for i in 0..5 { imgui::table_setup_column(str(i), imgui::WIDTH_STRETCH); }
        key_row(c, "sin(", "cos(", "tan(", "sqrt(", "abs(", width);
        key_row(c, "7", "8", "9", "/", "C", width);
        key_row(c, "4", "5", "6", "*", "<x", width);
        key_row(c, "1", "2", "3", "-", "%", width);
        key_row(c, "0", ".", "^", "+", "=", width);
        imgui::end_table();
    }
    let wide = max(imgui::content_avail()[0] / 6.0 - 6.0, 20.0);
    wide_key(c, "and ", wide);
    imgui::same_line();
    wide_key(c, "or ", wide);
    imgui::same_line();
    wide_key(c, "xor ", wide);
    imgui::same_line();
    wide_key(c, "<< ", wide);
    imgui::same_line();
    wide_key(c, ">> ", wide);
    imgui::same_line();
    wide_key(c, "~", wide);

    wide_key(c, "0x", wide);
    imgui::same_line();
    wide_key(c, "pi", wide);
    imgui::same_line();
    wide_key(c, "e ", wide);
    imgui::same_line();
    wide_key(c, "x^2", wide);
    imgui::same_line();
    wide_key(c, "( )", wide);
    imgui::same_line();
    wide_key(c, "AC", wide);
}

fn tape(c: Calc&) {
    imgui::text_muted(str(c.tape.len, " results, newest first"));
    if c.tape.len == 0 {
        imgui::text_muted("press = to save one");
        return;
    }
    for i in 0..c.tape.len {
        let index = c.tape.len - 1 - i;
        let entry = c.tape[index];
        var label: u8[>..] = [];
        label.append(entry.expression[0..text_len(entry.expression)]);
        label.append(" = ");
        label.append(entry.result[0..text_len(entry.result)]);
        if imgui::selectable(label, false, imgui::SELECTABLE_SPAN_ALL_COLUMNS) {
            set_expression(c, entry.expression[0..text_len(entry.expression)]);
        }
    }
}

// The result as a 32 bit word, high half over low half so it fits a narrow
// column without wrapping.
fn bits(c: Calc&) {
    let value = c.result as i64;
    imgui::separator_text("result as bits");
    for half in 0..2 {
        var text: u8[>..] = [];
        for i in 0..16 {
            let shift = 31 - (half * 16 + i);
            if ((value >> shift) & 1) == 1 {
                text.push('1');
            } else {
                text.push('0');
            }
            if (i + 1) % 4 == 0 && i != 15 { text.push(' '); }
        }
        imgui::text_colored(0.55, 0.8, 1.0, 1.0, text);
    }
    var hex: u8[>..] = [];
    format_hex(hex, value);
    imgui::text_muted(str(hex, "   ", c.result));
}

fn layout(c: Calc&) {
    let flags = imgui::NO_TITLE_BAR | imgui::NO_RESIZE | imgui::NO_MOVE;
    if imgui::begin_window("calculator", flags) {
        if imgui::begin_menu_bar() {
            if imgui::begin_menu("Calculator") {
                if imgui::menu_item("Copy result") { imgui::set_clipboard(strs(c)); }
                if imgui::menu_item("Clear all", "", false) { clear(c); }
                imgui::end_menu();
            }
            if imgui::begin_menu("View") {
                if imgui::menu_item_toggle("Hexadecimal result", c.hex_view) {}
                if imgui::menu_item_toggle("Dark theme", c.dark) {}
                imgui::end_menu();
            }
            if imgui::begin_menu("Help") {
                imgui::menu_item("Type an expression and press Enter", "", false);
                imgui::menu_item("0x10, <<, >>, and, or, xor, ~ all work", "", false);
                imgui::menu_item("Click a tape entry to reuse it", "", false);
                imgui::end_menu();
            }
            imgui::end_menu_bar();
        }

        imgui::set_next_item_width(imgui::content_avail()[0]);
        if imgui::input_text("##expression", c.expression, imgui::INPUT_ENTER_RETURNS_TRUE) {
            commit(c);
        }
        var shown: u8[>..] = [];
        if c.error {
            shown.append("cannot evaluate");
        } else {
            format_value(shown, c.result);
            if c.hex_view {
                shown.append("   ");
                format_hex(shown, c.result as i64);
            }
        }
        if c.error {
            imgui::text_colored(1.0, 0.45, 0.4, 1.0, shown);
        } else {
            imgui::text_colored(0.6, 0.85, 1.0, 1.0, shown);
        }
        imgui::separator();

        let available = imgui::content_avail();
        let body = max(available[1] - 24.0, 120.0);
        if imgui::begin_child("keys", available[0] * 0.62, body) {
            keypad(c);
            imgui::end_child();
        }
        imgui::same_line();
        if imgui::begin_child("side", 0.0, body, imgui::BORDERS) {
            tape(c);
            bits(c);
            imgui::end_child();
        }
        imgui::text_muted("Enter evaluates, Esc clears, click a result to reuse it");
        imgui::end_window();
    }
}

fn strs(c: Calc&) -> u8[>..] {
    var text: u8[>..] = [];
    if c.error {
        text.append("error");
    } else {
        format_value(text, c.result);
    }
    return text;
}

// --- entry point ---------------------------------------------------------

fn run(options: support::Options&, c: Calc&) {
    if !support::begin(options) { return; }
    defer imgui::shutdown();
    var light = false;

    var frame = 0;
    while imgui::frame() {
        frame += 1;
        imgui::set_next_window_pos(0.0, 0.0, imgui::ALWAYS);
        imgui::set_next_window_size(options.width, options.height, imgui::ALWAYS);
        // The style is a context-wide setting, so it is applied when the
        // choice changes rather than every frame.
        if c.dark == light {
            if c.dark {
                imgui::dark_theme();
            } else {
                imgui::light_theme();
            }
            light = !c.dark;
        }
        layout(c);
        if imgui::key_pressed(raw::key_escape) { clear(c); }
        if imgui::key_pressed(raw::key_backspace) { backspace(c); }
        imgui::end_frame();
        if support::finished(options, frame) { break; }
    }
}

fn main() {
    var c = Calc {
        expression: [0; 256],
        result: 0.0,
        error: false,
        hex_view: false,
        dark: true,
        tape: [],
    };
    push_tape(c, "0.1 + 0.2", 0.3);
    push_tape(c, "(17 << 3) or 5", 141.0);
    push_tape(c, "sqrt(144) * 2 + 0x1f", 55.0);
    // Opening on a worked expression, so the first frame is a real session.
    insert(c, "2^10 - 24");
    commit(c);
    var options = support::parse("goose-imgui | calculator", 760, 430);
    run(options, c);
}
