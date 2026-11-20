#!/usr/bin/env python3
"""Generate goose-imgui's raw Goose bindings and their C ABI glue.

Reads the JSON metadata that `dear_bindings` emits beside `dcimgui.h`
(`native/cimgui/metadata/dcimgui.json`) and writes two files that must
always agree:

  raw.goose                        extern fn declarations + enum constants
  native/generated/igs_api.cpp/.h  thin extern "C" wrappers, one per extern fn

Why a generated C++ layer exists at all: Dear ImGui's C API takes
`const char*` for every label and `ImVec2`/`ImVec4` by value. Goose has no
NUL-terminated string type and its structs are packed, so the generated
wrappers take `igs_u8s { uint8_t* data; int64_t len; }` (Goose's `const
u8[:]`) and two/four floats, and build the C++ values inside the wrapper.
The wrappers pass nothing but scalars and {data,len} pairs across the ABI,
which keeps the Goose side free of layout assumptions.

The mapping is deliberately conservative: anything this script cannot
describe exactly with scalars, slices and opaque 64-bit handles is skipped
(the handwritten shim in native/goose_imgui_shim.cpp covers those), and
`--check` fails when the checked-in output differs from what the metadata
says it should be.

Usage:
  python3 scripts/generate_bindings.py            # regenerate
  python3 scripts/generate_bindings.py --check     # verify (CI)
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
METADATA = ROOT / "native" / "cimgui" / "metadata" / "dcimgui.json"
RAW_GOOSE = ROOT / "raw.goose"
GLUE_CPP = ROOT / "native" / "generated" / "igs_api.cpp"
GLUE_H = ROOT / "native" / "generated" / "igs_api.h"

# The hand-written half of the ABI: one `// goose: <declaration>` line above
# each C prototype is the Goose signature that goes into raw.goose.
HANDWRITTEN_HEADERS = [
    ROOT / "native" / "goose_imgui_shim.h",
    ROOT / "native" / "goose_imgui_internal.h",
]

# Goose has no NUL-terminated strings; these are the {data,len} pairs it passes.
BYTES_C = "igs_u8s"
FLOATS_C = "igs_f32s"
BYTES_GOOSE = "const u8[:]"
FLOATS_GOOSE = "const f32[:]"

SCALARS = {
    "float": ("f32", "float"),
    "int": ("i32", "int32_t"),
    "unsigned_int": ("u32", "uint32_t"),
    "double": ("f64", "double"),
    "unsigned_short": ("u16", "uint16_t"),
    "unsigned_char": ("u8", "uint8_t"),
    "signed_char": ("i8", "int8_t"),
    "char": ("i8", "int8_t"),
    "bool": ("bool", "bool"),
    "size_t": ("u64", "size_t"),
    "intptr_t": ("i64", "intptr_t"),
    "uintptr_t": ("u64", "uintptr_t"),
    "long": ("i64", "int64_t"),
    "unsigned_long": ("u64", "uint64_t"),
}

# Goose keywords and names that would shadow something the generated module
# itself declares. A parameter named after one of these gets a trailing "_".
RESERVED = {
    "as", "assert", "break", "const", "continue", "default", "defer", "else",
    "enum", "export", "extern", "false", "fn", "for", "from", "guard", "if",
    "import", "in", "let", "loop", "map", "match", "namespace", "return",
    "self", "struct", "true", "type", "use", "var", "while", "yield", "raw",
    "igs", "out",
}

# Functions that need an adapter this generator does not emit: variadic text
# formatting, callbacks, or buffers that only the handwritten shim can own.
# They are still declared by the shim under their own name; see
# native/goose_imgui_shim.cpp.
SKIP = {
    # Variadic or format-string entry points: the shim's text helpers cover them.
    "ImGui_Text", "ImGui_TextColored", "ImGui_TextDisabled", "ImGui_TextWrapped",
    "ImGui_TextV", "ImGui_TextColoredV", "ImGui_TextDisabledV", "ImGui_TextWrappedV",
    "ImGui_BulletText", "ImGui_LabelText", "ImGui_SetTooltip", "ImGui_LogText",
    "ImGui_TreeNodeExV", "ImGui_TreeNodeV", "ImGui_TreeNodeExV", "ImGui_TextFormatted",
    # Typed input/output that owns a char buffer; the shim's igs_input_text does.
    "ImGui_InputText", "ImGui_InputTextMultiline", "ImGui_InputTextWithHint",
    "ImGui_DebugTextEncoding",
    # A direct ImTextureRef by value (a struct with a pointer to ImTextureData).
    "ImGui_Image", "ImGui_ImageWithBg", "ImGui_ImageButton", "ImGui_ImageButtonEx",
    # Font atlas building from files or memory: fonts are loaded by the shim.
    "ImFontAtlas_AddFontFromFileTTF", "ImFontAtlas_AddFontFromMemoryTTF",
    "ImFontAtlas_AddFontDefault", "ImFontAtlas_AddFont",
    "ImFontAtlas_GetGlyphRangesDefault", "ImFontAtlas_GetGlyphRangesGreek",
    "ImFontAtlas_GetGlyphRangesKorean", "ImFontAtlas_GetGlyphRangesJapanese",
    "ImFontAtlas_GetGlyphRangesChineseFull", "ImFontAtlas_GetGlyphRangesChineseSimplifiedCommon",
    "ImFontAtlas_GetGlyphRangesCyrillic", "ImFontAtlas_GetGlyphRangesThai",
    "ImFontAtlas_GetGlyphRangesVietnamese",
    # Value widgets whose C parameter is a `T*`: their mapping to an opaque
    # u64 address is useless (and unsafe) from Goose, so the shim's f64/i64
    # versions, which take Goose's `T&`, are the only ones declared.
    "ImGui_Checkbox", "ImGui_RadioButton", "ImGui_ProgressBar",
    "ImGui_SliderFloat", "ImGui_SliderFloatEx", "ImGui_SliderFloat2",
    "ImGui_SliderFloat2Ex", "ImGui_SliderFloat3", "ImGui_SliderFloat3Ex",
    "ImGui_SliderFloat4", "ImGui_SliderFloat4Ex", "ImGui_SliderInt",
    "ImGui_SliderIntEx", "ImGui_SliderInt2", "ImGui_SliderInt2Ex",
    "ImGui_SliderInt3", "ImGui_SliderInt3Ex", "ImGui_SliderInt4",
    "ImGui_SliderInt4Ex", "ImGui_SliderAngle", "ImGui_SliderAngleEx",
    "ImGui_DragFloat", "ImGui_DragFloatEx", "ImGui_DragFloat2", "ImGui_DragFloat2Ex",
    "ImGui_DragFloat3", "ImGui_DragFloat3Ex", "ImGui_DragFloat4", "ImGui_DragFloat4Ex",
    "ImGui_DragInt", "ImGui_DragIntEx", "ImGui_DragInt2", "ImGui_DragInt2Ex",
    "ImGui_DragInt3", "ImGui_DragInt3Ex", "ImGui_DragInt4", "ImGui_DragInt4Ex",
    "ImGui_InputFloat", "ImGui_InputFloatEx", "ImGui_InputFloat2", "ImGui_InputFloat2Ex",
    "ImGui_InputFloat3", "ImGui_InputFloat3Ex", "ImGui_InputFloat4", "ImGui_InputFloat4Ex",
    "ImGui_InputInt", "ImGui_InputIntEx", "ImGui_InputInt2", "ImGui_InputInt2Ex",
    "ImGui_InputInt3", "ImGui_InputInt3Ex", "ImGui_InputInt4", "ImGui_InputInt4Ex",
    "ImGui_ColorEdit3", "ImGui_ColorEdit4", "ImGui_ColorPicker3", "ImGui_ColorPicker4",
    "ImGui_ColorButton", "ImGui_ColorButtonEx",
    # The frame ImGui itself renders: the shim's begin/end frame owns the GPU.
    "ImGui_NewFrame", "ImGui_EndFrame", "ImGui_Render",
    # Draw-list primitives the shim wraps with scalars and text slices.
    "ImDrawList_AddLine", "ImDrawList_AddLineEx", "ImDrawList_AddRect",
    "ImDrawList_AddRectEx", "ImDrawList_AddRectFilled", "ImDrawList_AddRectFilledEx",
    "ImDrawList_AddCircle", "ImDrawList_AddCircleEx", "ImDrawList_AddCircleFilled",
    "ImDrawList_AddCircleFilledEx", "ImDrawList_AddBezierCubic", "ImDrawList_AddText",
    "ImDrawList_AddTextEx", "ImDrawList_AddTriangleFilled",
    # Clipboard/callback hooks and anything else the programmer wires in C.
    "ImGui_GetClipboardTextFn_", "ImGui_GetClipboardText", "ImGui_SetClipboardText",
}

# Handy aliases: the C API's own spelling is kept for grep-ability, but a few
# entry points read better under a stable name of our choosing.
RENAME = {}


@dataclass
class Param:
    name: str
    goose: str
    c: str
    is_bytes: bool = False
    is_floats: bool = False


@dataclass
class Function:
    cname: str
    goose_name: str
    ret_goose: str          # "" for void, or a scalar type
    ret_c: str
    params: list[Param] = field(default_factory=list)
    out_vec: int = 0        # 2 or 4: returns an ImVec2/ImVec4 through out params
    expr: str = ""          # how the wrapper calls the C API

    @property
    def symbol(self) -> str:
        return self.goose_name


def camel_to_snake(name: str) -> str:
    s = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1_\2", name)
    s = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", s)
    s = s.replace("__", "_")
    return s.strip("_").lower()


def goose_ident(raw: str, fallback: str) -> str:
    name = camel_to_snake(raw) if raw else fallback
    if not name or not re.match(r"^[a-z_]", name):
        name = fallback if not name else "a_" + name
    if name in RESERVED:
        name += "_"
    return name


def goose_function_name(cname: str) -> str:
    if cname in RENAME:
        return RENAME[cname]
    cls, _, method = cname.partition("_")
    parts = camel_to_snake(method).split("_") if method else camel_to_snake(cls).split("_")
    if not method:  # A plain C function (no class prefix): keep its whole name.
        return "igs_" + camel_to_snake(cls)
    if cls == "ImGui":
        prefix = ""
    elif cls in ("ImGuiIO", "ImGuiStyle", "ImGuiPlatformIO"):
        prefix = camel_to_snake(cls[5:]) + "_"
    elif cls == "ImDrawList":
        prefix = "draw_list_"
    elif cls.startswith("ImGui"):
        prefix = camel_to_snake(cls[5:]) + "_"
    elif cls.startswith("ImDraw"):
        prefix = camel_to_snake(cls[4:]) + "_"
    elif cls.startswith("ImFontAtlas"):
        prefix = "font_atlas_" + camel_to_snake(cls[len("ImFontAtlas"):]).strip("_")
        prefix = prefix.rstrip("_") + "_"
    elif cls.startswith("ImFont"):
        prefix = "font_" + camel_to_snake(cls[len("ImFont"):]).strip("_")
        prefix = prefix.rstrip("_") + "_"
    else:
        prefix = camel_to_snake(cls) + "_"
    return "igs_" + prefix + "_".join(p for p in parts if p)


class Generator:
    def __init__(self, meta: dict):
        self.meta = meta
        self.typedefs = {t["name"]: t.get("type", {}) for t in meta.get("typedefs", [])}
        self.enums = {e["name"]: e for e in meta.get("enums", [])}
        self.structs = {s["name"]: s for s in meta.get("structs", [])}
        self.skipped: list[tuple[str, str]] = []

    # --- type classification -------------------------------------------------
    def classify(self, desc: dict) -> tuple[str, object]:
        """('scalar', (goose, c)) | ('enum', None) | ('vec2'|'vec4', None)
        | ('struct', name) | ('bytes', None) | ('floats', None)
        | ('ptr', None) | ('void', None) | ('unsupported', reason)"""
        kind = desc.get("kind")
        if kind == "Builtin":
            b = desc.get("builtin_type")
            if b == "void":
                return "void", None
            if b in SCALARS:
                return "scalar", SCALARS[b]
            return "unsupported", f"builtin {b}"
        if kind == "User":
            name = desc.get("name", "")
            return self.classify_user(name)
        if kind == "Pointer":
            inner = desc.get("inner_type") or {}
            storage = inner.get("storage_classes") or []
            ikind, ival = self.classify(inner)
            if ikind == "void":
                return "ptr", "void*"
            if ikind == "scalar" and inner.get("kind") == "Builtin" and \
                    inner.get("builtin_type") == "char":
                # `const char*` is text; a writable `char*` is a buffer we do
                # not hand to Goose (the shim's text-input helpers do).
                return ("bytes", None) if "const" in storage else (
                    "unsupported", "writable char*")
            if ikind == "struct":
                return "ptr", inner.get("name", "void") + "*"
            if ikind == "scalar":
                # A pointer to a scalar (bool* p_open, int* out_count, ...) is
                # handed to Goose as an opaque 64-bit address. The pointer+count
                # merge above and the shim's cell helpers are how one is made.
                ctype = (inner.get("name", "int") if inner.get("kind") == "User"
                         else ival[1])
                return "scalarptr", ctype + "*"
            return "unsupported", f"pointer to {ikind}"
        return "unsupported", f"type kind {kind}"

    def classify_user(self, name: str) -> tuple[str, object]:
        if name in ("ImVec2", "ImVec2_t"):
            return "vec2", None
        if name in ("ImVec4", "ImVec4_t"):
            return "vec4", None
        if name in ("ImTextureID",):
            return "scalar", ("u64", "uint64_t")
        if name in self.enums or (name + "_") in self.enums:
            return "enum", name
        if name in self.typedefs:
            inner = self.typedefs[name].get("description", {})
            if inner:
                kind, val = self.classify(inner)
                # A typedef of a builtin keeps its C spelling of the typedef,
                # which for size_t-style names is exact and clearer.
                if kind == "scalar" and inner.get("kind") == "Builtin":
                    return "scalar", SCALARS[inner["builtin_type"]] \
                        if inner["builtin_type"] in SCALARS else val
                return kind, val
            decl = self.typedefs[name].get("declaration", "")
            if decl in ("unsigned int", "ImU32"):
                return "scalar", ("u32", "uint32_t")
            if decl in ("unsigned long long", "unsigned __int64", "ImU64"):
                return "scalar", ("u64", "uint64_t")
            return "unsupported", f"typedef {name} ({decl})"
        if name in self.structs:
            return "struct", name
        return "unsupported", f"unknown type {name}"

    # --- function conversion -------------------------------------------------
    def convert(self, fn: dict) -> Function | None:
        cname = fn["name"]
        if cname in SKIP:
            self.skipped.append((cname, "handwritten shim"))
            return None
        if any(a.get("is_varargs") for a in fn.get("arguments", [])):
            self.skipped.append((cname, "variadic"))
            return None
        args = fn.get("arguments", [])
        params: list[Param] = []
        call_args: list[str] = []
        i = 0
        while i < len(args):
            a = args[i]
            safe = goose_ident(a.get("name", ""), f"arg{i}")
            if a.get("is_array"):
                self.skipped.append((cname, "array argument"))
                return None
            t = a.get("type", {})
            desc = t.get("description", {})
            kind, val = self.classify(desc)
            # `const float* values, int count` becomes one `f32[:]`.
            if (kind in ("unsupported", "scalarptr") and desc.get("kind") == "Pointer" and
                    desc.get("inner_type", {}).get("kind") == "Builtin" and
                    desc.get("inner_type", {}).get("builtin_type") in ("float", "int") and
                    i + 1 < len(args) and
                    re.search(r"count|num|size", args[i + 1].get("name", ""), re.I)):
                nxt = args[i + 1]
                nkind, _ = self.classify(nxt.get("type", {}).get("description", {}))
                if nkind == "scalar" and nxt.get("type", {}).get("description", {}).get(
                        "builtin_type") == "int":
                    goose, c = ("f32s", FLOATS_C) if desc["inner_type"]["builtin_type"] == "float" \
                        else (None, None)
                    if goose is None:
                        self.skipped.append((cname, "integer pointer+count"))
                        return None
                    params.append(Param(safe, FLOATS_GOOSE, FLOATS_C, is_floats=True))
                    call_args.append(f"reinterpret_cast<const float*>({safe}.data)")
                    call_args.append(f"(int){safe}.len")
                    i += 2
                    continue
            if kind == "bytes":
                params.append(Param(safe, BYTES_GOOSE, BYTES_C, is_bytes=True))
                call_args.append(f"igs_z({safe})")
            elif kind == "scalar":
                g, c = val
                pname = safe
                params.append(Param(pname, g, c))
                call_args.append(pname)
            elif kind == "enum":
                # Unscoped C++ enums do not take an int implicitly; the
                # dcimgui header keeps the enum's own name for the cast.
                params.append(Param(safe, "i32", "int32_t"))
                call_args.append(f"static_cast<{val}>({safe})")
            elif kind == "vec2" or kind == "vec4":
                n = 2 if kind == "vec2" else 4
                comps = "xyzw"[:n]
                for comp in comps:
                    pname = f"{safe}_{comp}" if safe != f"_{comp}" else f"{safe}{comp}"
                    params.append(Param(pname, "f32", "float"))
                    call_args.append(pname)
                call_args[-n:] = [
                    "ImVec2{%s, %s}" % (call_args[-2], call_args[-1])
                    if n == 2 else
                    "ImVec4{%s, %s, %s, %s}" % tuple(call_args[-4:])
                ]
            elif kind in ("ptr", "scalarptr"):
                params.append(Param(safe, "u64", "uint64_t"))
                call_args.append(f"reinterpret_cast<{val}>({safe})")
            else:
                self.skipped.append((cname, str(val)))
                return None
            i += 1
        # Return type.
        rdesc = fn.get("return_type", {}).get("description", {})
        rkind, rval = self.classify(rdesc)
        out_vec = 0
        fn_ptr_cast = "void*"
        ret_goose, ret_c = "", "void"
        if rkind == "void":
            pass
        elif rkind == "scalar":
            ret_goose, ret_c = rval
        elif rkind == "enum":
            ret_goose, ret_c = "i32", "int32_t"
        elif rkind in ("vec2", "vec4"):
            out_vec = 2 if rkind == "vec2" else 4
            for comp in "xyzw"[:out_vec]:
                params.append(Param(f"out_{comp}", "f32&", "float*"))
        elif rkind == "ptr":
            ret_goose, ret_c = "u64", "uint64_t"
            fn_ptr_cast = rval
        else:
            self.skipped.append((cname, f"return {rval}"))
            return None
        fn_out = Function(cname, goose_function_name(cname), ret_goose, ret_c, params,
                          out_vec=out_vec)
        # Build the wrapper body's call expression.
        ret_cast = ""
        if out_vec:
            call = f"ImVec{'2' if out_vec == 2 else '4'} r = {cname}({', '.join(call_args)})"
            comps = "xyzw"[:out_vec]
            body = [f"    {call};"]
            body += [f"    *out_{c} = r.{c};" for c in comps]
            fn_out.expr = "\n".join(body)
            return fn_out
        callexpr = f"{cname}({', '.join(call_args)})"
        if ret_c == "uint64_t":
            callexpr = f"reinterpret_cast<uint64_t>({callexpr})"
        if ret_c == "bool":
            callexpr = f"(bool)({callexpr})"
        if ret_goose == "":
            fn_out.expr = f"    {callexpr};"
        else:
            fn_out.expr = f"    return {callexpr};"
        return fn_out

    # --- emitting ------------------------------------------------------------
    def handwritten(self) -> list[tuple[str, str]]:
        """(symbol, goose declaration) for the shim's own functions."""
        out: list[tuple[str, str]] = []
        seen: set[str] = set()
        for path in HANDWRITTEN_HEADERS:
            lines = path.read_text().splitlines()
            for i, line in enumerate(lines):
                marker = line.strip()
                if not marker.startswith("// goose:"):
                    continue
                decl = marker[len("// goose:"):].strip()
                if not decl.startswith("fn "):
                    raise SystemExit(f"{path}:{i + 1}: a goose line must be `fn ...`")
                # The symbol is the name after `fn`.
                symbol = decl[3:].split("(")[0].strip()
                if symbol in seen:
                    raise SystemExit(f"{path}:{i + 1}: {symbol} declared twice")
                seen.add(symbol)
                out.append((symbol, decl))
        return out

    def run(self) -> tuple[str, str, str]:
        functions: list[Function] = []
        seen: dict[str, str] = {}
        hand = self.handwritten()
        hand_symbols = {sym for sym, _ in hand}
        for fn in self.meta.get("functions", []):
            f = self.convert(fn)
            if f is None:
                continue
            if f.symbol in hand_symbols:
                # The shim's version takes a pointer or a buffer, so it is
                # the one Goose should see.
                self.skipped.append((f.cname, "hand-written shim wins"))
                continue
            if f.symbol in seen:
                self.skipped.append((f.cname, f"name collision with {seen[f.symbol]}"))
                continue
            seen[f.symbol] = f.cname
            functions.append(f)
        functions.sort(key=lambda f: f.symbol)

        goose = self.emit_goose(functions, hand)
        header = self.emit_header(functions)
        source = self.emit_source(functions)
        return goose, header, source

    def emit_goose(self, functions: list[Function],
                   hand: list[tuple[str, str]]) -> str:
        lines: list[str] = []
        w = lines.append
        w("// Auto-generated by scripts/generate_bindings.py from")
        w("// native/cimgui/metadata/dcimgui.json (dear_bindings output for Dear ImGui")
        version = next((d["content"].strip('"') for d in self.meta.get("defines", [])
                        if d["name"] == "IMGUI_VERSION"), "unknown")
        w(f"// v{version}). Do not edit: regenerate with")
        w("//     python3 scripts/generate_bindings.py")
        w("//")
        w("// Every function here crosses the ABI as scalars, {data,len} pairs and")
        w("// 64-bit opaque handles only; strings and ImVec2/ImVec4 are adapted in")
        w("// native/generated/igs_api.cpp. Prefer the API in imgui.goose.")
        w("namespace raw;")
        w("")
        w("// --- enumerations (ImGui's own constants, snake_case) --------------------")
        emitted = 0
        for enum in self.meta.get("enums", []):
            # `ImGuiWindowFlags_NoTitleBar` -> `window_flags_no_title_bar`:
            # the C enum's own prefix becomes the constant's prefix, shortened
            # to the part after "ImGui".
            full = camel_to_snake(enum["name"].rstrip("_"))
            short = full
            for lead in ("im_gui_", "imgui_", "im_"):
                if short.startswith(lead):
                    short = short[len(lead):]
                    break
            for el in enum.get("elements", []):
                if el.get("is_internal"):
                    continue
                value = el.get("value")
                if not isinstance(value, int):
                    continue
                name = camel_to_snake(el["name"])
                if name.startswith(full + "_"):
                    name = name[len(full) + 1:]
                elif name == full:
                    name = short
                name = f"{short}_{name}"
                if name in RESERVED:
                    name += "_"
                w(f"let {name}: i32 = {value};")
                emitted += 1
        w("")
        w(f"// {emitted} constants, {len(functions)} generated functions.")
        w("")
        w("// --- generated from the Dear ImGui metadata ------------------------------")
        for f in functions:
            params = ", ".join(f"{p.name}: {p.goose}" for p in f.params)
            ret = f" -> {f.ret_goose}" if f.ret_goose else ""
            w(f"extern fn {f.symbol}({params}){ret};")
        w("")
        w("// --- the shim's own entry points (native/goose_imgui_shim.h and ----------")
        w("// --- native/goose_imgui_internal.h); the file each is written in ---------")
        for _, decl in hand:
            w(f"extern {decl};")
        w("")
        return "\n".join(lines)

    def emit_header(self, functions: list[Function]) -> str:
        lines = [
            "// Auto-generated by scripts/generate_bindings.py. Do not edit.",
            "#ifndef IMGUI_GOOSE_IGS_API_H",
            "#define IMGUI_GOOSE_IGS_API_H",
            "",
            "#include <stdint.h>",
            "",
            "#ifdef __cplusplus",
            'extern "C" {',
            "#endif",
            "",
            "typedef struct { uint8_t *data; int64_t len; } igs_u8s;",
            "typedef struct { float *data; int64_t len; } igs_f32s;",
            "",
        ]
        for f in functions:
            lines.append(f"{f.ret_c} {f.symbol}({self.c_params(f)});")
        lines += [
            "",
            "#ifdef __cplusplus",
            "}",
            "#endif",
            "",
            "#endif",
            "",
        ]
        return "\n".join(lines)

    def c_params(self, f: Function) -> str:
        return ", ".join(f"{p.c} {p.name}" for p in f.params)

    def emit_source(self, functions: list[Function]) -> str:
        lines = [
            "// Auto-generated by scripts/generate_bindings.py. Do not edit.",
            "//",
            "// Thin extern \"C\" adapters over dcimgui: {data,len} pairs become",
            "// std::string, floats become ImVec2/ImVec4, and ImVec2/ImVec4 returns",
            "// become out parameters. Built with the rest of native/ by CMake.",
            "",
            '#include "dcimgui.h"',
            '#include "igs_api.h"',
            "",
            "#include <string>",
            "",
            "namespace {",
            "// dcimgui takes `const char *`, so text needs a NUL. A thread_local",
            "// buffer keeps the copy alive for the call and never leaks.",
            "inline const char *igs_z(const igs_u8s &s) {",
            "    static thread_local std::string buf;",
            "    buf.assign((const char *)s.data, (size_t)s.len);",
            "    return buf.c_str();",
            "}",
            "}  // namespace",
            "",
        ]
        for f in functions:
            # String parameters need the copying adapter; rewrite the call.
            expr = f.expr
            lines.append(f"extern \"C\" {f.ret_c} {f.symbol}({self.c_params(f)}) {{")
            if not f.params:
                lines.append("    (void)0;")
            lines.append(expr)
            lines.append("}")
            lines.append("")
        return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true",
                    help="fail unless the checked-in output is up to date")
    ap.add_argument("--metadata", default=str(METADATA))
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    meta = json.loads(Path(args.metadata).read_text())
    gen = Generator(meta)
    goose, header, source = gen.run()
    outputs = [(RAW_GOOSE, goose), (GLUE_H, header), (GLUE_CPP, source)]

    if args.check:
        stale = [p for p, text in outputs
                 if not p.exists() or p.read_text() != text]
        for p in stale:
            print(f"out of date: {p.relative_to(ROOT)}", file=sys.stderr)
        return 1 if stale else 0

    for path, text in outputs:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        print(f"wrote {path.relative_to(ROOT)} ({len(text.splitlines())} lines)")
    if args.verbose:
        print(f"skipped {len(gen.skipped)} functions:", file=sys.stderr)
        for name, why in gen.skipped:
            print(f"  {name}: {why}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
