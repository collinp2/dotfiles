#include "PluginEditor.h"

using namespace horror;

namespace
{
    juce::Font monoFont (float h, bool bold = true)
    {
        return juce::Font (juce::Font::getDefaultMonospacedFontName(), h,
                           bold ? juce::Font::bold : juce::Font::plain);
    }
}

// ===========================================================================
NecronamAudioProcessorEditor::NecronamAudioProcessorEditor (NecronamAudioProcessor& p)
    : AudioProcessorEditor (&p), processor (p)
{
    setLookAndFeel (&lnf);

    // ---- Model / IR controls ----
    addAndMakeVisible (loadModelButton);
    addAndMakeVisible (clearModelButton);
    addAndMakeVisible (loadIRButton);
    addAndMakeVisible (clearIRButton);
    loadModelButton.onClick = [this] { chooseFile (true); };
    clearModelButton.onClick = [this] { processor.clearNamModel(); };
    loadIRButton.onClick = [this] { chooseFile (false); };
    clearIRButton.onClick = [this] { processor.clearImpulseResponse(); };

    for (auto* l : { &modelNameLabel, &irNameLabel })
    {
        l->setFont (monoFont (11.0f, false));
        l->setColour (juce::Label::textColourId, c (COL_BONE_DIM));
        l->setJustificationType (juce::Justification::centredLeft);
        addAndMakeVisible (*l);
    }

    addAndMakeVisible (outputModeBox);
    outputModeBox.addItemList ({ "Raw", "Normalized", "Calibrated" }, 1);
    outputModeAttach = std::make_unique<ComboAttach> (processor.apvts,
                                                      NecronamAudioProcessor::ParamID::outputMode,
                                                      outputModeBox);

    // A2 quality / efficiency slider (horizontal, max efficiency .. max quality).
    qualitySlider.setSliderStyle (juce::Slider::LinearHorizontal);
    qualitySlider.setTextBoxStyle (juce::Slider::TextBoxRight, false, 96, 16);
    qualitySlider.setColour (juce::Slider::textBoxTextColourId, c (COL_BONE));
    addAndMakeVisible (qualitySlider);
    sliderAttachments.push_back (std::make_unique<SliderAttach> (
        processor.apvts, NecronamAudioProcessor::ParamID::quality, qualitySlider));

    using ID = NecronamAudioProcessor::ParamID;

    // ---- Knobs ----
    inputKnob    = &addKnob (ID::inputLevel,  "INPUT");
    gateKnob     = &addKnob (ID::gateThresh,  "GATE THR");
    outputKnob   = &addKnob (ID::outputLevel, "OUTPUT");
    inputCalKnob = &addKnob (ID::inputCal,    "IN CAL");
    hpfKnob      = &addKnob (ID::hpfFreq,     "HI-PASS");
    lpfKnob      = &addKnob (ID::lpfFreq,     "LOW-PASS");

    // ---- Toggles ----
    gateToggle = &addToggle (ID::gateActive, "Gate");
    irToggle   = &addToggle (ID::irActive,   "IR On");
    eqToggle   = &addToggle (ID::eqActive,   "EQ On");
    satToggle  = &addToggle (ID::satActive,  "Sat On");
    hpfToggle  = &addToggle (ID::hpfActive,  "On");
    lpfToggle  = &addToggle (ID::lpfActive,  "On");

    // ---- Graphic EQ sliders ----
    for (int i = 0; i < Api560EQ::kNumBands; ++i)
    {
        const float f = Api560EQ::kFrequencies[(size_t) i];
        const juce::String name = f >= 1000.0f ? juce::String (f / 1000.0f, (f == 16000.0f ? 0 : 1)) + "k"
                                               : juce::String (juce::roundToInt (f));
        eqSliders[(size_t) i] = &addVSlider (NecronamAudioProcessor::eqParamID (i), name);
    }

    // ---- Saturation knobs (low/mid/high x sat/dist/fuzz) ----
    const char* bandIds[3]  = { "low", "mid", "high" };
    const char* stageIds[3] = { "sat", "dist", "fuzz" };
    const char* stageNm[3]  = { "SAT", "DIST", "FUZZ" };
    for (int b = 0; b < 3; ++b)
        for (int s = 0; s < 3; ++s)
            satKnobs[(size_t) (b * 3 + s)] =
                &addKnob (juce::String (bandIds[b]) + "_" + stageIds[s], stageNm[s]);

    startTimerHz (5);
    setSize (1000, 800);
}

NecronamAudioProcessorEditor::~NecronamAudioProcessorEditor()
{
    setLookAndFeel (nullptr);
}

// ===========================================================================
juce::Slider& NecronamAudioProcessorEditor::addKnob (const juce::String& paramID, const juce::String& labelText)
{
    auto s = std::make_unique<juce::Slider> (juce::Slider::RotaryHorizontalVerticalDrag,
                                             juce::Slider::TextBoxBelow);
    s->setRotaryParameters (juce::MathConstants<float>::pi * 1.25f,
                            juce::MathConstants<float>::pi * 2.75f, true);
    s->setTextBoxStyle (juce::Slider::TextBoxBelow, false, 66, 15);
    addAndMakeVisible (*s);

    auto lab = std::make_unique<juce::Label> (juce::String(), labelText);
    lab->setJustificationType (juce::Justification::centred);
    lab->setFont (monoFont (10.0f));
    lab->setColour (juce::Label::textColourId, c (COL_BONE));
    addAndMakeVisible (*lab);
    lab->attachToComponent (s.get(), false);

    sliderAttachments.push_back (std::make_unique<SliderAttach> (processor.apvts, paramID, *s));

    auto& ref = *s;
    sliders.push_back (std::move (s));
    labels.push_back (std::move (lab));
    return ref;
}

juce::Slider& NecronamAudioProcessorEditor::addVSlider (const juce::String& paramID, const juce::String& labelText)
{
    auto s = std::make_unique<juce::Slider> (juce::Slider::LinearVertical, juce::Slider::TextBoxBelow);
    s->setTextBoxStyle (juce::Slider::TextBoxBelow, false, 50, 14);
    addAndMakeVisible (*s);

    auto lab = std::make_unique<juce::Label> (juce::String(), labelText);
    lab->setJustificationType (juce::Justification::centred);
    lab->setFont (monoFont (9.5f));
    lab->setColour (juce::Label::textColourId, c (COL_BONE_DIM));
    addAndMakeVisible (*lab);
    lab->attachToComponent (s.get(), false);

    sliderAttachments.push_back (std::make_unique<SliderAttach> (processor.apvts, paramID, *s));

    auto& ref = *s;
    sliders.push_back (std::move (s));
    labels.push_back (std::move (lab));
    return ref;
}

juce::TextButton& NecronamAudioProcessorEditor::addToggle (const juce::String& paramID, const juce::String& text)
{
    auto b = std::make_unique<juce::TextButton> (text);
    b->setClickingTogglesState (true);
    addAndMakeVisible (*b);
    buttonAttachments.push_back (std::make_unique<ButtonAttach> (processor.apvts, paramID, *b));

    auto& ref = *b;
    toggles.push_back (std::move (b));
    return ref;
}

void NecronamAudioProcessorEditor::chooseFile (bool isModel)
{
    const auto dir = juce::File::getSpecialLocation (juce::File::userHomeDirectory);
    chooser = std::make_unique<juce::FileChooser> (
        isModel ? "Select a NAM model (.nam)" : "Select an impulse response (.wav)",
        dir, isModel ? "*.nam" : "*.wav");

    const auto flags = juce::FileBrowserComponent::openMode | juce::FileBrowserComponent::canSelectFiles;
    chooser->launchAsync (flags, [this, isModel] (const juce::FileChooser& fc)
    {
        const auto f = fc.getResult();
        if (f.existsAsFile())
        {
            if (isModel) processor.loadNamModel (f);
            else         processor.loadImpulseResponse (f);
        }
    });
}

void NecronamAudioProcessorEditor::timerCallback()
{
    const auto m = processor.getLoadedModelName();
    modelNameLabel.setText (m.isEmpty() ? "(no model)" : m, juce::dontSendNotification);
    const auto ir = processor.getLoadedIRName();
    irNameLabel.setText (ir.isEmpty() ? "(no IR)" : ir, juce::dontSendNotification);

    // The quality slider only does anything for A2 (slimmable) models.
    const bool slim = processor.isModelSlimmable();
    if (qualitySlider.isEnabled() != slim)
    {
        qualitySlider.setEnabled (slim);
        qualitySlider.setAlpha (slim ? 1.0f : 0.45f);
        repaint (qualityLabelArea);
        repaint (getWidth() - 90, 0, 90, 84);   // the A2 header badge
    }
}

// ===========================================================================
void NecronamAudioProcessorEditor::paint (juce::Graphics& g)
{
    const auto w = getWidth();
    g.fillAll (c (COL_BACKGROUND));

    // Header.
    auto header = juce::Rectangle<int> (0, 0, w, 84);
    g.setColour (c (COL_HEADER_BG));
    g.fillRect (header);
    HorrorLookAndFeel::drawBloodDrips (g, header.toFloat().removeFromBottom (40.0f));

    g.setColour (c (COL_BLOOD_BRIGHT));
    g.setFont (juce::Font (juce::Font::getDefaultSansSerifFontName(), 38.0f, juce::Font::bold));
    g.drawText ("NECRONAM", header.reduced (16, 8).removeFromTop (48),
                juce::Justification::centredLeft);

    g.setColour (c (COL_BONE_DIM));
    g.setFont (monoFont (11.0f));
    g.drawText ("[ NEURAL AMP NECROMANCY  //  NAM  -  CAB IR  //  API-560 EQ  //  SATURATION ]",
                header.reduced (18, 8).removeFromBottom (24), juce::Justification::centredLeft);

    // "A2" badge — lit when a slimmable (Architecture 2) model is loaded.
    {
        const bool slim = processor.isModelSlimmable();
        const auto badge = juce::Rectangle<float> (w - 78.0f, 16.0f, 60.0f, 32.0f);
        g.setColour (slim ? c (COL_BLOOD_DARK) : c (COL_PANEL_BG));
        g.fillRoundedRectangle (badge, 4.0f);
        if (slim)   // outer glow
        {
            g.setColour (c (COL_BLOOD_BRIGHT).withAlpha (0.25f));
            g.drawRoundedRectangle (badge.expanded (2.0f), 5.0f, 2.0f);
        }
        g.setColour (slim ? c (COL_BLOOD_BRIGHT) : c (COL_BONE_DIM).withAlpha (0.5f));
        g.drawRoundedRectangle (badge, 4.0f, 1.4f);
        g.setColour (slim ? c (COL_BONE) : c (COL_BONE_DIM).withAlpha (0.5f));
        g.setFont (juce::Font (juce::Font::getDefaultSansSerifFontName(), 18.0f, juce::Font::bold));
        g.drawText ("A2", badge.withTrimmedBottom (9.0f), juce::Justification::centred);
        g.setFont (monoFont (6.5f));
        g.drawText ("ARCHITECTURE", badge.removeFromBottom (10.0f), juce::Justification::centred);
    }

    auto sectionTitle = [&] (juce::Rectangle<int> area, const juce::String& t)
    {
        g.setColour (c (COL_BLOOD_BRIGHT));
        g.setFont (monoFont (12.0f));
        g.drawText (t, area.reduced (14, 6).removeFromTop (16), juce::Justification::centredLeft);
    };

    // Panels.
    for (auto* r : { &ampArea, &cabArea, &filterArea, &eqArea, &satArea })
        HorrorLookAndFeel::drawPanelBackground (g, r->toFloat());

    sectionTitle (ampArea,    "AMP / MODEL");
    sectionTitle (cabArea,    "CAB / IMPULSE RESPONSE");
    sectionTitle (filterArea, "FILTERS");
    sectionTitle (eqArea,     "GRAPHIC EQ  -  API 560 STYLE");
    sectionTitle (satArea,    "SATURATION  -  FLESH RENDER");

    // Saturation band labels.
    if (! satArea.isEmpty())
    {
        auto s = satArea.reduced (12);
        s.removeFromTop (26 + 16);
        const char* names[3] = { "LOW", "MID", "HIGH" };
        const int cw = s.getWidth() / 3;
        g.setColour (c (COL_BLOOD));
        g.setFont (monoFont (12.0f));
        for (int b = 0; b < 3; ++b)
            g.drawText (names[b], s.removeFromLeft (cw).removeFromTop (14), juce::Justification::centred);
    }

    // Quality slider hints: MAX EFFICIENCY <- ... -> MAX QUALITY.
    if (! qualityLabelArea.isEmpty())
    {
        const auto track = qualityLabelArea.withTrimmedRight (96);   // exclude value box
        const bool slim = processor.isModelSlimmable();
        const float dim = slim ? 1.0f : 0.4f;    // grey the whole section for A1
        g.setFont (monoFont (9.0f));
        g.setColour (c (COL_BONE_DIM).withAlpha (dim));
        g.drawText ("MAX EFFICIENCY", track, juce::Justification::centredLeft);
        g.drawText ("MAX QUALITY",    track, juce::Justification::centredRight);
        g.setColour (slim ? c (COL_BLOOD_BRIGHT) : c (COL_BONE_DIM).withAlpha (dim));
        g.drawText (slim ? "QUALITY (A2)" : "QUALITY (A1 - FIXED)", track, juce::Justification::centred);
    }

    // Footer.
    g.setColour (c (COL_BONE_DIM));
    g.setFont (monoFont (10.0f));
    g.drawText ("VOIDCRAFT AUDIO  -  NECRONAM v1.0  -  NEURAL AMP NECROMANCY",
                juce::Rectangle<int> (0, getHeight() - 26, w, 22), juce::Justification::centred);

    // Grain overlay.
    HorrorLookAndFeel::drawGrainTexture (g, getLocalBounds());
}

// ===========================================================================
void NecronamAudioProcessorEditor::resized()
{
    auto area = getLocalBounds();
    area.removeFromTop (84);                 // header
    area.removeFromBottom (28);              // footer
    area.reduce (12, 8);

    // ---- Row 1: AMP | (CAB over FILTERS) ----
    auto row1 = area.removeFromTop (268);
    ampArea = row1.removeFromLeft (380);
    row1.removeFromLeft (12);
    cabArea = row1.removeFromTop (74);
    row1.removeFromTop (10);
    filterArea = row1;

    area.removeFromTop (10);

    // ---- Row 2: EQ ----
    eqArea = area.removeFromTop (210);
    area.removeFromTop (10);

    // ---- Row 3: SAT ----
    satArea = area;

    // ===== AMP contents =====
    {
        auto a = ampArea.reduced (14);
        a.removeFromTop (22);                 // section title

        auto loadRow = a.removeFromTop (26);
        loadModelButton.setBounds (loadRow.removeFromLeft (120));
        loadRow.removeFromLeft (6);
        clearModelButton.setBounds (loadRow.removeFromRight (28));
        loadRow.removeFromRight (6);
        modelNameLabel.setBounds (loadRow);

        a.removeFromTop (18);                 // room for knob labels
        auto knobRow = a.removeFromTop (94);
        const int kw = knobRow.getWidth() / 4;
        inputKnob->setBounds    (knobRow.removeFromLeft (kw).reduced (5));
        gateKnob->setBounds     (knobRow.removeFromLeft (kw).reduced (5));
        outputKnob->setBounds   (knobRow.removeFromLeft (kw).reduced (5));
        inputCalKnob->setBounds (knobRow.reduced (5));

        a.removeFromTop (8);
        auto modeRow = a.removeFromTop (26);
        outputModeBox.setBounds (modeRow.removeFromLeft (160));
        modeRow.removeFromLeft (10);
        gateToggle->setBounds (modeRow.removeFromLeft (74));

        a.removeFromTop (8);
        qualityLabelArea = a.removeFromTop (14);          // painted hints
        qualitySlider.setBounds (a.removeFromTop (26));
    }

    // ===== CAB contents =====
    {
        auto cb = cabArea.reduced (14);
        cb.removeFromTop (20);
        auto crow = cb.removeFromTop (26);
        loadIRButton.setBounds (crow.removeFromLeft (110));
        crow.removeFromLeft (6);
        clearIRButton.setBounds (crow.removeFromRight (28));
        crow.removeFromRight (8);
        irToggle->setBounds (crow.removeFromRight (74));
        crow.removeFromRight (8);
        irNameLabel.setBounds (crow);
    }

    // ===== FILTERS contents =====
    {
        auto fa = filterArea.reduced (14);
        fa.removeFromTop (22);
        const int half = fa.getWidth() / 2;
        auto left = fa.removeFromLeft (half);
        auto right = fa;

        left.removeFromTop (18);              // label room
        hpfKnob->setBounds (left.removeFromTop (84).reduced (24, 2));
        hpfToggle->setBounds (left.removeFromTop (24).reduced (34, 2));

        right.removeFromTop (18);
        lpfKnob->setBounds (right.removeFromTop (84).reduced (24, 2));
        lpfToggle->setBounds (right.removeFromTop (24).reduced (34, 2));
    }

    // ===== EQ contents =====
    {
        auto e = eqArea.reduced (14);
        auto etop = e.removeFromTop (24);
        eqToggle->setBounds (etop.removeFromRight (90));
        e.removeFromTop (16);                 // label room
        const int n = Api560EQ::kNumBands;
        const int sw = e.getWidth() / n;
        for (int i = 0; i < n; ++i)
            eqSliders[(size_t) i]->setBounds (e.removeFromLeft (sw).reduced (6, 2));
    }

    // ===== SAT contents =====
    {
        auto s = satArea.reduced (14);
        auto stop = s.removeFromTop (24);
        satToggle->setBounds (stop.removeFromRight (90));
        s.removeFromTop (16 + 14);            // section + band-name room
        const int cw = s.getWidth() / 3;
        for (int b = 0; b < 3; ++b)
        {
            auto col = s.removeFromLeft (cw);
            const int kw = col.getWidth() / 3;
            for (int st = 0; st < 3; ++st)
                satKnobs[(size_t) (b * 3 + st)]->setBounds (col.removeFromLeft (kw).reduced (6));
        }
    }
}
