// examples/support/support.goose — command line and screen-capture plumbing that
// every demo shares, so each demo file is about its own UI and nothing else.
namespace support;

import imgui from "../..";
import std;
import os;

// What every demo accepts:
//
//     --size 900x600      window and offscreen size
//     --frames 30         stop after this many frames
//     --shot path.png     render offscreen, save one real frame, exit
//     --headless          offscreen with no window at all
struct Options {
    title: const u8[:],
    width: i64,
    height: i64,
    frames: i64,
    path: u8[..512],
    headless: bool,
}

fn text_len(buf: const u8[:]) -> i64 {
    var n = 0;
    while n < buf.len && buf[n] != 0 { n += 1; }
    return n;
}

fn path_of(options: Options&) -> const u8[:] {
    return options.path[0..text_len(options.path)]
}

fn parse(title: const u8[:], width: i64, height: i64) -> Options {
    var options = Options {
        title: title, width: width, height: height, frames: 0, path: [0; 512], headless: false,
    };
    let argv = args();
    var i = 1;
    while i < argv.len {
        let option = argv[i];
        if option == "--shot" && i + 1 < argv.len {
            i += 1;
            let path = argv[i];
            let n = min(path.len, options.path.len - 1);
            for j in 0..n { options.path[j] = path[j]; }
            options.path[n] = 0;
        } else if option == "--frames" && i + 1 < argv.len {
            i += 1;
            let n, ok = parse_int(argv[i]);
            if ok { options.frames = n; }
        } else if option == "--headless" {
            options.headless = true;
        } else if option == "--size" && i + 1 < argv.len {
            i += 1;
            let text = argv[i];
            var at = 0;
            while at < text.len && text[at] != 'x' { at += 1; }
            if at < text.len {
                let w, ok_w = parse_int(text[0..at]);
                let h, ok_h = parse_int(text[at + 1..]);
                if ok_w && ok_h {
                    options.width = w;
                    options.height = h;
                }
            }
        }
        i += 1;
    }
    return options;
}

// Opens the window (or an offscreen target), prints the driver on the way in,
// and returns whether the demo can draw. Call `finish` when the frame loop is
// over: it saves the screenshot if one was asked for.
fn begin(options: Options&) -> bool {
    let headless = options.headless || path_of(options).len > 0;
    var opened = false;
    if headless {
        opened = imgui::init_offscreen(options.width, options.height);
    } else {
        opened = imgui::init(options.title, options.width, options.height);
    }
    if !opened {
        write_stderr(str(options.title, ": ", imgui::error(), "\n"));
        return false;
    }
    print(options.title, ": driver=", imgui::driver(), " imgui=", imgui::version(),
          " dpi=", imgui::dpi_scale(), " space=", imgui::display_width(), "x",
          imgui::display_height());
    return true;
}

// True on the frame the loop should stop after: the screenshot is written
// first, so a captured frame is exactly the frame that was asked for.
fn finished(options: Options&, frame: i64) -> bool {
    let target = if options.frames > 0 { options.frames } else { 1 << 24 };
    let path = path_of(options);
    if path.len > 0 && frame >= max(target, 6) {
        if !imgui::screenshot(path) {
            write_stderr(str(options.title, ": ", imgui::error(), "\n"));
        }
        return true;
    }
    return frame >= target;
}
