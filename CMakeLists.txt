# goose-imgui's native part: Dear ImGui (docking), the generated C API from
# dear_bindings, the SDL3 platform and SDL_GPU3 renderer backends, the
# generated per-function wrappers, and the C ABI shim.
#
# Goose builds this through the package's sidecar (`imgui.build`, which names
# the `imgui_goose` target): `goose build` and `goose run` configure and build
# it with CMake automatically, so a user never runs CMake themselves.
#
# SDL3 comes from one of, in order:
#   1. a source tree named by -DIMGUI_GOOSE_SDL3_SOURCE=/path/to/SDL
#   2. an SDL3 CMake package (Homebrew, vcpkg, a distro's sdl3-devel, ...)
#   3. pkg-config
# SDL3 3.2 or newer is required: SDL_GPU and the SDL3 backend's SDL3 version
# checks both need it.

cmake_minimum_required(VERSION 3.20)
project(imgui_goose C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(IMGUI_GOOSE_DIR "${CMAKE_CURRENT_SOURCE_DIR}")
set(IMGUI_GOOSE_SDL3_SOURCE "" CACHE PATH "SDL3 source tree to build (optional)")

# --- SDL3 -------------------------------------------------------------------
if(IMGUI_GOOSE_SDL3_SOURCE)
    if(NOT EXISTS "${IMGUI_GOOSE_SDL3_SOURCE}/CMakeLists.txt")
        message(FATAL_ERROR "IMGUI_GOOSE_SDL3_SOURCE=${IMGUI_GOOSE_SDL3_SOURCE} has no CMakeLists.txt")
    endif()
    set(SDL_SHARED OFF CACHE BOOL "" FORCE)
    set(SDL_STATIC ON CACHE BOOL "" FORCE)
    set(SDL_TEST_LIBRARY OFF CACHE BOOL "" FORCE)
    add_subdirectory("${IMGUI_GOOSE_SDL3_SOURCE}" SDL3 EXCLUDE_FROM_ALL)
endif()

if(NOT TARGET SDL3::SDL3)
    # The usual install prefixes, so a Homebrew or /usr/local SDL3 is found
    # without the caller setting CMAKE_PREFIX_PATH.
    find_package(SDL3 CONFIG QUIET
                 HINTS "${IMGUI_GOOSE_DIR}/third_party/SDL3"
                       "$ENV{HOMEBREW_PREFIX}/lib/cmake"
                       "$ENV{SDL3_DIR}"
                       /opt/homebrew/lib/cmake /usr/local/lib/cmake /usr/lib/cmake)
endif()

if(NOT TARGET SDL3::SDL3)
    find_package(PkgConfig QUIET)
    if(PkgConfig_FOUND)
        pkg_check_modules(SDL3PC QUIET IMPORTED_TARGET SDL3>=3.2)
        if(SDL3PC_FOUND)
            add_library(SDL3::SDL3 ALIAS PkgConfig::SDL3PC)
        endif()
    endif()
endif()

if(NOT TARGET SDL3::SDL3)
    message(FATAL_ERROR
        "goose-imgui needs SDL3 3.2 or newer (SDL_GPU), and could not find it.\n"
        "Install it (macOS: `brew install sdl3`, Debian/Ubuntu: `apt install libsdl3-dev`,\n"
        "Windows: vcpkg `vcpkg install sdl3` or the SDL3 release package), or point\n"
        "CMake at an SDL3 source tree with -DIMGUI_GOOSE_SDL3_SOURCE=/path/to/SDL.")
endif()

# --- Dear ImGui -------------------------------------------------------------
set(IMGUI_DIR "${IMGUI_GOOSE_DIR}/native/cimgui/imgui")

add_library(imgui_goose_core STATIC
    "${IMGUI_DIR}/imgui.cpp"
    "${IMGUI_DIR}/imgui_draw.cpp"
    "${IMGUI_DIR}/imgui_tables.cpp"
    "${IMGUI_DIR}/imgui_widgets.cpp"
    "${IMGUI_DIR}/imgui_demo.cpp"
    "${IMGUI_DIR}/backends/imgui_impl_sdl3.cpp"
    "${IMGUI_DIR}/backends/imgui_impl_sdlgpu3.cpp"
    "${IMGUI_GOOSE_DIR}/native/cimgui/dcimgui.cpp"
    "${IMGUI_GOOSE_DIR}/native/cimgui/dcimgui_impl_sdl3.cpp"
    "${IMGUI_GOOSE_DIR}/native/cimgui/dcimgui_impl_sdlgpu3.cpp"
)
target_include_directories(imgui_goose_core PUBLIC
    "${IMGUI_DIR}"
    "${IMGUI_DIR}/backends"
    "${IMGUI_GOOSE_DIR}/native/cimgui"
)
target_link_libraries(imgui_goose_core PUBLIC SDL3::SDL3)
set_target_properties(imgui_goose_core PROPERTIES POSITION_INDEPENDENT_CODE ON)

# Dear ImGui's own warnings are not ours to act on; imgui_goose does not
# re-enable them for the vendored sources.
if(MSVC)
    target_compile_options(imgui_goose_core PRIVATE /W0 /utf-8)
    target_compile_definitions(imgui_goose_core PRIVATE _CRT_SECURE_NO_WARNINGS)
else()
    target_compile_options(imgui_goose_core PRIVATE -w)
endif()

# --- the Goose ABI ----------------------------------------------------------
# generated/igs_api.cpp has one wrapper per function the Goose side declares;
# goose_imgui_shim.cpp and goose_imgui_internal.cpp are the hand-written half.
add_library(imgui_goose STATIC
    "${IMGUI_GOOSE_DIR}/native/generated/igs_api.cpp"
    "${IMGUI_GOOSE_DIR}/native/goose_imgui_shim.cpp"
    "${IMGUI_GOOSE_DIR}/native/goose_imgui_internal.cpp"
)
target_include_directories(imgui_goose PUBLIC
    "${IMGUI_GOOSE_DIR}/native"
    "${IMGUI_GOOSE_DIR}/native/generated"
)
target_link_libraries(imgui_goose PUBLIC imgui_goose_core)
set_target_properties(imgui_goose PROPERTIES POSITION_INDEPENDENT_CODE ON)

if(MSVC)
    target_compile_options(imgui_goose PRIVATE /W3 /utf-8)
    target_compile_definitions(imgui_goose PRIVATE _CRT_SECURE_NO_WARNINGS)
else()
    target_compile_options(imgui_goose PRIVATE -Wall -Wextra -Wno-unused-parameter)
endif()

# The C++ runtime, through this target's interface.
#
# Goose links a program with the C compiler driver and a probe that is itself a
# C file, so CMake never adds the C++ runtime: nothing on that link line is
# C++, yet Dear ImGui and the shim are. Publishing the compiler's own implicit
# C++ libraries here puts them in the package's link closure, which is what
# `goose build` uses. MSVC records them in each object as /DEFAULTLIB.
if(NOT MSVC)
    if(CMAKE_CXX_IMPLICIT_LINK_LIBRARIES)
        target_link_libraries(imgui_goose INTERFACE ${CMAKE_CXX_IMPLICIT_LINK_LIBRARIES})
    elseif(APPLE)
        target_link_libraries(imgui_goose INTERFACE c++ c++abi)
    else()
        target_link_libraries(imgui_goose INTERFACE stdc++)
    endif()
endif()

# The package is one static library; what a Goose program links is
# imgui_goose, which carries Dear ImGui, the backends and SDL3 with it.
get_target_property(_sdl3_type SDL3::SDL3 TYPE)
message(STATUS "goose-imgui: Dear ImGui ${IMGUI_DIR}, ${_sdl3_type} SDL3")
