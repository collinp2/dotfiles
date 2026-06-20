#pragma once

#include <juce_gui_basics/juce_gui_basics.h>

namespace horror
{
    // ----- High-Contrast "Gory Light Mode" Palette (Stained Bone & Arterial Blood) -----
    inline constexpr juce::uint32 COL_BACKGROUND   = 0xFFF2EFE9; // Aged, dried bone surface
    inline constexpr juce::uint32 COL_HEADER_BG    = 0xFFE5DEC9; // Heavily stained, darker bone tier
    inline constexpr juce::uint32 COL_PANEL_BG     = 0xFFF7F5F0; // Bright bone white for high UI panel contrast
    inline constexpr juce::uint32 COL_PANEL_BORDER = 0xFF501212; // Coagulated scab-red borders

    inline constexpr juce::uint32 COL_BLOOD_DARK   = 0xFF4A0505; // Deep, oxidized scab red
    inline constexpr juce::uint32 COL_BLOOD        = 0xFF9E0C0C; // Rich, arterial blood red
    inline constexpr juce::uint32 COL_BLOOD_BRIGHT = 0xFFD60606; // Vivid, freshly spilled visceral red

    inline constexpr juce::uint32 COL_BONE         = 0xFF2A1C1C; // Deep crimson-tinted near-black for readable text
    inline constexpr juce::uint32 COL_BONE_DIM     = 0xFF6D5A5A; // Dried blood stain color for inactive text/markers

    inline constexpr juce::uint32 COL_KNOB_BODY    = 0xFF500A0A; // Clotted blood chunk knob body
    inline constexpr juce::uint32 COL_KNOB_SHINE   = 0xFF851A1A; // Fresh wet shine on the knob cap
    inline constexpr juce::uint32 COL_KNOB_SHADOW  = 0xFFD0C3B0; // Soft bone-tinted drop shadow (instead of black)
    inline constexpr juce::uint32 COL_RUST         = 0xFF7D3C3C; // Dried flesh / rust accent

    // Light bone tone for text/marks drawn on top of dark blood fills.
    inline constexpr juce::uint32 COL_BONE_LIGHT   = 0xFFF7F5F0;

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

    static void drawGrainTexture (juce::Graphics&, juce::Rectangle<int> area, float alpha = 0.04f);
    static void drawBloodDrips   (juce::Graphics&, juce::Rectangle<float> area);
    static void drawPanelBackground (juce::Graphics&, juce::Rectangle<float> bounds);
};
