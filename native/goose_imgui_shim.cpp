// goose_imgui_shim.cpp — the stateful half of goose-imgui's C ABI.
//
// native/generated/igs_api.cpp carries one thin wrapper per Dear ImGui
// function (generated from the dear_bindings metadata). This file carries
// what a table of wrappers cannot: the context, window and GPU device
// lifecycle, the SDL_GPU frame, screenshots, fonts, text buffers, value
// widgets whose C parameter is `T*`, and the pieces of the C API that need
// a pointer or a buffer Goose hands in.
//
// This translation unit speaks the *C* API only (`dcimgui.h`), so it can
// never disagree with the ABI the generated wrappers expose. The few
// helpers that live in `imgui_internal.h` (the docking builder) are in
// native/goose_imgui_internal.cpp, which is the only file that includes the
// C++ headers.
//
// Every function here is `extern "C"`, prefixed `igs_`, and takes and
// returns only what Goose can pass: scalars, `{data,len}` pairs, `T&`
// (a pointer) and opaque 64-bit handles.
//
// Three ways to get a surface:
//   igs_init(title, w, h, flags)      opens an SDL3 window and an SDL_GPU
//                                     device (Metal/Vulkan/D3D12) itself
//   igs_attach(window, device)        uses an SDL_Window*/SDL_GPUDevice* the
//                                     program already owns, such as one a
//                                     goose_gfx program created for SDL_GPU
//   igs_init_offscreen(w, h)          a device and a render target, no window
//
// In every mode ImGui renders into an RGBA8 texture of its own and the
// windowed modes blit that texture to the swapchain, so a screenshot is
// the same pixels whatever the surface, and one code path is tested.

#include "dcimgui.h"
#include "dcimgui_impl_sdl3.h"
#include "dcimgui_impl_sdlgpu3.h"
#include "igs_api.h"

#include <SDL3/SDL.h>

#include <cfloat>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {

struct State {
    SDL_Window *window = nullptr;
    SDL_GPUDevice *device = nullptr;
    bool own_window = false;
    bool own_device = false;
    bool offscreen = false;
    bool imgui_ready = false;
    bool gpu_backend_ready = false;
    bool platform_backend_ready = false;
    bool frame_open = false;
    bool quit = false;
    bool claimed = false;
    int width = 0;
    int height = 0;

    SDL_GPUTexture *target = nullptr; // what ImGui renders into, RGBA8
    SDL_GPUTextureFormat target_format = SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;

    uint64_t frames = 0;
    float dpi_scale = 1.0f;
    std::string error;
    SDL_FColor clear_color = {0.06f, 0.07f, 0.09f, 1.0f};
};

State g;

// --- small helpers ---------------------------------------------------------

std::string text_of(const igs_u8s &s) {
    if (!s.data || s.len <= 0) return std::string();
    return std::string(reinterpret_cast<const char *>(s.data), static_cast<size_t>(s.len));
}

// dcimgui takes NUL terminated `const char *` and keeps nothing, so a
// borrowed copy is enough: it only has to live until the call returns. One
// call can pass several strings (a label and a hint, a path and a format), and
// their conversions may be reordered, so the copies rotate through a ring
// rather than sharing one buffer.
const char *zstr(const igs_u8s &s) {
    constexpr int slots = 8;
    static thread_local std::string bufs[slots];
    static thread_local int next = 0;
    std::string &buf = bufs[next];
    next = (next + 1) % slots;
    buf = text_of(s);
    return buf.c_str();
}

// Goose packs its structs, so a fixed array inside one is a one byte length
// followed by the elements at whatever byte offset the fields before it add up
// to: a caller's `f64` array is not necessarily 8 byte aligned. A C compiler
// may widen a loop of stores into 16 byte vector stores, which would write
// past the last element and into the bytes after it. Reading and writing
// caller memory through memcpy makes that impossible: the compiler cannot
// widen a copy whose size is the object's own.
double load_f64(const double *p) {
    double v;
    std::memcpy(&v, p, sizeof v);
    return v;
}

void store_f64(double *p, double v) {
    std::memcpy(p, &v, sizeof v);
}

bool load_bool(const bool *p) {
    bool v;
    std::memcpy(&v, p, sizeof v);
    return v;
}

void store_bool(bool *p, bool v) {
    std::memcpy(p, &v, sizeof v);
}

int64_t load_i64(const int64_t *p) {
    int64_t v;
    std::memcpy(&v, p, sizeof v);
    return v;
}

void store_i64(int64_t *p, int64_t v) {
    std::memcpy(p, &v, sizeof v);
}

void set_error(const char *what) {
    g.error = (what && *what) ? what : "unknown error";
}
void clear_error() {
    g.error.clear();
}
bool fail(const char *what) {
    set_error(what);
    return false;
}

float dpi_scale_of(SDL_Window *window) {
    if (!window) return 1.0f;
    int w = 0, h = 0, pw = 0, ph = 0;
    SDL_GetWindowSize(window, &w, &h);
    SDL_GetWindowSizeInPixels(window, &pw, &ph);
    return (w > 0) ? static_cast<float>(pw) / static_cast<float>(w) : 1.0f;
}

// --- the render target -----------------------------------------------------

bool ensure_target(int width, int height) {
    if (!g.device || width <= 0 || height <= 0) return fail("no device or zero-size target");
    if (g.target && g.width == width && g.height == height) return true;
    if (g.target) {
        SDL_ReleaseGPUTexture(g.device, g.target);
        g.target = nullptr;
    }
    SDL_GPUTextureCreateInfo info{};
    info.type = SDL_GPU_TEXTURETYPE_2D;
    info.format = g.target_format;
    info.usage = SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | SDL_GPU_TEXTUREUSAGE_SAMPLER;
    info.width = static_cast<Uint32>(width);
    info.height = static_cast<Uint32>(height);
    info.layer_count_or_depth = 1;
    info.num_levels = 1;
    info.sample_count = SDL_GPU_SAMPLECOUNT_1;
    g.target = SDL_CreateGPUTexture(g.device, &info);
    if (!g.target) return fail(SDL_GetError());
    g.width = width;
    g.height = height;
    return true;
}

void release_target() {
    if (g.target && g.device) SDL_ReleaseGPUTexture(g.device, g.target);
    g.target = nullptr;
    g.width = g.height = 0;
}

void teardown_imgui() {
    if (g.gpu_backend_ready) {
        cImGui_ImplSDLGPU3_Shutdown();
        g.gpu_backend_ready = false;
    }
    if (g.platform_backend_ready) {
        cImGui_ImplSDL3_Shutdown();
        g.platform_backend_ready = false;
    }
    if (g.imgui_ready) {
        ImGui_DestroyContext(nullptr);
        g.imgui_ready = false;
    }
}

// --- PNG writing -----------------------------------------------------------
// A minimal, deterministic PNG encoder: one IDAT, deflate "stored" blocks,
// CRC32 and Adler32. Screenshots never depend on a system image library.

uint32_t crc_table[256];
bool crc_ready = false;

void make_crc_table() {
    for (uint32_t n = 0; n < 256; n++) {
        uint32_t c = n;
        for (int k = 0; k < 8; k++)
            c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
        crc_table[n] = c;
    }
    crc_ready = true;
}

uint32_t crc32_of(const uint8_t *data, size_t len) {
    if (!crc_ready) make_crc_table();
    uint32_t c = 0xFFFFFFFFu;
    for (size_t i = 0; i < len; i++)
        c = crc_table[(c ^ data[i]) & 0xFF] ^ (c >> 8);
    return c ^ 0xFFFFFFFFu;
}

void put32(std::vector<uint8_t> &v, uint32_t x) {
    v.push_back(static_cast<uint8_t>(x >> 24));
    v.push_back(static_cast<uint8_t>(x >> 16));
    v.push_back(static_cast<uint8_t>(x >> 8));
    v.push_back(static_cast<uint8_t>(x));
}

void chunk(std::vector<uint8_t> &out, const char *type, const std::vector<uint8_t> &data) {
    put32(out, static_cast<uint32_t>(data.size()));
    std::vector<uint8_t> body;
    body.reserve(4 + data.size());
    body.insert(body.end(), type, type + 4);
    body.insert(body.end(), data.begin(), data.end());
    out.insert(out.end(), body.begin(), body.end());
    put32(out, crc32_of(body.data(), body.size()));
}

// --- deflate ---------------------------------------------------------------
// A small deflate compressor: the fixed Huffman code from RFC 1951 and a hash
// chain matcher, which is enough to make a screenshot a tenth of its raw size
// and keeps the PNG writer free of any image or compression library.

struct BitWriter {
    std::vector<uint8_t> &out;
    uint32_t bits = 0;
    int count = 0;

    explicit BitWriter(std::vector<uint8_t> &sink) : out(sink) {}

    // Deflate packs Huffman codes most significant bit first and everything
    // else least significant first, so codes are written reversed.
    void put(uint32_t value, int n) {
        bits |= (value & ((1u << n) - 1u)) << count;
        count += n;
        while (count >= 8) {
            out.push_back(static_cast<uint8_t>(bits & 0xFF));
            bits >>= 8;
            count -= 8;
        }
    }

    void put_reversed(uint32_t code, int n) {
        uint32_t reversed = 0;
        for (int i = 0; i < n; i++)
            reversed |= ((code >> i) & 1u) << (n - 1 - i);
        put(reversed, n);
    }

    void flush() {
        if (count > 0) {
            out.push_back(static_cast<uint8_t>(bits & 0xFF));
            bits = 0;
            count = 0;
        }
    }
};

// The literal/length code lengths and distance codes of RFC 1951 3.2.6.
void put_literal(BitWriter &w, int symbol) {
    if (symbol < 144)
        w.put_reversed(0x30 + symbol, 8);
    else if (symbol < 256)
        w.put_reversed(0x190 + (symbol - 144), 9);
    else if (symbol < 280)
        w.put_reversed(symbol - 256, 7);
    else
        w.put_reversed(0xC0 + (symbol - 280), 8);
}

const uint16_t length_base[29] = {3,  4,  5,  6,  7,  8,  9,  10, 11,  13,  15,  17,  19,  23, 27,
                                  31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258};
const uint8_t length_extra[29] = {0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2,
                                  2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0};
const uint16_t distance_base[30] = {1,    2,    3,    4,    5,    7,    9,    13,    17,    25,
                                    33,   49,   65,   97,   129,  193,  257,  385,   513,   769,
                                    1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577};
const uint8_t distance_extra[30] = {0, 0, 0, 0, 1, 1, 2, 2,  3,  3,  4,  4,  5,  5,  6,
                                    6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13};

void put_match(BitWriter &w, int length, int distance) {
    int li = 28;
    while (li > 0 && length_base[li] > length)
        li--;
    put_literal(w, 257 + li);
    if (length_extra[li]) w.put(static_cast<uint32_t>(length - length_base[li]), length_extra[li]);
    int di = 29;
    while (di > 0 && distance_base[di] > distance)
        di--;
    w.put_reversed(static_cast<uint32_t>(di), 5);
    if (distance_extra[di])
        w.put(static_cast<uint32_t>(distance - distance_base[di]), distance_extra[di]);
}

// The final deflate stream for `data`, single block, fixed Huffman codes.
void deflate_fixed(const std::vector<uint8_t> &data, std::vector<uint8_t> &out) {
    out.push_back(0x78);
    out.push_back(0x01); // zlib header: deflate, 32K window, no preset dictionary
    BitWriter w(out);
    w.put(1, 1); // final block
    w.put(1, 2); // fixed Huffman

    constexpr int window = 32768;
    constexpr int max_match = 258;
    constexpr int hash_bits = 15;
    constexpr int hash_size = 1 << hash_bits;
    std::vector<int32_t> head(hash_size, -1);
    std::vector<int32_t> prev(data.size() + 1, -1);
    auto hash_at = [&](size_t i) -> uint32_t {
        uint32_t h = static_cast<uint32_t>(data[i]) << 16;
        h |= static_cast<uint32_t>(data[i + 1]) << 8;
        h |= static_cast<uint32_t>(data[i + 2]);
        return (h * 2654435761u) >> (32 - hash_bits);
    };
    auto insert = [&](size_t i) {
        if (i + 2 >= data.size()) return;
        uint32_t h = hash_at(i);
        prev[i] = head[h];
        head[h] = static_cast<int32_t>(i);
    };

    size_t i = 0;
    while (i < data.size()) {
        int best_length = 0;
        int best_distance = 0;
        if (i + 2 < data.size()) {
            uint32_t h = hash_at(i);
            int32_t candidate = head[h];
            int chain = 0;
            while (candidate >= 0 && chain < 64) {
                size_t distance = i - static_cast<size_t>(candidate);
                if (distance == 0 || distance > static_cast<size_t>(window)) break;
                size_t limit = data.size() - i;
                if (limit > static_cast<size_t>(max_match)) limit = static_cast<size_t>(max_match);
                size_t length = 0;
                while (length < limit &&
                       data[static_cast<size_t>(candidate) + length] == data[i + length])
                    length++;
                if (static_cast<int>(length) > best_length) {
                    best_length = static_cast<int>(length);
                    best_distance = static_cast<int>(distance);
                    if (best_length == max_match) break;
                }
                candidate = prev[static_cast<size_t>(candidate)];
                chain++;
            }
        }
        if (best_length >= 3) {
            put_match(w, best_length, best_distance);
            for (int k = 0; k < best_length; k++)
                insert(i + static_cast<size_t>(k));
            i += static_cast<size_t>(best_length);
        } else {
            put_literal(w, data[i]);
            insert(i);
            i++;
        }
    }
    put_literal(w, 256);
    w.flush();

    uint32_t a = 1, b = 0;
    for (uint8_t byte : data) {
        a = (a + byte) % 65521;
        b = (b + a) % 65521;
    }
    put32(out, (b << 16) | a);
}

// The scanline filter that minimises the sum of absolute differences, which is
// the heuristic PNG's own reference implementation uses.
void filter_rows(const uint8_t *rgba, int width, int height, std::vector<uint8_t> &out) {
    const size_t stride = static_cast<size_t>(width) * 4;
    const size_t bpp = 4;
    std::vector<uint8_t> previous(stride, 0);
    std::vector<uint8_t> current(stride, 0);
    std::vector<uint8_t> candidates[5];
    for (int f = 0; f < 5; f++)
        candidates[f].resize(stride);
    out.reserve(static_cast<size_t>(height) * (stride + 1));
    for (int y = 0; y < height; y++) {
        std::memcpy(current.data(), rgba + static_cast<size_t>(y) * stride, stride);
        int best = 0;
        double best_score = 0.0;
        for (int f = 0; f < 5; f++) {
            double score = 0.0;
            for (size_t x = 0; x < stride; x++) {
                uint8_t left = x >= bpp ? current[x - bpp] : 0;
                uint8_t up = previous[x];
                uint8_t up_left = x >= bpp ? previous[x - bpp] : 0;
                int value = 0;
                switch (f) {
                case 0:
                    value = current[x];
                    break;
                case 1:
                    value = current[x] - left;
                    break;
                case 2:
                    value = current[x] - up;
                    break;
                case 3:
                    value = current[x] - ((left + up) / 2);
                    break;
                default: {
                    int p = static_cast<int>(left) + up - up_left;
                    int pa = std::abs(p - left);
                    int pb = std::abs(p - up);
                    int pc = std::abs(p - up_left);
                    int predictor = (pa <= pb && pa <= pc) ? left : (pb <= pc ? up : up_left);
                    value = current[x] - predictor;
                }
                }
                candidates[f][x] = static_cast<uint8_t>(value);
                score += std::abs(value < 128 ? value : value - 256);
            }
            if (f == 0 || score < best_score) {
                best = f;
                best_score = score;
            }
        }
        out.push_back(static_cast<uint8_t>(best));
        out.insert(out.end(), candidates[best].begin(), candidates[best].end());
        previous = current;
    }
}

bool write_png(const char *path, int width, int height, const uint8_t *rgba) {
    if (!path || width <= 0 || height <= 0 || !rgba) return false;
    std::vector<uint8_t> raw;
    filter_rows(rgba, width, height, raw);

    std::vector<uint8_t> z;
    z.reserve(raw.size() / 4 + 64);
    deflate_fixed(raw, z);

    std::vector<uint8_t> png = {0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A};
    std::vector<uint8_t> ihdr;
    put32(ihdr, static_cast<uint32_t>(width));
    put32(ihdr, static_cast<uint32_t>(height));
    ihdr.push_back(8); // bit depth
    ihdr.push_back(6); // RGBA
    ihdr.push_back(0); // deflate
    ihdr.push_back(0); // filter method
    ihdr.push_back(0); // no interlace
    chunk(png, "IHDR", ihdr);
    chunk(png, "IDAT", z);
    chunk(png, "IEND", {});

    FILE *f = std::fopen(path, "wb");
    if (!f) return false;
    size_t written = std::fwrite(png.data(), 1, png.size(), f);
    std::fclose(f);
    return written == png.size();
}

// --- fonts -----------------------------------------------------------------

// Dear ImGui's ImFontConfig has non-zero defaults (a rasterizer density of 1,
// ownership of the font data, an unclamped max advance). dear_bindings mirrors
// the struct as plain data, so a zeroed one would rasterize glyphs at zero
// scale and every character would come out zero pixels wide. Fill what has a
// non-zero default; everything else is zero either way.
void default_font_config(ImFontConfig &cfg) {
    std::memset(&cfg, 0, sizeof(cfg));
    cfg.FontDataOwnedByAtlas = true;
    cfg.GlyphMaxAdvanceX = FLT_MAX;
    cfg.RasterizerMultiply = 1.0f;
    cfg.RasterizerDensity = 1.0f;
    cfg.ExtraSizeScale = 1.0f;
    cfg.PixelSnapV = true;
}

const char *font_candidates[] = {
    "/System/Library/Fonts/Supplemental/Arial.ttf",
    "/System/Library/Fonts/Supplemental/Verdana.ttf",
    "/Library/Fonts/Arial.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
    "/usr/share/fonts/noto/NotoSans-Regular.ttf",
    "C:/Windows/Fonts/segoeui.ttf",
    "C:/Windows/Fonts/arial.ttf",
};

bool file_readable(const char *path) {
    if (!path || !*path) return false;
    FILE *f = std::fopen(path, "rb");
    if (!f) return false;
    std::fclose(f);
    return true;
}

// The default UI font: a system sans if there is one, else ImGui's built-in.
// IGS_FONT names a file to use instead. Returns the font file used or "".
std::string install_default_font() {
    ImGuiIO *io = ImGui_GetIO();
    if (!io || !io->Fonts) return std::string();
    // A way to force Dear ImGui's built-in bitmap font, for troubleshooting.
    if (std::getenv("IGS_FONT_BUILTIN")) {
        ImFontAtlas_AddFontDefault(io->Fonts, nullptr);
        return std::string();
    }
    const char *chosen = nullptr;
    if (const char *env = std::getenv("IGS_FONT")) {
        if (file_readable(env)) chosen = env;
    }
    for (int i = 0;
         !chosen && i < static_cast<int>(sizeof(font_candidates) / sizeof(*font_candidates)); i++)
        if (file_readable(font_candidates[i])) chosen = font_candidates[i];
    if (chosen) {
        ImFontConfig cfg;
        default_font_config(cfg);
        cfg.OversampleH = 2;
        cfg.OversampleV = 1;
        // 16px at 1x with ImGui's DPI scaling on top of that.
        if (ImFontAtlas_AddFontFromFileTTF(io->Fonts, chosen, 16.0f, &cfg,
                                           ImFontAtlas_GetGlyphRangesDefault(io->Fonts)))
            return chosen;
    }
    ImFontAtlas_AddFontDefault(io->Fonts, nullptr);
    return std::string();
}

// --- bring-up --------------------------------------------------------------

bool create_device() {
    SDL_GPUShaderFormat formats =
        SDL_GPU_SHADERFORMAT_SPIRV | SDL_GPU_SHADERFORMAT_DXIL | SDL_GPU_SHADERFORMAT_MSL;
    g.device = SDL_CreateGPUDevice(formats, /*debug_mode=*/false, nullptr);
    if (!g.device) return fail(SDL_GetError());
    g.own_device = true;
    return true;
}

void apply_style(bool dark);

bool init_imgui(bool dark) {
    if (g.imgui_ready) return true;
    ImGui_CreateContext(nullptr);
    ImGuiIO *io = ImGui_GetIO();
    if (!io) return fail("could not create an ImGui context");
    io->ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
    io->ConfigFlags |= ImGuiConfigFlags_DockingEnable;
    io->ConfigFlags |= ImGuiConfigFlags_DpiEnableScaleFonts;
    io->IniFilename = nullptr; // a package leaves no files on the user's disk
    g.imgui_ready = true;
    apply_style(dark);
    install_default_font();
    return true;
}

void apply_style(bool dark) {
    if (!g.imgui_ready) return;
    if (dark)
        ImGui_StyleColorsDark(nullptr);
    else
        ImGui_StyleColorsLight(nullptr);
    ImGuiStyle *style = ImGui_GetStyle();
    if (!style) return;
    style->WindowRounding = 6.0f;
    style->FrameRounding = 4.0f;
    style->GrabRounding = 4.0f;
    style->TabRounding = 4.0f;
    style->ScrollbarRounding = 6.0f;
    style->WindowPadding = ImVec2{10, 10};
    style->FramePadding = ImVec2{8, 4};
    style->ItemSpacing = ImVec2{8, 6};
}

bool init_backends(bool with_platform) {
    ImGui_ImplSDLGPU3_InitInfo info{};
    info.Device = g.device;
    info.ColorTargetFormat = g.target_format;
    info.MSAASamples = SDL_GPU_SAMPLECOUNT_1;
    info.SwapchainComposition = SDL_GPU_SWAPCHAINCOMPOSITION_SDR;
    info.PresentMode = SDL_GPU_PRESENTMODE_VSYNC;
    if (!cImGui_ImplSDLGPU3_Init(&info))
        return fail("the SDL_GPU3 renderer backend failed to start");
    g.gpu_backend_ready = true;
    if (with_platform && g.window) {
        if (!cImGui_ImplSDL3_InitForSDLGPU(g.window)) {
            cImGui_ImplSDLGPU3_Shutdown();
            g.gpu_backend_ready = false;
            return fail("the SDL3 platform backend failed to start");
        }
        g.platform_backend_ready = true;
    }
    return true;
}

void shutdown_all() {
    release_target();
    teardown_imgui();
    if (g.device && g.claimed && g.window) SDL_ReleaseWindowFromGPUDevice(g.device, g.window);
    if (g.device && g.own_device) SDL_DestroyGPUDevice(g.device);
    if (g.window && g.own_window) SDL_DestroyWindow(g.window);
    g.device = nullptr;
    g.window = nullptr;
    g.claimed = g.own_device = g.own_window = false;
    g.offscreen = false;
    g.frame_open = false;
    g.quit = false;
    g.width = g.height = 0;
    g.frames = 0;
    clear_error();
}

// One warm-up frame at start-up, never shown.
//
// Dear ImGui bakes font glyphs lazily, while a frame is being built, so the
// first frame a program draws would otherwise bake the atlas and create the
// GPU texture mid-flight. Measuring the printable ASCII range here means a
// program's first frame draws text from an atlas that already exists.
void warm_up(int width, int height) {
    ImGuiIO *io = ImGui_GetIO();
    if (!io) return;
    io->DisplaySize = ImVec2{static_cast<float>(width), static_cast<float>(height)};
    const ImGuiWindowFlags flags = ImGuiWindowFlags_NoDecoration |
                                   ImGuiWindowFlags_NoSavedSettings | ImGuiWindowFlags_NoInputs |
                                   ImGuiWindowFlags_NoDocking;
    if (g.platform_backend_ready) cImGui_ImplSDL3_NewFrame();
    cImGui_ImplSDLGPU3_NewFrame();
    ImGui_NewFrame();
    ImGui_Begin("##goose-imgui warm-up", nullptr, static_cast<int>(flags));
    ImGui_TextUnformattedEx(" !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ"
                            "[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~",
                            nullptr);
    ImGui_End();
    ImGui_Render();
}

} // namespace

extern "C" {

// ---------------------------------------------------------------------------
// Lifecycle. The shim owns what it created and leaves alone what it attached
// to: igs_shutdown never destroys a window or device it did not make.

bool igs_init(igs_u8s title, int64_t width, int64_t height, int64_t flags) {
    clear_error();
    if (g.imgui_ready) return fail("goose-imgui is already initialized");
    if (!SDL_Init(SDL_INIT_VIDEO)) return fail(SDL_GetError());
    std::string t = text_of(title);
    SDL_WindowFlags wf = SDL_WINDOW_RESIZABLE | SDL_WINDOW_HIGH_PIXEL_DENSITY;
    if (flags & 1) wf |= SDL_WINDOW_FULLSCREEN;
    if (flags & 2) wf |= SDL_WINDOW_HIDDEN;
    g.window = SDL_CreateWindow(t.empty() ? "goose-imgui" : t.c_str(), static_cast<int>(width),
                                static_cast<int>(height), wf);
    if (!g.window) return fail(SDL_GetError());
    g.own_window = true;
    if (!create_device()) {
        shutdown_all();
        return false;
    }
    if (!SDL_ClaimWindowForGPUDevice(g.device, g.window)) {
        shutdown_all();
        return fail(SDL_GetError());
    }
    g.claimed = true;
    g.offscreen = false;
    if (!init_imgui(true) || !init_backends(true)) {
        shutdown_all();
        return false;
    }
    int pw = 0, ph = 0;
    SDL_GetWindowSizeInPixels(g.window, &pw, &ph);
    g.dpi_scale = dpi_scale_of(g.window);
    g.width = pw;
    g.height = ph;
    if (!ensure_target(pw, ph)) {
        shutdown_all();
        return false;
    }
    warm_up(pw, ph);
    return true;
}

bool igs_attach(uint64_t window, uint64_t device) {
    clear_error();
    if (g.imgui_ready) return fail("goose-imgui is already initialized");
    g.window = reinterpret_cast<SDL_Window *>(window);
    g.device = reinterpret_cast<SDL_GPUDevice *>(device);
    if (!g.window || !g.device) return fail("igs_attach needs an SDL_Window and an SDL_GPUDevice");
    g.own_window = g.own_device = false;
    // A window another layer already claimed (goose_gfx does claim its own)
    // can still be used: ImGui only needs the size and the devices.
    g.claimed = SDL_ClaimWindowForGPUDevice(g.device, g.window);
    g.offscreen = false;
    // An attached window is someone else's, but it is also the thing the user
    // is looking at, so the platform layer (input, clipboard, DPI) comes too.
    if (!init_imgui(true) || !init_backends(true)) {
        teardown_imgui();
        if (g.claimed) SDL_ReleaseWindowFromGPUDevice(g.device, g.window);
        g.claimed = false;
        g.window = nullptr;
        g.device = nullptr;
        return false;
    }
    int pw = 0, ph = 0;
    SDL_GetWindowSizeInPixels(g.window, &pw, &ph);
    g.dpi_scale = dpi_scale_of(g.window);
    g.width = pw;
    g.height = ph;
    if (!ensure_target(pw, ph)) {
        teardown_imgui();
        g.window = nullptr;
        g.device = nullptr;
        return false;
    }
    warm_up(pw, ph);
    return true;
}

bool igs_init_offscreen(int64_t width, int64_t height) {
    clear_error();
    if (g.imgui_ready) return fail("goose-imgui is already initialized");
    SDL_Init(SDL_INIT_VIDEO); // best effort: a dummy driver is enough
    g.window = SDL_CreateWindow("goose-imgui (offscreen)", static_cast<int>(width),
                                static_cast<int>(height),
                                SDL_WINDOW_HIDDEN | SDL_WINDOW_HIGH_PIXEL_DENSITY);
    g.own_window = g.window != nullptr;
    g.offscreen = true;
    if (!create_device()) {
        shutdown_all();
        return false;
    }
    if (g.window && SDL_ClaimWindowForGPUDevice(g.device, g.window)) g.claimed = true;
    // Offscreen renders into its own texture: it wants the renderer backend
    // and nothing of the platform layer, so the drawing space is exactly the
    // target's pixels whatever display the machine happens to have.
    if (!init_imgui(true) || !init_backends(false)) {
        shutdown_all();
        return false;
    }
    g.dpi_scale = 1.0f;
    if (!ensure_target(static_cast<int>(width), static_cast<int>(height))) {
        shutdown_all();
        return false;
    }
    warm_up(static_cast<int>(width), static_cast<int>(height));
    return true;
}

void igs_shutdown() {
    shutdown_all();
}

bool igs_ready(void) {
    return g.imgui_ready && g.gpu_backend_ready;
}

uint64_t igs_sdl_window(void) {
    return reinterpret_cast<uint64_t>(g.window);
}
uint64_t igs_sdl_device(void) {
    return reinterpret_cast<uint64_t>(g.device);
}
uint64_t igs_render_target_texture(void) {
    return reinterpret_cast<uint64_t>(g.target);
}
bool igs_is_offscreen(void) {
    return g.offscreen;
}
uint64_t igs_frame_count(void) {
    return g.frames;
}
float igs_dpi_scale(void) {
    return g.dpi_scale;
}

int64_t igs_driver_into(igs_u8s out) {
    const char *driver = g.device ? SDL_GetGPUDeviceDriver(g.device) : "";
    std::string name = driver ? driver : "";
    int64_t n = static_cast<int64_t>(name.size());
    if (out.data && out.len > 0) {
        int64_t copy = n < out.len ? n : out.len;
        std::memcpy(out.data, name.data(), static_cast<size_t>(copy));
        n = copy;
    }
    return n;
}

int64_t igs_error_into(igs_u8s out) {
    int64_t n = static_cast<int64_t>(g.error.size());
    if (out.data && out.len > 0) {
        int64_t copy = n < out.len ? n : out.len;
        std::memcpy(out.data, g.error.data(), static_cast<size_t>(copy));
        n = copy;
    }
    return n;
}

int64_t igs_version_into(igs_u8s out) {
    const char *v = ImGui_GetVersion();
    int64_t n = static_cast<int64_t>(std::strlen(v));
    if (out.data && out.len > 0) {
        int64_t copy = n < out.len ? n : out.len;
        std::memcpy(out.data, v, static_cast<size_t>(copy));
        n = copy;
    }
    return n;
}

void igs_style_colors(bool dark) {
    apply_style(dark);
}

void igs_set_clear_color(float r, float gr, float b, float a) {
    g.clear_color = SDL_FColor{r, gr, b, a};
}

void igs_io_display_size(float *w, float *h, float *dt) {
    ImGuiIO *io = ImGui_GetIO();
    if (!io || !w || !h || !dt) return;
    *w = io->DisplaySize.x;
    *h = io->DisplaySize.y;
    *dt = io->DeltaTime;
}

// --- frame -----------------------------------------------------------------

// Starts a frame: events, backends' NewFrame, ImGui::NewFrame. False when
// the program should stop (the window was closed, or igs_request_quit).
bool igs_new_frame(void) {
    if (!g.imgui_ready || !g.gpu_backend_ready) return false;
    if (g.frame_open) return true;
    if (g.platform_backend_ready) {
        SDL_Event ev;
        while (SDL_PollEvent(&ev)) {
            cImGui_ImplSDL3_ProcessEvent(&ev);
            if (ev.type == SDL_EVENT_QUIT) g.quit = true;
            if (ev.type == SDL_EVENT_WINDOW_CLOSE_REQUESTED && g.window &&
                ev.window.windowID == SDL_GetWindowID(g.window))
                g.quit = true;
        }
    }
    if (g.quit) return false;
    if (g.window && !g.offscreen) {
        int pw = 0, ph = 0;
        SDL_GetWindowSizeInPixels(g.window, &pw, &ph);
        if (pw <= 0 || ph <= 0) return false; // minimized
        if (!ensure_target(pw, ph)) return false;
    }
    cImGui_ImplSDLGPU3_NewFrame();
    if (g.platform_backend_ready)
        cImGui_ImplSDL3_NewFrame();
    else {
        ImGuiIO *io = ImGui_GetIO();
        io->DisplaySize = ImVec2{static_cast<float>(g.width), static_cast<float>(g.height)};
        io->DeltaTime = 1.0f / 60.0f;
    }
    ImGui_NewFrame();
    g.frame_open = true;
    return true;
}

void igs_request_quit(void) {
    g.quit = true;
}
bool igs_should_close(void) {
    return g.quit;
}
void igs_set_clipboard(igs_u8s text) {
    ImGuiIO *io = ImGui_GetIO();
    // With no platform backend there is nowhere to put the text, so this is a
    // quiet no-op instead of a call through a null callback.
    if (!io || !io->SetClipboardTextFn) return;
    ImGui_SetClipboardText(zstr(text));
}

int64_t igs_clipboard_into(igs_u8s out) {
    ImGuiIO *io = ImGui_GetIO();
    if (!io || !io->GetClipboardTextFn) return 0;
    const char *text = ImGui_GetClipboardText();
    if (!text) return 0;
    int64_t n = static_cast<int64_t>(std::strlen(text));
    if (out.data && out.len > 0) {
        int64_t copy = n < out.len ? n : out.len;
        std::memcpy(out.data, text, static_cast<size_t>(copy));
        n = copy;
    }
    return n;
}

float igs_delta_time(void) {
    ImGuiIO *io = ImGui_GetIO();
    return io ? io->DeltaTime : 0.0f;
}
// The size windows are laid out in, which on a high density display is the
// window's size in points, not the size of the texture it renders into.
int64_t igs_display_width(void) {
    ImGuiIO *io = ImGui_GetIO();
    return io ? static_cast<int64_t>(io->DisplaySize.x) : g.width;
}

int64_t igs_display_height(void) {
    ImGuiIO *io = ImGui_GetIO();
    return io ? static_cast<int64_t>(io->DisplaySize.y) : g.height;
}

// Ends the frame: renders the draw data into the RGBA8 target and, when a
// window is shown, blits it into the swapchain and presents.
void igs_end_frame(void) {
    if (!g.frame_open) return;
    g.frame_open = false;
    ImGui_Render();
    ImDrawData *draw_data = ImGui_GetDrawData();
    if (!draw_data) return;
    SDL_GPUCommandBuffer *cmd = SDL_AcquireGPUCommandBuffer(g.device);
    if (!cmd) {
        set_error(SDL_GetError());
        return;
    }
    cImGui_ImplSDLGPU3_PrepareDrawData(draw_data, cmd);
    SDL_GPUColorTargetInfo color{};
    color.texture = g.target;
    color.load_op = SDL_GPU_LOADOP_CLEAR;
    color.store_op = SDL_GPU_STOREOP_STORE;
    color.clear_color = g.clear_color;
    SDL_GPURenderPass *pass = SDL_BeginGPURenderPass(cmd, &color, 1, nullptr);
    if (pass) {
        cImGui_ImplSDLGPU3_RenderDrawData(draw_data, cmd, pass);
        SDL_EndGPURenderPass(pass);
    } else {
        set_error(SDL_GetError());
    }
    if (!g.offscreen && g.window && g.claimed) {
        SDL_GPUTexture *swap = nullptr;
        Uint32 sw = 0, sh = 0;
        if (SDL_WaitAndAcquireGPUSwapchainTexture(cmd, g.window, &swap, &sw, &sh) && swap) {
            SDL_GPUBlitInfo blit{};
            blit.source.texture = g.target;
            blit.source.w = static_cast<Uint32>(g.width);
            blit.source.h = static_cast<Uint32>(g.height);
            blit.destination.texture = swap;
            blit.destination.w = sw;
            blit.destination.h = sh;
            blit.load_op = SDL_GPU_LOADOP_DONT_CARE;
            blit.filter = SDL_GPU_FILTER_LINEAR;
            SDL_BlitGPUTexture(cmd, &blit);
        }
    }
    if (!SDL_SubmitGPUCommandBuffer(cmd)) set_error(SDL_GetError());
    g.frames++;
}

// Reads the target back and writes it as a PNG. It waits for the GPU, so the
// file holds the frame just rendered, in every mode.
bool igs_screenshot(igs_u8s path) {
    if (!g.device || !g.target) return fail("no render target to capture");
    std::string p = text_of(path);
    if (p.empty()) return fail("igs_screenshot needs a path");
    SDL_GPUCommandBuffer *cmd = SDL_AcquireGPUCommandBuffer(g.device);
    if (!cmd) return fail(SDL_GetError());
    SDL_GPUTransferBufferCreateInfo tbi{};
    tbi.usage = SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD;
    tbi.size = static_cast<Uint32>(static_cast<size_t>(g.width) * g.height * 4);
    SDL_GPUTransferBuffer *buf = SDL_CreateGPUTransferBuffer(g.device, &tbi);
    if (!buf) {
        SDL_SubmitGPUCommandBuffer(cmd);
        return fail(SDL_GetError());
    }
    SDL_GPUTextureRegion region{};
    region.texture = g.target;
    region.w = static_cast<Uint32>(g.width);
    region.h = static_cast<Uint32>(g.height);
    region.d = 1;
    SDL_GPUTextureTransferInfo dst{};
    dst.transfer_buffer = buf;
    dst.pixels_per_row = static_cast<Uint32>(g.width);
    dst.rows_per_layer = static_cast<Uint32>(g.height);
    SDL_GPUCopyPass *copy = SDL_BeginGPUCopyPass(cmd);
    if (copy) {
        SDL_DownloadFromGPUTexture(copy, &region, &dst);
        SDL_EndGPUCopyPass(copy);
    }
    SDL_GPUFence *fence = SDL_SubmitGPUCommandBufferAndAcquireFence(cmd);
    bool ok = false;
    if (fence && SDL_WaitForGPUFences(g.device, true, &fence, 1)) {
        void *mapped = SDL_MapGPUTransferBuffer(g.device, buf, false);
        if (mapped) {
            ok = write_png(p.c_str(), g.width, g.height, static_cast<const uint8_t *>(mapped));
            SDL_UnmapGPUTransferBuffer(g.device, buf);
        }
    }
    if (fence) SDL_ReleaseGPUFence(g.device, fence);
    SDL_ReleaseGPUTransferBuffer(g.device, buf);
    if (!ok) return fail("could not write the screenshot");
    return true;
}

// --- fonts ------------------------------------------------------------------

bool igs_load_font(igs_u8s path, float size_px) {
    ImGuiIO *io = ImGui_GetIO();
    if (!io || !io->Fonts) return fail("no ImGui context");
    std::string p = text_of(path);
    if (p.empty()) return fail("igs_load_font needs a path");
    // Checked here so a typo is a clean `false` rather than an ImGui assert.
    if (!file_readable(p.c_str())) return fail("that font file cannot be read");
    ImFontConfig cfg;
    default_font_config(cfg);
    cfg.OversampleH = 2;
    cfg.MergeMode = io->Fonts->Fonts.Size > 0;
    ImFont *font =
        ImFontAtlas_AddFontFromFileTTF(io->Fonts, p.c_str(), size_px > 0 ? size_px : 16.0f, &cfg,
                                       ImFontAtlas_GetGlyphRangesDefault(io->Fonts));
    if (!font) return fail("could not load that font file");
    return true;
}

// The atlas texture's size, its ImTextureStatus and its backend handle, packed
// as (texid << 32) | (status << 16) | ... no: returned as the handle, with the
// size through out parameters.
uint64_t igs_atlas_info(int32_t *width, int32_t *height) {
    ImGuiIO *io = ImGui_GetIO();
    if (!io || !io->Fonts || !io->Fonts->TexData) {
        if (width) *width = 0;
        if (height) *height = 0;
        return 0;
    }
    ImTextureData *tex = io->Fonts->TexData;
    if (width) *width = tex->Width;
    if (height) *height = tex->Height;
    return static_cast<uint64_t>(tex->Status) << 56 | reinterpret_cast<uint64_t>(tex->TexID);
}

// Writes the font atlas texture as a PNG: what the GPU actually holds, which
// is how a font that loads but does not draw gets diagnosed.
bool igs_atlas_dump(igs_u8s path) {
    ImGuiIO *io = ImGui_GetIO();
    if (!g.device || !io || !io->Fonts || !io->Fonts->TexData) return fail("no atlas");
    ImTextureData *tex = io->Fonts->TexData;
    SDL_GPUTexture *texture = reinterpret_cast<SDL_GPUTexture *>(tex->TexID);
    if (!texture) return fail("the atlas has no GPU texture yet");
    const int w = tex->Width, h = tex->Height;
    SDL_GPUCommandBuffer *cmd = SDL_AcquireGPUCommandBuffer(g.device);
    if (!cmd) return fail(SDL_GetError());
    SDL_GPUTransferBufferCreateInfo tbi{};
    tbi.usage = SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD;
    tbi.size = static_cast<Uint32>(w * h * 4);
    SDL_GPUTransferBuffer *buf = SDL_CreateGPUTransferBuffer(g.device, &tbi);
    if (!buf) {
        SDL_SubmitGPUCommandBuffer(cmd);
        return fail(SDL_GetError());
    }
    SDL_GPUTextureRegion region{};
    region.texture = texture;
    region.w = static_cast<Uint32>(w);
    region.h = static_cast<Uint32>(h);
    region.d = 1;
    SDL_GPUTextureTransferInfo dst{};
    dst.transfer_buffer = buf;
    dst.pixels_per_row = static_cast<Uint32>(w);
    dst.rows_per_layer = static_cast<Uint32>(h);
    SDL_GPUCopyPass *copy = SDL_BeginGPUCopyPass(cmd);
    if (copy) {
        SDL_DownloadFromGPUTexture(copy, &region, &dst);
        SDL_EndGPUCopyPass(copy);
    }
    SDL_GPUFence *fence = SDL_SubmitGPUCommandBufferAndAcquireFence(cmd);
    bool ok = false;
    if (fence && SDL_WaitForGPUFences(g.device, true, &fence, 1)) {
        void *mapped = SDL_MapGPUTransferBuffer(g.device, buf, false);
        if (mapped) {
            // Shown as alpha-on-black: the atlas is white RGB with a coverage
            // alpha, which a viewer would otherwise draw as a blank white page.
            const uint8_t *px = static_cast<const uint8_t *>(mapped);
            std::vector<uint8_t> image(static_cast<size_t>(w) * h * 4, 255);
            for (size_t i = 0; i < static_cast<size_t>(w) * h; i++) {
                uint8_t alpha = px[i * 4 + 3];
                image[i * 4 + 0] = alpha;
                image[i * 4 + 1] = alpha;
                image[i * 4 + 2] = alpha;
                image[i * 4 + 3] = 255;
            }
            ok = write_png(zstr(path), w, h, image.data());
            SDL_UnmapGPUTransferBuffer(g.device, buf);
        }
    }
    if (fence) SDL_ReleaseGPUFence(g.device, fence);
    SDL_ReleaseGPUTransferBuffer(g.device, buf);
    return ok;
}

// --- text -------------------------------------------------------------------

void igs_text(igs_u8s s) {
    if (!s.data || s.len <= 0) {
        ImGui_TextUnformatted("");
        return;
    }
    const char *begin = reinterpret_cast<const char *>(s.data);
    ImGui_TextUnformattedEx(begin, begin + s.len);
}

void igs_text_colored(float r, float gr, float b, float a, igs_u8s s) {
    ImGui_PushStyleColorImVec4(ImGuiCol_Text, ImVec4{r, gr, b, a});
    igs_text(s);
    ImGui_PopStyleColor();
}

void igs_text_disabled(igs_u8s s) {
    const ImVec4 *c = ImGui_GetStyleColorVec4(ImGuiCol_TextDisabled);
    if (c) ImGui_PushStyleColorImVec4(ImGuiCol_Text, *c);
    igs_text(s);
    if (c) ImGui_PopStyleColor();
}

void igs_text_wrapped(igs_u8s s) {
    ImGui_PushTextWrapPos(0.0f);
    igs_text(s);
    ImGui_PopTextWrapPos();
}

void igs_label_text(igs_u8s label, igs_u8s value) {
    igs_text(label);
    ImGui_SameLine();
    igs_text(value);
}

void igs_bullet_text(igs_u8s s) {
    ImGui_Bullet();
    ImGui_SameLine();
    igs_text(s);
}

void igs_tooltip(igs_u8s s) {
    if (ImGui_IsItemHovered(ImGuiHoveredFlags_DelayNormal)) {
        ImGui_BeginTooltip();
        igs_text(s);
        ImGui_EndTooltip();
    }
}

void igs_separator_text(igs_u8s s) {
    ImGui_SeparatorText(zstr(s));
}

// --- text input with a caller-owned buffer ----------------------------------
// Goose passes a writable u8[:]: its data pointer and capacity. ImGui edits
// it in place, NUL-terminated inside the slice. widgets.goose hides the
// capacity bookkeeping.

bool igs_input_text(igs_u8s label, igs_u8s buf, int64_t flags) {
    if (!buf.data || buf.len <= 0) return false;
    return ImGui_InputText(zstr(label), reinterpret_cast<char *>(buf.data),
                           static_cast<size_t>(buf.len), static_cast<ImGuiInputTextFlags>(flags));
}

bool igs_input_text_with_hint(igs_u8s label, igs_u8s hint, igs_u8s buf, int64_t flags) {
    if (!buf.data || buf.len <= 0) return false;
    return ImGui_InputTextWithHint(zstr(label), zstr(hint), reinterpret_cast<char *>(buf.data),
                                   static_cast<size_t>(buf.len),
                                   static_cast<ImGuiInputTextFlags>(flags));
}

bool igs_input_text_multiline_sized(igs_u8s label, igs_u8s buf, float w, float h, int64_t flags) {
    if (!buf.data || buf.len <= 0) return false;
    return ImGui_InputTextMultilineEx(zstr(label), reinterpret_cast<char *>(buf.data),
                                      static_cast<size_t>(buf.len), ImVec2{w, h},
                                      static_cast<ImGuiInputTextFlags>(flags), nullptr, nullptr);
}

// --- value widgets whose C parameter is a pointer ---------------------------
// Goose's `T&` is a pointer, so these take the caller's variable directly.

// Goose's integer and float literals are i64 and f64, so the value widgets
// take those and convert: a caller writes `var gain = 1.0;` and gets a slider
// over it, not a type error. Multi-component widgets take a pointer to the
// first of `n` doubles, which is what `v[0]` is for a Goose array.

bool igs_checkbox(igs_u8s label, bool *v) {
    return ImGui_Checkbox(zstr(label), v);
}

bool igs_slider_f64(igs_u8s label, double *v, double lo, double hi) {
    float f = static_cast<float>(load_f64(v));
    bool changed =
        ImGui_SliderFloatEx(zstr(label), &f, static_cast<float>(lo), static_cast<float>(hi), "%.3f",
                            static_cast<ImGuiSliderFlags>(0));
    store_f64(v, f);
    return changed;
}

bool igs_slider_f64_fmt(igs_u8s label, double *v, double lo, double hi, igs_u8s fmt) {
    float f = static_cast<float>(load_f64(v));
    const char *l = zstr(label);
    const char *format = zstr(fmt);
    bool changed = ImGui_SliderFloatEx(l, &f, static_cast<float>(lo), static_cast<float>(hi),
                                       format, static_cast<ImGuiSliderFlags>(0));
    store_f64(v, f);
    return changed;
}

bool igs_slider_i64(igs_u8s label, int64_t *v, int64_t lo, int64_t hi) {
    int i = static_cast<int>(load_i64(v));
    bool changed = ImGui_SliderIntEx(zstr(label), &i, static_cast<int>(lo), static_cast<int>(hi),
                                     "%d", static_cast<ImGuiSliderFlags>(0));
    store_i64(v, i);
    return changed;
}

bool igs_slider_angle(igs_u8s label, double *v, double lo, double hi) {
    float f = static_cast<float>(load_f64(v));
    bool changed =
        ImGui_SliderAngleEx(zstr(label), &f, static_cast<float>(lo), static_cast<float>(hi),
                            "%.0f deg", static_cast<ImGuiSliderFlags>(0));
    store_f64(v, f);
    return changed;
}

bool igs_drag_f64(igs_u8s label, double *v, double speed, double lo, double hi) {
    float f = static_cast<float>(load_f64(v));
    bool changed =
        ImGui_DragFloatEx(zstr(label), &f, static_cast<float>(speed), static_cast<float>(lo),
                          static_cast<float>(hi), "%.3f", static_cast<ImGuiSliderFlags>(0));
    store_f64(v, f);
    return changed;
}

bool igs_drag_f64_speed(igs_u8s label, double *v, double speed) {
    float f = static_cast<float>(load_f64(v));
    bool changed = ImGui_DragFloatEx(zstr(label), &f, static_cast<float>(speed), 0.0f, 0.0f, "%.3f",
                                     static_cast<ImGuiSliderFlags>(0));
    store_f64(v, f);
    return changed;
}

bool igs_drag_i64(igs_u8s label, int64_t *v, double speed, int64_t lo, int64_t hi) {
    int i = static_cast<int>(load_i64(v));
    bool changed = ImGui_DragIntEx(zstr(label), &i, static_cast<float>(speed), static_cast<int>(lo),
                                   static_cast<int>(hi), "%d", static_cast<ImGuiSliderFlags>(0));
    store_i64(v, i);
    return changed;
}

bool igs_input_f64(igs_u8s label, double *v, double step, double step_fast) {
    float f = static_cast<float>(load_f64(v));
    bool changed =
        ImGui_InputFloatEx(zstr(label), &f, static_cast<float>(step), static_cast<float>(step_fast),
                           "%.3f", static_cast<ImGuiInputTextFlags>(0));
    store_f64(v, f);
    return changed;
}

bool igs_input_i64(igs_u8s label, int64_t *v, int64_t step, int64_t step_fast) {
    int i = static_cast<int>(load_i64(v));
    bool changed =
        ImGui_InputIntEx(zstr(label), &i, static_cast<int>(step), static_cast<int>(step_fast),
                         static_cast<ImGuiInputTextFlags>(0));
    store_i64(v, i);
    return changed;
}

namespace {

// The component count of a multi-component widget: n clamped to 2..4.
int components(int64_t n) {
    return static_cast<int>(n < 2 ? 2 : (n > 4 ? 4 : n));
}

// 3 or 4 components for the colour widgets: three for RGB, four for RGBA.
int colour_components(int64_t n) {
    return static_cast<int>(n <= 3 ? 3 : 4);
}

void read_f32(float *out, const double *v, int count) {
    for (int i = 0; i < count; i++)
        out[i] = static_cast<float>(load_f64(v + i));
}

void write_f64(double *v, const float *in, int count) {
    for (int i = 0; i < count; i++)
        store_f64(v + i, in[i]);
}

} // namespace

// n is 2, 3 or 4 components, from the pointer to the first.
bool igs_slider_f64_n(igs_u8s label, double *v, int64_t n, double lo, double hi) {
    float f[4] = {0, 0, 0, 0};
    int count = components(n);
    read_f32(f, v, count);
    const char *l = zstr(label);
    bool changed = false;
    switch (count) {
    case 2:
        changed = ImGui_SliderFloat2Ex(l, f, static_cast<float>(lo), static_cast<float>(hi), "%.3f",
                                       static_cast<ImGuiSliderFlags>(0));
        break;
    case 3:
        changed = ImGui_SliderFloat3Ex(l, f, static_cast<float>(lo), static_cast<float>(hi), "%.3f",
                                       static_cast<ImGuiSliderFlags>(0));
        break;
    default:
        changed = ImGui_SliderFloat4Ex(l, f, static_cast<float>(lo), static_cast<float>(hi), "%.3f",
                                       static_cast<ImGuiSliderFlags>(0));
        break;
    }
    write_f64(v, f, count);
    return changed;
}

bool igs_drag_f64_n(igs_u8s label, double *v, int64_t n, double speed, double lo, double hi) {
    float f[4] = {0, 0, 0, 0};
    int count = components(n);
    read_f32(f, v, count);
    const char *l = zstr(label);
    bool changed = false;
    switch (count) {
    case 2:
        changed =
            ImGui_DragFloat2Ex(l, f, static_cast<float>(speed), static_cast<float>(lo),
                               static_cast<float>(hi), "%.3f", static_cast<ImGuiSliderFlags>(0));
        break;
    case 3:
        changed =
            ImGui_DragFloat3Ex(l, f, static_cast<float>(speed), static_cast<float>(lo),
                               static_cast<float>(hi), "%.3f", static_cast<ImGuiSliderFlags>(0));
        break;
    default:
        changed =
            ImGui_DragFloat4Ex(l, f, static_cast<float>(speed), static_cast<float>(lo),
                               static_cast<float>(hi), "%.3f", static_cast<ImGuiSliderFlags>(0));
        break;
    }
    write_f64(v, f, count);
    return changed;
}

bool igs_input_f64_n(igs_u8s label, double *v, int64_t n) {
    float f[4] = {0, 0, 0, 0};
    int count = components(n);
    read_f32(f, v, count);
    const char *l = zstr(label);
    bool changed = false;
    if (count == 2)
        changed = ImGui_InputFloat2(l, f);
    else if (count == 3)
        changed = ImGui_InputFloat3(l, f);
    else
        changed = ImGui_InputFloat4(l, f);
    write_f64(v, f, count);
    return changed;
}

bool igs_color_edit(igs_u8s label, double *v, int64_t n) {
    float f[4] = {0, 0, 0, 1};
    int count = colour_components(n);
    read_f32(f, v, count);
    const char *l = zstr(label);
    bool changed = (count == 3) ? ImGui_ColorEdit3(l, f, static_cast<ImGuiColorEditFlags>(0))
                                : ImGui_ColorEdit4(l, f, static_cast<ImGuiColorEditFlags>(0));
    write_f64(v, f, count);
    return changed;
}

bool igs_color_picker(igs_u8s label, double *v, int64_t n) {
    float f[4] = {0, 0, 0, 1};
    int count = colour_components(n);
    read_f32(f, v, count);
    const char *l = zstr(label);
    bool changed = (count == 3)
                       ? ImGui_ColorPicker3(l, f, static_cast<ImGuiColorEditFlags>(0))
                       : ImGui_ColorPicker4(l, f, static_cast<ImGuiColorEditFlags>(0), nullptr);
    write_f64(v, f, count);
    return changed;
}

bool igs_color_button(igs_u8s desc, double *v) {
    return ImGui_ColorButtonEx(zstr(desc),
                               ImVec4{static_cast<float>(load_f64(v)),
                                      static_cast<float>(load_f64(v + 1)),
                                      static_cast<float>(load_f64(v + 2)), 1.0f},
                               static_cast<ImGuiColorEditFlags>(0), ImVec2{0, 0});
}

bool igs_combo(igs_u8s label, int64_t *current, igs_u8s items) {
    if (!current) return false;
    int i = static_cast<int>(load_i64(current));
    // items is "one\0two\0three\0": ImGui wants a list that ends in two NULs,
    // and the string zstr() builds supplies the second one.
    const char *l = zstr(label);
    const char *list = zstr(items);
    bool changed = ImGui_Combo(l, &i, list);
    store_i64(current, i);
    return changed;
}

bool igs_radio_i64(igs_u8s label, int64_t *v, int64_t button) {
    if (!v) return false;
    int i = static_cast<int>(load_i64(v));
    bool changed = ImGui_RadioButtonIntPtr(zstr(label), &i, static_cast<int>(button));
    store_i64(v, i);
    return changed;
}

bool igs_menu_item_toggle(igs_u8s label, bool *selected) {
    if (!selected) return false;
    bool v = load_bool(selected);
    bool changed = ImGui_MenuItemBoolPtr(zstr(label), nullptr, &v, true);
    store_bool(selected, v);
    return changed;
}

void igs_progress_bar(double fraction, float w, float h, igs_u8s overlay) {
    ImGui_ProgressBar(static_cast<float>(fraction), ImVec2{w, h}, zstr(overlay));
}

// --- textures and images ----------------------------------------------------

bool igs_texture_update(uint64_t tex, int64_t w, int64_t h, igs_u8s rgba) {
    if (!g.device || !tex || !rgba.data || rgba.len < w * h * 4 || w <= 0 || h <= 0) return false;
    SDL_GPUTexture *texture = reinterpret_cast<SDL_GPUTexture *>(tex);
    SDL_GPUCommandBuffer *cmd = SDL_AcquireGPUCommandBuffer(g.device);
    if (!cmd) return fail(SDL_GetError());
    SDL_GPUTransferBufferCreateInfo tbi{};
    tbi.usage = SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
    tbi.size = static_cast<Uint32>(w * h * 4);
    SDL_GPUTransferBuffer *buf = SDL_CreateGPUTransferBuffer(g.device, &tbi);
    if (!buf) {
        SDL_SubmitGPUCommandBuffer(cmd);
        return fail(SDL_GetError());
    }
    void *mapped = SDL_MapGPUTransferBuffer(g.device, buf, false);
    if (mapped) std::memcpy(mapped, rgba.data, static_cast<size_t>(w * h * 4));
    SDL_UnmapGPUTransferBuffer(g.device, buf);
    SDL_GPUTextureTransferInfo src{};
    src.transfer_buffer = buf;
    src.pixels_per_row = static_cast<Uint32>(w);
    src.rows_per_layer = static_cast<Uint32>(h);
    SDL_GPUTextureRegion dst{};
    dst.texture = texture;
    dst.w = static_cast<Uint32>(w);
    dst.h = static_cast<Uint32>(h);
    dst.d = 1;
    SDL_GPUCopyPass *copy = SDL_BeginGPUCopyPass(cmd);
    if (copy) {
        SDL_UploadToGPUTexture(copy, &src, &dst, false);
        SDL_EndGPUCopyPass(copy);
    }
    SDL_SubmitGPUCommandBuffer(cmd);
    SDL_ReleaseGPUTransferBuffer(g.device, buf);
    return true;
}

uint64_t igs_texture_create(int64_t w, int64_t h, igs_u8s rgba) {
    if (!g.device || w <= 0 || h <= 0) {
        set_error("no device, or a zero-size texture");
        return 0;
    }
    SDL_GPUTextureCreateInfo info{};
    info.type = SDL_GPU_TEXTURETYPE_2D;
    info.format = SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;
    info.usage = SDL_GPU_TEXTUREUSAGE_SAMPLER;
    info.width = static_cast<Uint32>(w);
    info.height = static_cast<Uint32>(h);
    info.layer_count_or_depth = 1;
    info.num_levels = 1;
    SDL_GPUTexture *tex = SDL_CreateGPUTexture(g.device, &info);
    if (!tex) {
        set_error(SDL_GetError());
        return 0;
    }
    uint64_t handle = reinterpret_cast<uint64_t>(tex);
    if (rgba.data && rgba.len >= w * h * 4 && !igs_texture_update(handle, w, h, rgba)) {
        SDL_ReleaseGPUTexture(g.device, tex);
        return 0;
    }
    return handle;
}

void igs_texture_release(uint64_t tex) {
    if (g.device && tex) SDL_ReleaseGPUTexture(g.device, reinterpret_cast<SDL_GPUTexture *>(tex));
}

void igs_image(uint64_t tex, float w, float h) {
    ImGui_Image(ImTextureRef{nullptr, static_cast<ImTextureID>(tex)}, ImVec2{w, h});
}

void igs_image_ex(uint64_t tex, float w, float h, float u0, float v0, float u1, float v1) {
    ImGui_ImageEx(ImTextureRef{nullptr, static_cast<ImTextureID>(tex)}, ImVec2{w, h},
                  ImVec2{u0, v0}, ImVec2{u1, v1});
}

bool igs_image_button(igs_u8s id, uint64_t tex, float w, float h) {
    return ImGui_ImageButton(zstr(id), ImTextureRef{nullptr, static_cast<ImTextureID>(tex)},
                             ImVec2{w, h});
}

// --- IO and style scalars ---------------------------------------------------

float igs_io_fps(void) {
    ImGuiIO *io = ImGui_GetIO();
    return io ? io->Framerate : 0.0f;
}
void igs_io_set_fps(float fps) {
    if (ImGuiIO *io = ImGui_GetIO()) io->Framerate = fps;
}
void igs_io_get_mouse_pos(float *x, float *y) {
    ImGuiIO *io = ImGui_GetIO();
    if (!io || !x || !y) return;
    *x = io->MousePos.x;
    *y = io->MousePos.y;
}
void igs_io_mouse_delta(float *x, float *y) {
    ImGuiIO *io = ImGui_GetIO();
    if (!io || !x || !y) return;
    *x = io->MouseDelta.x;
    *y = io->MouseDelta.y;
}

void igs_io_mouse_wheel(float *x, float *y) {
    ImGuiIO *io = ImGui_GetIO();
    if (!io || !x || !y) return;
    *x = io->MouseWheel;
    *y = io->MouseWheelH;
}

bool igs_mouse_down(int64_t button) {
    return ImGui_IsMouseDown(static_cast<int>(button));
}

bool igs_mouse_clicked(int64_t button) {
    return ImGui_IsMouseClicked(static_cast<int>(button));
}

bool igs_mouse_released(int64_t button) {
    return ImGui_IsMouseReleased(static_cast<int>(button));
}

bool igs_mouse_dragging(int64_t button, double threshold) {
    return ImGui_IsMouseDragging(static_cast<int>(button), static_cast<float>(threshold));
}

bool igs_io_want_mouse(void) {
    ImGuiIO *io = ImGui_GetIO();
    return io && io->WantCaptureMouse;
}

bool igs_io_want_keyboard(void) {
    ImGuiIO *io = ImGui_GetIO();
    return io && io->WantCaptureKeyboard;
}

void igs_io_set_mouse_pos(float x, float y) {
    if (ImGuiIO *io = ImGui_GetIO()) ImGuiIO_AddMousePosEvent(io, x, y);
}
int64_t igs_io_metrics_render_vertices(void) {
    ImGuiIO *io = ImGui_GetIO();
    return io ? static_cast<int64_t>(io->MetricsRenderVertices) : 0;
}
int64_t igs_io_metrics_render_indices(void) {
    ImGuiIO *io = ImGui_GetIO();
    return io ? static_cast<int64_t>(io->MetricsRenderIndices) : 0;
}
int64_t igs_io_metrics_active_windows(void) {
    ImGuiIO *io = ImGui_GetIO();
    return io ? static_cast<int64_t>(io->MetricsActiveWindows) : 0;
}

void igs_style_set_window_rounding(float v) {
    if (ImGuiStyle *s = ImGui_GetStyle()) s->WindowRounding = v;
}
void igs_style_set_frame_rounding(float v) {
    if (ImGuiStyle *s = ImGui_GetStyle()) s->FrameRounding = v;
}
void igs_style_set_window_padding(float x, float y) {
    if (ImGuiStyle *s = ImGui_GetStyle()) s->WindowPadding = ImVec2{x, y};
}
void igs_style_set_frame_padding(float x, float y) {
    if (ImGuiStyle *s = ImGui_GetStyle()) s->FramePadding = ImVec2{x, y};
}
void igs_style_set_item_spacing(float x, float y) {
    if (ImGuiStyle *s = ImGui_GetStyle()) s->ItemSpacing = ImVec2{x, y};
}
void igs_style_set_scrollbar_size(float v) {
    if (ImGuiStyle *s = ImGui_GetStyle()) s->ScrollbarSize = v;
}

// --- docking ---------------------------------------------------------------
// The DockBuilder layout itself is in goose_imgui_internal.cpp, since it needs
// imgui_internal.h; these three are plain C API.

uint32_t igs_dockspace_over_viewport(float top, float bottom, int64_t flags) {
    (void)top;
    (void)bottom;
    return static_cast<uint32_t>(
        ImGui_DockSpaceOverViewportEx(0, nullptr, static_cast<ImGuiDockNodeFlags>(flags), nullptr));
}

uint32_t igs_dockspace_id(igs_u8s name) {
    return static_cast<uint32_t>(ImGui_GetID(zstr(name)));
}

uint32_t igs_dockspace(uint32_t id, float x, float y, float w, float h, int64_t flags) {
    (void)x;
    (void)y;
    return static_cast<uint32_t>(ImGui_DockSpaceEx(
        static_cast<ImGuiID>(id), ImVec2{w, h}, static_cast<ImGuiDockNodeFlags>(flags), nullptr));
}

// --- drawing helpers the raw layer cannot express ---------------------------
// A draw list is a `u64` everywhere else; these take the primitives Goose
// has (floats, a colour, a slice of text) so node graphs and canvases need no
// vectors at all.

void igs_draw_list_add_text(uint64_t list, float x, float y, uint32_t col, igs_u8s text) {
    ImDrawList *dl = reinterpret_cast<ImDrawList *>(list);
    if (dl) ImDrawList_AddText(dl, ImVec2{x, y}, static_cast<ImU32>(col), zstr(text));
}

void igs_draw_list_add_text_sized(uint64_t list, float x, float y, float size, uint32_t col,
                                  igs_u8s text) {
    ImDrawList *dl = reinterpret_cast<ImDrawList *>(list);
    ImFont *font = ImGui_GetFont();
    if (dl && font && size > 0.0f)
        ImDrawList_AddTextImFontPtr(dl, font, size, ImVec2{x, y}, static_cast<ImU32>(col),
                                    zstr(text));
}

void igs_draw_list_add_rect_filled(uint64_t list, float x0, float y0, float x1, float y1,
                                   uint32_t col, float rounding) {
    ImDrawList *dl = reinterpret_cast<ImDrawList *>(list);
    if (dl)
        ImDrawList_AddRectFilledEx(dl, ImVec2{x0, y0}, ImVec2{x1, y1}, static_cast<ImU32>(col),
                                   rounding, static_cast<ImDrawFlags>(0));
}

void igs_draw_list_add_rect(uint64_t list, float x0, float y0, float x1, float y1, uint32_t col,
                            float rounding, float thickness) {
    ImDrawList *dl = reinterpret_cast<ImDrawList *>(list);
    if (dl)
        // 1.92.8 put thickness before flags: rounding, thickness, flags.
        ImDrawList_AddRectEx(dl, ImVec2{x0, y0}, ImVec2{x1, y1}, static_cast<ImU32>(col), rounding,
                             thickness, static_cast<ImDrawFlags>(0));
}

void igs_draw_list_add_circle_filled(uint64_t list, float cx, float cy, float r, uint32_t col) {
    ImDrawList *dl = reinterpret_cast<ImDrawList *>(list);
    if (dl) ImDrawList_AddCircleFilled(dl, ImVec2{cx, cy}, r, static_cast<ImU32>(col), 0);
}

void igs_draw_list_add_circle(uint64_t list, float cx, float cy, float r, uint32_t col,
                              float thickness) {
    ImDrawList *dl = reinterpret_cast<ImDrawList *>(list);
    if (dl)
        ImDrawList_AddCircleEx(dl, ImVec2{cx, cy}, r, static_cast<ImU32>(col), 0, thickness,
                               static_cast<ImDrawFlags>(0));
}

void igs_draw_list_add_line(uint64_t list, float x0, float y0, float x1, float y1, uint32_t col,
                            float thickness) {
    ImDrawList *dl = reinterpret_cast<ImDrawList *>(list);
    if (dl)
        ImDrawList_AddLineEx(dl, ImVec2{x0, y0}, ImVec2{x1, y1}, static_cast<ImU32>(col), thickness,
                             static_cast<ImDrawFlags>(0));
}

void igs_draw_list_add_bezier_cubic(uint64_t list, float x0, float y0, float x1, float y1, float x2,
                                    float y2, float x3, float y3, uint32_t col, float thickness) {
    ImDrawList *dl = reinterpret_cast<ImDrawList *>(list);
    if (dl)
        ImDrawList_AddBezierCubic(dl, ImVec2{x0, y0}, ImVec2{x1, y1}, ImVec2{x2, y2},
                                  ImVec2{x3, y3}, static_cast<ImU32>(col), thickness, 0,
                                  static_cast<ImDrawFlags>(0));
}

void igs_draw_list_add_triangle_filled(uint64_t list, float x0, float y0, float x1, float y1,
                                       float x2, float y2, uint32_t col) {
    ImDrawList *dl = reinterpret_cast<ImDrawList *>(list);
    if (dl)
        ImDrawList_AddTriangleFilled(dl, ImVec2{x0, y0}, ImVec2{x1, y1}, ImVec2{x2, y2},
                                     static_cast<ImU32>(col));
}

// --- plots ------------------------------------------------------------------

void igs_plot_lines(igs_u8s label, igs_f32s values) {
    ImGui_PlotLinesEx(zstr(label), values.data, static_cast<int>(values.len), 0, nullptr, FLT_MAX,
                      FLT_MAX, ImVec2{0, 0}, sizeof(float));
}

void igs_plot_lines_scaled(igs_u8s label, igs_f32s values, float lo, float hi, float w, float h) {
    ImGui_PlotLinesEx(zstr(label), values.data, static_cast<int>(values.len), 0, nullptr, lo, hi,
                      ImVec2{w, h}, sizeof(float));
}

void igs_plot_histogram(igs_u8s label, igs_f32s values, float lo, float hi, float w, float h) {
    ImGui_PlotHistogramEx(zstr(label), values.data, static_cast<int>(values.len), 0, nullptr, lo,
                          hi, ImVec2{w, h}, sizeof(float));
}

// --- misc helpers -----------------------------------------------------------

void igs_set_next_window_pos_pivot(float x, float y, int64_t cond, float px, float py) {
    ImGui_SetNextWindowPosEx(ImVec2{x, y}, static_cast<ImGuiCond>(cond), ImVec2{px, py});
}

bool igs_begin_open(igs_u8s name, bool *p_open, int64_t flags) {
    return ImGui_Begin(zstr(name), p_open, static_cast<ImGuiWindowFlags>(flags));
}

// Windows that remember nothing on disk: a settings slot in the shim.
uint64_t igs_open_cell_new(bool initial) {
    bool *cell = static_cast<bool *>(std::malloc(sizeof(bool)));
    if (cell) *cell = initial;
    return reinterpret_cast<uint64_t>(cell);
}
bool igs_open_cell_get(uint64_t cell) {
    return cell ? *reinterpret_cast<bool *>(cell) : false;
}
void igs_open_cell_set(uint64_t cell, bool value) {
    if (cell) *reinterpret_cast<bool *>(cell) = value;
}
void igs_open_cell_free(uint64_t cell) {
    std::free(reinterpret_cast<bool *>(cell));
}

} // extern "C"
