#pragma once

// ============================================================================
//  HorrorLookAndFeel  —  VoidCraft Audio house style (from "Flesh Render")
//  Blood-red / bone palette, jagged "claw" tick marks, grain + blood-drip
//  decorations. Reused so NECRONAM matches the existing horror line.
// ============================================================================

#include <juce_gui_basics/juce_gui_basics.h>

namespace horror
{
    // ----- Palette (matches Flesh Render) ------------------------------------
    inline constexpr juce::uint32 COL_BACKGROUND   = 0xFF080208;
    inline constexpr juce::uint32 COL_HEADER_BG    = 0xFF1A0000;
    inline constexpr juce::uint32 COL_PANEL_BG     = 0xFF0D0808;
    inline constexpr juce::uint32 COL_PANEL_BORDER = 0xFF5A0000;
    inline constexpr juce::uint32 COL_BLOOD_DARK   = 0xFF5A0000;
    inline constexpr juce::uint32 COL_BLOOD        = 0xFF8B0000;
    inline constexpr juce::uint32 COL_BLOOD_BRIGHT = 0xFFBB1515;
    inline constexpr juce::uint32 COL_BONE         = 0xFFCCBDA5;
    inline constexpr juce::uint32 COL_BONE_DIM     = 0xFF7A6A55;
    inline constexpr juce::uint32 COL_KNOB_BODY    = 0xFF1A1A1A;
    inline constexpr juce::uint32 COL_KNOB_SHINE   = 0xFF2E2E2E;
    inline constexpr juce::uint32 COL_KNOB_SHADOW  = 0xFF090909;
    inline constexpr juce::uint32 COL_RUST         = 0xFF3D2020;

    inline juce::Colour c (juce::uint32 argb) { return juce::Colour (argb); }
}

class HorrorLookAndFeel : public juce::LookAndFeel_V4
{
public:
    HorrorLookAndFeel();

    void drawRotarySlider (juce::Graphics&, int x, int y, int width, int height,
                           float sliderPos, float rotaryStartAngle, float rotaryEndAngle,
                           juce::Slider&) override;

    void drawLinearSlider (juce::Graphics&, int x, int y, int width, int height,
                           float sliderPos, float minSliderPos, float maxSliderPos,
                           juce::Slider::SliderStyle, juce::Slider&) override;

    void drawLabel (juce::Graphics&, juce::Label&) override;
    juce::Font getLabelFont (juce::Label&) override;

    void drawButtonBackground (juce::Graphics&, juce::Button&, const juce::Colour& backgroundColour,
                               bool shouldDrawButtonAsHighlighted, bool shouldDrawButtonAsDown) override;
    void drawButtonText (juce::Graphics&, juce::TextButton&,
                         bool shouldDrawButtonAsHighlighted, bool shouldDrawButtonAsDown) override;

    // Reusable decoration helpers.
    static void drawGrainTexture (juce::Graphics&, juce::Rectangle<int> area, float alpha = 0.018f);
    static void drawBloodDrips   (juce::Graphics&, juce::Rectangle<float> area);
    static void drawPanelBackground (juce::Graphics&, juce::Rectangle<float> bounds);
};
