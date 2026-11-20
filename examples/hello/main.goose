// examples/hello/main.goose — the smallest complete goose-imgui program.
//
// One window, two widgets and a clean exit: the README's quickstart, with the
// shared plumbing so it also runs unattended and can write a screenshot.
//
//     goose build examples/hello/main.goose && ./examples/hello/main
//
//     ./examples/hello/main --shot screenshots/hello.png --frames 30
//
// The first form opens a real window: drag the slider, press the button or
// close the window to leave. The second renders offscreen and writes a PNG.

import imgui from "../..";
import support from "../support";

fn main() {
    var options = support::parse("goose-imgui | hello", 480, 240);
    if !support::begin(options) { return; }
    defer imgui::shutdown();

    var volume = 0.5;
    var frame = 0;
    while imgui::frame() {
        frame += 1;
        imgui::window("hello", imgui::ALWAYS_AUTO_RESIZE) {
            imgui::text("hello, goose");
            if imgui::slider("volume", volume, 0.0, 1.0) {}
            imgui::same_line();
            imgui::text_muted(str(volume * 100.0, "%"));
            if imgui::button("quit") { imgui::quit(); }
        }
        imgui::end_frame();
        if support::finished(options, frame) { break; }
    }
}
