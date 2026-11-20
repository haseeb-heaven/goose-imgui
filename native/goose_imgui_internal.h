/* goose_imgui_internal.h — the imgui_internal.h half of goose-imgui's shim.
 *
 * A `// goose:` line above each declaration gives the Goose signature that
 * scripts/generate_bindings.py emits into raw.goose, exactly as in
 * goose_imgui_shim.h.
 *
 * These are the few operations that exist only in Dear ImGui's C++ headers:
 * the DockBuilder layout API, style scaling, font loading through
 * ImFontAtlas, and multi-viewport (platform window) support. */

#ifndef IMGUI_GOOSE_INTERNAL_H
#define IMGUI_GOOSE_INTERNAL_H

#include <stdint.h>

#include "igs_api.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Builds a four-slot workspace (center, left, right, bottom) for the
 * dockspace `root`. Call once, before the windows it holds are submitted;
 * slot numbers are 0 center, 1 left, 2 right, 3 bottom. */
// goose: fn igs_internal_dock_build(root: u32, width: f32, height: f32, layout: i64) -> bool
bool igs_internal_dock_build(uint32_t root, float width, float height, int64_t layout);
// goose: fn igs_internal_dock_window(title: const u8[:], slot: i64)
void igs_internal_dock_window(igs_u8s title, int64_t slot);
// goose: fn igs_internal_dock_finish()
void igs_internal_dock_finish(void);

// goose: fn igs_internal_style_scale_all_sizes(scale: f32)
void igs_internal_style_scale_all_sizes(float scale);
// goose: fn igs_internal_load_font(path: const u8[:], size_px: f32) -> bool
bool igs_internal_load_font(igs_u8s path, float size_px);
// goose: fn igs_internal_enable_viewports(on: bool)
void igs_internal_enable_viewports(bool on);
// goose: fn igs_internal_render_platform_windows()
void igs_internal_render_platform_windows(void);

#ifdef __cplusplus
}
#endif

#endif /* IMGUI_GOOSE_INTERNAL_H */
