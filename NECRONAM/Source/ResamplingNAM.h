#pragma once

// ============================================================================
//  ResamplingNAM
//  Thin wrapper around a nam::DSP model that transparently resamples the host
//  audio to/from the model's native sample rate using AudioDSPTools'
//  ResamplingContainer. When the host SR already matches the model SR (the
//  common, lowest-latency case) the resampler is bypassed entirely and the
//  reported latency is exactly zero.
//
//  Modelled on sdatkinson/NeuralAmpModelerPlugin's ResamplingNAM, re-authored
//  for a JUCE host.
// ============================================================================

#include <cmath>
#include <memory>

#include "NAM/dsp.h"
#include "NAM/slimmable.h"
#include "dsp/ResamplingContainer/ResamplingContainer.h"

class ResamplingNAM
{
public:
    explicit ResamplingNAM (std::unique_ptr<nam::DSP> encapsulated)
        : mEncapsulated (std::move (encapsulated))
    {
        if (mEncapsulated != nullptr)
            mExpectedSampleRate = mEncapsulated->GetExpectedSampleRate();
    }

    // Prepare for a given host sample rate / max block size. Allocates — call
    // off the audio thread (e.g. right after loading the model, or in
    // prepareToPlay), never from processBlock.
    void Reset (double hostSampleRate, int maxBlockSize)
    {
        mHostSampleRate = hostSampleRate;

        double modelSampleRate = mExpectedSampleRate;
        if (modelSampleRate <= 0.0)          // model didn't declare its rate
            modelSampleRate = hostSampleRate; // assume it matches the host

        mBypass = std::abs (modelSampleRate - hostSampleRate) < 1.0;

        if (mBypass)
        {
            mResampler.reset();
            mEncapsulated->Reset (hostSampleRate, maxBlockSize);
            mLatency = 0;
        }
        else
        {
            mResampler = std::make_unique<dsp::ResamplingContainer<NAM_SAMPLE, 1, 12>> (modelSampleRate);
            mResampler->Reset (hostSampleRate, maxBlockSize);

            // Worst-case number of frames the model sees per block at its own SR.
            const int maxModelBlock =
                (int) std::ceil ((double) maxBlockSize * modelSampleRate / hostSampleRate) + 1;
            mEncapsulated->Reset (modelSampleRate, maxModelBlock);

            mLatency = mResampler->GetLatency();
        }
    }

    // Mono in / mono out, NAM_SAMPLE (== float here). input/output are
    // channel-pointer arrays of size 1.
    void process (NAM_SAMPLE** input, NAM_SAMPLE** output, int numFrames)
    {
        if (mBypass || mResampler == nullptr)
        {
            mEncapsulated->process (input, output, numFrames);
        }
        else
        {
            mResampler->ProcessBlock (input, output, numFrames,
                [this] (NAM_SAMPLE** ins, NAM_SAMPLE** outs, int n)
                {
                    mEncapsulated->process (ins, outs, n);
                });
        }
    }

    // Reported plugin latency (resampler group delay; 0 when SR matches).
    int  GetLatency() const            { return mLatency; }

    bool   HasLoudness() const         { return mEncapsulated && mEncapsulated->HasLoudness(); }
    double GetLoudness() const         { return mEncapsulated->GetLoudness(); }
    bool   HasInputLevel() const       { return mEncapsulated && mEncapsulated->HasInputLevel(); }
    double GetInputLevel() const       { return mEncapsulated->GetInputLevel(); }
    bool   HasOutputLevel() const      { return mEncapsulated && mEncapsulated->HasOutputLevel(); }
    double GetOutputLevel() const      { return mEncapsulated->GetOutputLevel(); }
    double GetExpectedSampleRate() const { return mExpectedSampleRate; }

    // ----- A2 "slimmable" quality / efficiency control -----------------------
    // Returns nullptr for non-slimmable (A1) models. SetSlimmableSize is
    // thread-safe but NOT real-time safe, so callers must drive it from the
    // message thread, never from processBlock.
    nam::SlimmableModel* GetSlimmableModel()
    {
        return dynamic_cast<nam::SlimmableModel*> (mEncapsulated.get());
    }
    bool IsSlimmable() { return GetSlimmableModel() != nullptr; }

    // size: 0 = max efficiency (lite) .. 1 = max quality (full). No-op for A1.
    void SetQuality (double size)
    {
        if (auto* s = GetSlimmableModel())
            s->SetSlimmableSize (size);
    }

private:
    std::unique_ptr<nam::DSP> mEncapsulated;
    std::unique_ptr<dsp::ResamplingContainer<NAM_SAMPLE, 1, 12>> mResampler;

    double mExpectedSampleRate = -1.0;
    double mHostSampleRate     = 0.0;
    bool   mBypass             = true;
    int    mLatency            = 0;
};
