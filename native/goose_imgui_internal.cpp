// goose_imgui_internal.cpp — the imgui_internal.h half of the shim.
//
// This is the only translation unit that includes Dear ImGui's C++ headers.
// dcimgui.h defines C mirrors of ImGui's structs (layout-compatible by
// construction, see dcimgui.cpp's ConvertFromCPP_* helpers), so a file that
// included both would see two definitions of every type. Keeping the dock
// builder and the style scaling here means the rest of the shim speaks only
// the C API and can never disagree with it.
//
// A DockBuilder layout is rebuilt in one frame, before any window is
// submitted, so building and docking are separate calls made in that order.

#include <cstdio>
#include <string>
#include <vector>

#include "imgui.h"
#include "imgui_internal.h"

#include "goose_imgui_internal.h"

namespace {
struct Layout {
    bool built = false;
    ImGuiID root = 0;
    ImGuiID center = 0;
    ImGuiID left = 0;
    ImGuiID right = 0;
    ImGuiID bottom = 0;
};
Layout g_layout;

std::string text_of(const igs_u8s &s) {
    if (!s.data || s.len <= 0) return std::string();
    return std::string(reinterpret_cast<const char *>(s.data), static_cast<size_t>(s.len));
}
} // namespace

extern "C" {

bool igs_internal_dock_build(uint32_t root, float width, float height, int64_t layout) {
    if (!root) return false;
    const ImGuiID id = static_cast<ImGuiID>(root);
    ImGui::DockBuilderRemoveNode(id);
    ImGui::DockBuilderAddNode(id, ImGuiDockNodeFlags_DockSpace);
    ImGui::DockBuilderSetNodeSize(id, ImVec2(width, height));
    g_layout = Layout{};
    g_layout.root = id;
    g_layout.center = id;
    if (layout == 0) {
        g_layout.left = ImGui::DockBuilderSplitNode(g_layout.center, ImGuiDir_Left, 0.24f, nullptr,
                                                    &g_layout.center);
        g_layout.right = ImGui::DockBuilderSplitNode(g_layout.center, ImGuiDir_Right, 0.28f,
                                                     nullptr, &g_layout.center);
        g_layout.bottom = ImGui::DockBuilderSplitNode(g_layout.center, ImGuiDir_Down, 0.30f,
                                                      nullptr, &g_layout.center);
    } else if (layout == 1) {
        // Two columns, no bottom strip: for editors.
        g_layout.left = ImGui::DockBuilderSplitNode(g_layout.center, ImGuiDir_Left, 0.30f, nullptr,
                                                    &g_layout.center);
        g_layout.right = ImGui::DockBuilderSplitNode(g_layout.center, ImGuiDir_Right, 0.32f,
                                                     nullptr, &g_layout.center);
    }
    g_layout.built = true;
    return true;
}

void igs_internal_dock_window(igs_u8s title, int64_t slot) {
    if (!g_layout.built) return;
    std::string t = text_of(title);
    if (t.empty()) return;
    ImGuiID node = g_layout.center;
    if (slot == 1)
        node = g_layout.left;
    else if (slot == 2)
        node = g_layout.right;
    else if (slot == 3)
        node = g_layout.bottom;
    if (node) ImGui::DockBuilderDockWindow(t.c_str(), node);
}

void igs_internal_dock_finish(void) {
    if (g_layout.built) ImGui::DockBuilderFinish(g_layout.root);
    g_layout = Layout{};
}

void igs_internal_style_scale_all_sizes(float scale) {
    ImGui::GetStyle().ScaleAllSizes(scale);
}

bool igs_internal_load_font(igs_u8s path, float size_px) {
    std::string p = text_of(path);
    if (p.empty()) return false;
    FILE *probe = std::fopen(p.c_str(), "rb");
    if (!probe) return false;
    std::fclose(probe);
    ImGuiIO &io = ImGui::GetIO();
    ImFontConfig cfg; // its constructor sets the non-zero defaults
    cfg.OversampleH = 2;
    cfg.OversampleV = 1;
    cfg.MergeMode = io.Fonts->Fonts.Size > 0;
    return io.Fonts->AddFontFromFileTTF(p.c_str(), size_px > 0 ? size_px : 16.0f, &cfg,
                                        io.Fonts->GetGlyphRangesDefault()) != nullptr;
}

void igs_internal_enable_viewports(bool on) {
    ImGuiIO &io = ImGui::GetIO();
    if (on)
        io.ConfigFlags |= ImGuiConfigFlags_ViewportsEnable;
    else
        io.ConfigFlags &= ~ImGuiConfigFlags_ViewportsEnable;
}

void igs_internal_render_platform_windows(void) {
    ImGuiIO &io = ImGui::GetIO();
    if (io.ConfigFlags & ImGuiConfigFlags_ViewportsEnable) {
        ImGui::UpdatePlatformWindows();
        ImGui::RenderPlatformWindowsDefault();
    }
}

int64_t igs_internal_window_stack_depth(void) {
    ImGuiContext *ctx = ImGui::GetCurrentContext();
    return ctx ? (int64_t)ctx->CurrentWindowStack.Size : 0;
}

} // extern "C"
