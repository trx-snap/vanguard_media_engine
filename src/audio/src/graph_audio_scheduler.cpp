#include "vanguard/audio/graph_audio_scheduler.h"

#include "vanguard/audio/decoded_audio_pcm_source_node.h"

#include <limits>
#include <utility>

namespace vanguard {
namespace audio {

const std::string GraphAudioScheduler::kEmptySourceId;

GraphAudioScheduler::GraphAudioScheduler(
    const graph::Graph& graph,
    std::string targetMixNodeId,
    const std::unordered_map<std::string, AudioSampleProvider*>& providers,
    const std::unordered_map<std::string, SourceMixParams>* mixParams)
    : graph_(graph),
      targetMixNodeId_(std::move(targetMixNodeId)),
      snapshotGeneration_(graph.generationId()) {

    std::shared_ptr<graph::Node> targetNode = graph_.getNode(targetMixNodeId_);
    mixBus_ = std::dynamic_pointer_cast<AudioMixBusNode>(targetNode);
    targetValid_ = (mixBus_ != nullptr);

    if (targetValid_) {
        sampleRate_      = mixBus_->sampleRate();
        channelCount_    = mixBus_->channelCount();
        maxFramesPerMix_ = mixBus_->maxFramesPerMix();
    }

    perTrackStrideSamples_ =
        static_cast<int64_t>(maxFramesPerMix_) * static_cast<int64_t>(channelCount_);

    // Preallocate once; renderWindow() never resizes these.
    trackScratch_.assign(
        static_cast<size_t>(perTrackStrideSamples_) * kMaxRoutedTracks, 0);
    mixTracksScratch_.assign(kMaxRoutedTracks, AudioMixBusNode::MixTrack{});

    if (!targetValid_) {
        return;
    }

    std::vector<graph::Connection> conns;
    const core::Status connStatus = graph_.inputConnections(targetMixNodeId_, conns);
    if (!connStatus.ok()) {
        return;
    }

    const auto& mixInputPorts = mixBus_->inputPorts();
    for (const auto& c : conns) {
        bool portOk = false;
        for (const auto& p : mixInputPorts) {
            if (p.id == c.toPortId && p.dataType == graph::PortDataType::kAudioPacket) {
                portOk = true;
                break;
            }
        }
        if (!portOk) {
            continue;
        }
        auto it = providers.find(c.fromNodeId);
        if (it == providers.end() || it->second == nullptr) {
            continue; // No registered provider for this edge's source: not routed.
        }
        if (routedSources_.size() >= kMaxRoutedTracks) {
            break; // Bounded by the mix bus's own track-count ceiling.
        }
        // Cache the source node once so renderWindow() can gate on
        // Node::isActiveAt without a per-window graph lookup.
        std::shared_ptr<graph::Node> fromNode = graph_.getNode(c.fromNodeId);
        RoutedSource routed{c.fromNodeId, std::move(fromNode), it->second};
        // P4-AUDIO-SCHEDULER-ENVELOPE-WIRING: per-source static gain and
        // non-owning envelope resolved once here; no entry keeps the
        // unit-gain/null-envelope defaults.
        if (mixParams != nullptr) {
            auto paramsIt = mixParams->find(c.fromNodeId);
            if (paramsIt != mixParams->end()) {
                routed.gain     = paramsIt->second.gain;
                routed.envelope = paramsIt->second.envelope;
            }
        }
        routedSources_.push_back(std::move(routed));
    }
}

GraphAudioScheduler::GraphAudioScheduler(
    const graph::Graph& graph,
    std::string targetMixNodeId,
    AutoDiscoverSourceProviders,
    const std::unordered_map<std::string, SourceMixParams>* mixParams)
    : graph_(graph),
      targetMixNodeId_(std::move(targetMixNodeId)),
      snapshotGeneration_(graph.generationId()) {

    std::shared_ptr<graph::Node> targetNode = graph_.getNode(targetMixNodeId_);
    mixBus_ = std::dynamic_pointer_cast<AudioMixBusNode>(targetNode);
    targetValid_ = (mixBus_ != nullptr);

    if (targetValid_) {
        sampleRate_      = mixBus_->sampleRate();
        channelCount_    = mixBus_->channelCount();
        maxFramesPerMix_ = mixBus_->maxFramesPerMix();
    }

    perTrackStrideSamples_ =
        static_cast<int64_t>(maxFramesPerMix_) * static_cast<int64_t>(channelCount_);

    // Preallocate once; renderWindow() never resizes these.
    trackScratch_.assign(
        static_cast<size_t>(perTrackStrideSamples_) * kMaxRoutedTracks, 0);
    mixTracksScratch_.assign(kMaxRoutedTracks, AudioMixBusNode::MixTrack{});

    if (!targetValid_) {
        return;
    }

    std::vector<graph::Connection> conns;
    const core::Status connStatus = graph_.inputConnections(targetMixNodeId_, conns);
    if (!connStatus.ok()) {
        return;
    }

    const auto& mixInputPorts = mixBus_->inputPorts();
    for (const auto& c : conns) {
        bool portOk = false;
        for (const auto& p : mixInputPorts) {
            if (p.id == c.toPortId && p.dataType == graph::PortDataType::kAudioPacket) {
                portOk = true;
                break;
            }
        }
        if (!portOk) {
            continue;
        }
        std::shared_ptr<graph::Node> fromNode = graph_.getNode(c.fromNodeId);
        auto decodedSource =
            std::dynamic_pointer_cast<DecodedAudioPcmSourceNode>(fromNode);
        if (decodedSource == nullptr) {
            continue; // Missing or non-decoded-audio source node: not routed.
        }
        AudioSampleProvider* provider = decodedSource->audioSampleProvider();
        if (provider == nullptr) {
            continue; // Legacy 5-arg node owns no transport: not routed.
        }
        if (routedSources_.size() >= kMaxRoutedTracks) {
            break; // Bounded by the mix bus's own track-count ceiling.
        }
        RoutedSource routed{c.fromNodeId, fromNode, provider};
        // P4-AUDIO-SCHEDULER-ENVELOPE-WIRING: mix params stay keyed by
        // source node id even under auto-discovery; the node itself stores
        // no envelope.
        if (mixParams != nullptr) {
            auto paramsIt = mixParams->find(c.fromNodeId);
            if (paramsIt != mixParams->end()) {
                routed.gain     = paramsIt->second.gain;
                routed.envelope = paramsIt->second.envelope;
            }
        }
        routedSources_.push_back(std::move(routed));
    }
}

uint64_t GraphAudioScheduler::ComputeWindowPtsUs(int64_t startFrame, int32_t sampleRate) noexcept {
    if (sampleRate <= 0 || startFrame < 0) {
        return 0;
    }
    return (static_cast<uint64_t>(startFrame) * 1000000ULL) / static_cast<uint64_t>(sampleRate);
}

const std::string& GraphAudioScheduler::routedSourceIdAt(size_t index) const {
    if (index >= routedSources_.size()) {
        return kEmptySourceId;
    }
    return routedSources_[index].nodeId;
}

GraphAudioScheduler::SchedulerResult GraphAudioScheduler::renderWindow(
    int64_t startFrame,
    int64_t frameCount,
    int16_t* outPcm,
    int64_t outCapacitySamples,
    SchedulerOutput* outResult) noexcept {

    if (outResult != nullptr) {
        *outResult = SchedulerOutput{};
    }

    if (graph_.generationId() != snapshotGeneration_) {
        return SchedulerResult::kStaleGeneration;
    }
    if (!targetValid_) {
        return SchedulerResult::kInvalidTarget;
    }
    if (startFrame < 0 || frameCount <= 0 || frameCount > maxFramesPerMix_) {
        return SchedulerResult::kInvalidFrameCount;
    }
    const int64_t requiredOutputSamples = frameCount * static_cast<int64_t>(channelCount_);
    if (outPcm == nullptr || outCapacitySamples < requiredOutputSamples) {
        return SchedulerResult::kInsufficientCapacity;
    }

    // P4-AUDIO-SCHEDULER-ENVELOPE-WIRING: windowPtsUs is the scheduler-owned
    // window origin stamped into every MixTrack.envelopeStartPtsUs (int64).
    // Guard both the uint64 multiplication inside ComputeWindowPtsUs and the
    // int64 cast, failing closed before any provider call or output
    // mutation. startFrame is already known non-negative here.
    if (static_cast<uint64_t>(startFrame) >
        std::numeric_limits<uint64_t>::max() / 1000000ULL) {
        return SchedulerResult::kWindowPtsOverflow;
    }
    const uint64_t windowPtsUs = ComputeWindowPtsUs(startFrame, sampleRate_);
    if (windowPtsUs > static_cast<uint64_t>(std::numeric_limits<int64_t>::max())) {
        return SchedulerResult::kWindowPtsOverflow;
    }

    if (routedSources_.empty()) {
        for (int64_t i = 0; i < requiredOutputSamples; ++i) {
            outPcm[i] = 0;
        }
        if (outResult != nullptr) {
            outResult->framesRendered  = frameCount;
            outResult->routedTrackCount = 0;
            outResult->mixCalled       = false;
            outResult->silence         = true;
        }
        return SchedulerResult::kSilence;
    }

    size_t mixTracksUsed = 0;
    size_t routedIndex   = 0;
    for (const RoutedSource& routed : routedSources_) {
        // P4-AUDIO-SCHEDULER-TIMELINE-GATING: a source node reporting
        // inactive at this window's derived pts contributes no MixTrack,
        // exactly like a silent provider — skipped before provider format
        // checks and before provide(). A null cached node keeps the Node
        // default (always active). mapTimelineToLocalPts is deliberately
        // not consulted; the frame cursor stays authoritative.
        if (routed.node != nullptr && !routed.node->isActiveAt(windowPtsUs)) {
            continue;
        }
        if (routed.provider == nullptr) {
            return SchedulerResult::kProviderMissing;
        }
        if (routed.provider->sampleRate() != sampleRate_ ||
            routed.provider->channelCount() != channelCount_) {
            return SchedulerResult::kSampleRateMismatch;
        }

        AudioWindowRequest request{};
        request.startFrame     = startFrame;
        request.frameCount     = frameCount;
        request.sampleRate     = sampleRate_;
        request.channelCount   = channelCount_;
        request.timelinePtsUs  = windowPtsUs;

        AudioWindowBuffer buffer{};
        buffer.pcm             = trackScratch_.data() +
                                  static_cast<size_t>(routedIndex) * static_cast<size_t>(perTrackStrideSamples_);
        buffer.capacitySamples = perTrackStrideSamples_;
        buffer.framesWritten   = 0;
        buffer.silent          = false;
        ++routedIndex;

        const core::Status provideStatus = routed.provider->provide(request, buffer);
        if (!provideStatus.ok()) {
            return SchedulerResult::kProviderError;
        }

        if (buffer.silent) {
            // Silent provider buffers never become MixTrack entries.
            continue;
        }

        // Every MixTrack field is (re)populated on every use: the scratch
        // descriptors are reused across windows and must never leak a stale
        // gain/envelope from a previous window's track assignment.
        AudioMixBusNode::MixTrack& track = mixTracksScratch_[mixTracksUsed];
        track.pcm                = buffer.pcm;
        track.frameCount         = buffer.framesWritten;
        track.sampleRate         = sampleRate_;
        track.channelCount       = channelCount_;
        track.gain               = routed.gain;
        track.envelope           = routed.envelope;
        track.envelopeStartPtsUs = static_cast<int64_t>(windowPtsUs);
        ++mixTracksUsed;
    }

    if (mixTracksUsed == 0) {
        // Every routed provider reported silence for this window: bypass
        // mix() (it rejects trackCount==0) and report kSilence directly.
        for (int64_t i = 0; i < requiredOutputSamples; ++i) {
            outPcm[i] = 0;
        }
        if (outResult != nullptr) {
            outResult->framesRendered   = frameCount;
            outResult->routedTrackCount = 0;
            outResult->mixCalled        = false;
            outResult->silence          = true;
        }
        return SchedulerResult::kSilence;
    }

    AudioMixBusNode::MixOutput mixOutput{};
    const AudioMixBusNode::MixResult mixResult = mixBus_->mix(
        mixTracksScratch_.data(),
        mixTracksUsed,
        frameCount,
        outPcm,
        outCapacitySamples,
        &mixOutput);

    if (mixResult != AudioMixBusNode::MixResult::kOk) {
        return SchedulerResult::kMixFailure;
    }

    if (outResult != nullptr) {
        outResult->framesRendered      = mixOutput.framesMixed;
        outResult->checksum            = mixOutput.checksum;
        outResult->routedTrackCount    = mixTracksUsed;
        outResult->mixCalled           = true;
        outResult->silence             = false;
        outResult->envelopeApplied     = mixOutput.envelopeApplied;
        outResult->minEffectiveGain    = mixOutput.minEffectiveGain;
        outResult->maxEffectiveGain    = mixOutput.maxEffectiveGain;
        outResult->envelopeEvaluations = mixOutput.envelopeEvaluations;
    }

    return SchedulerResult::kOk;
}

} // namespace audio
} // namespace vanguard
