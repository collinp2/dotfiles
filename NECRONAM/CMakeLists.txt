cmake_minimum_required(VERSION 3.21)

# ============================================================================
#  NECRONAM  —  Neural Amp Necromancy
#  A Neural Amp Modeler (NAM) capture player with cab IR, API-560 style
#  graphic EQ, hi/low-pass filters and the Flesh Render multiband saturator.
#  VoidCraft Audio. JUCE + NeuralAmpModelerCore.
# ============================================================================

project(NECRONAM VERSION 1.0.0 LANGUAGES C CXX)

# NAM core requires C++20; JUCE is happy with it too.
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(FetchContent)

# ----------------------------------------------------------------------------
# JUCE  (develop branch + full history — required for macOS 15, per repo notes)
# ----------------------------------------------------------------------------
FetchContent_Declare(
    juce
    GIT_REPOSITORY https://github.com/juce-framework/JUCE.git
    GIT_TAG        develop
    GIT_SHALLOW    FALSE
)
FetchContent_MakeAvailable(juce)

# ----------------------------------------------------------------------------
# NeuralAmpModelerCore  (brings AudioDSPTools + Eigen as submodules,
# nlohmann/json is vendored in-tree). We compile its sources directly into
# our target rather than relying on its CMake targets.
# ----------------------------------------------------------------------------
FetchContent_Declare(
    nam_core
    GIT_REPOSITORY https://github.com/sdatkinson/NeuralAmpModelerCore.git
    GIT_TAG        main
    GIT_SHALLOW    FALSE
)
# We only want the sources, not its CMake project, so Populate (not MakeAvailable).
FetchContent_GetProperties(nam_core)
if(NOT nam_core_POPULATED)
    FetchContent_Populate(nam_core)
endif()

set(NAM_DIR        "${nam_core_SOURCE_DIR}")
set(NAM_DEPS       "${NAM_DIR}/Dependencies")
set(ADT_DIR        "${NAM_DEPS}/AudioDSPTools")

# Core + AudioDSPTools translation units.
file(GLOB NAM_CORE_SOURCES "${NAM_DIR}/NAM/*.cpp")
file(GLOB ADT_SOURCES      "${ADT_DIR}/dsp/*.cpp")

if(NOT NAM_CORE_SOURCES)
    message(FATAL_ERROR
        "NeuralAmpModelerCore sources not found. Run a fresh configure so "
        "FetchContent can clone the repo and its submodules (Eigen, AudioDSPTools).")
endif()

# ----------------------------------------------------------------------------
# Plugin target
# ----------------------------------------------------------------------------
juce_add_plugin(NECRONAM
    PRODUCT_NAME              "NECRONAM"
    COMPANY_NAME             "VoidCraft Audio"
    BUNDLE_ID                "com.voidcraftaudio.necronam"
    DESCRIPTION              "Neural Amp Necromancy — NAM player, IR, EQ & Saturation"
    PLUGIN_MANUFACTURER_CODE  Void
    PLUGIN_CODE               Ncnm
    FORMATS                   VST3 AU Standalone
    IS_SYNTH                  FALSE
    NEEDS_MIDI_INPUT          FALSE
    NEEDS_MIDI_OUTPUT         FALSE
    IS_MIDI_EFFECT            FALSE
    EDITOR_WANTS_KEYBOARD_FOCUS FALSE
    COPY_PLUGIN_AFTER_BUILD   TRUE
    VST3_CATEGORIES           "Fx" "Distortion"
    AU_MAIN_TYPE              "kAudioUnitType_Effect"
)

juce_generate_juce_header(NECRONAM)

# Embedded assets (parchment/marble background texture).
juce_add_binary_data(NecronamAssets SOURCES Resources/parchment.png)

target_sources(NECRONAM PRIVATE
    Source/PluginProcessor.cpp
    Source/PluginEditor.cpp
    Source/HorrorLookAndFeel.cpp
    ${NAM_CORE_SOURCES}
    ${ADT_SOURCES}
)

# Make NAM / AudioDSPTools floats so they line up with JUCE's float buffers.
target_compile_definitions(NECRONAM PRIVATE
    JUCE_WEB_BROWSER=0
    JUCE_USE_CURL=0
    JUCE_VST3_CAN_REPLACE_VST2=0
    JUCE_DISPLAY_SPLASH_SCREEN=0
    NAM_SAMPLE_FLOAT=1
    DSP_SAMPLE_FLOAT=1
)

# Include paths for NAM core, AudioDSPTools and their dependencies. We add the
# common candidate locations so the in-tree includes resolve regardless of how
# the (possibly nested) submodules get laid out.
target_include_directories(NECRONAM PRIVATE
    "${NAM_DIR}"
    "${NAM_DEPS}"
    "${ADT_DIR}"
    "${ADT_DIR}/Dependencies"
)
target_include_directories(NECRONAM SYSTEM PRIVATE
    "${NAM_DEPS}/eigen"
    "${ADT_DIR}/Dependencies/eigen"
)

target_link_libraries(NECRONAM PRIVATE
    NecronamAssets
    juce::juce_audio_utils
    juce::juce_audio_processors
    juce::juce_dsp
    juce::juce_recommended_config_flags
    juce::juce_recommended_lto_flags
    juce::juce_recommended_warning_flags
)
