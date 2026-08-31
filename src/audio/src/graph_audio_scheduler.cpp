#include "vanguard/audio/graph_audio_scheduler.h"

#include "vanguard/audio/decoded_audio_pcm_source_node.h"

#include <utility>

namespace vanguard {
namespace audio {

const std::string GraphAudioScheduler::kEmptySourceId;

GraphAudioScheduler::GraphAudioScheduler(
    const graph::Graph& graph,
    std::string targetMixNodeId,
    const std::unordered_map<std::string, AudioSampleProvider*>& providers)
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
        routedSources_.push_back(RoutedSource{c.fromNodeId, it->second});
    }
}

GraphAudioScheduler::GraphAudioScheduler(
    const graph::Graph& graph,
    std::string targetMixNodeId,
    AutoDiscoverSourceProviders)
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
        routedSources_.push_back(RoutedSource{c.fromNodeId, provider});
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

    const uint64_t windowPtsUs = ComputeWindowPtsUs(startFrame, sampleRate_);

    size_t mixTracksUsed = 0;
    size_t routedIndex   = 0;
    for (const RoutedSource& routed : routedSources_) {
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

        AudioMixBusNode::MixTrack& track = mixTracksScratch_[mixTracksUsed];
        track.pcm          = buffer.pcm;
        track.frameCount   = buffer.framesWritten;
        track.sampleRate   = sampleRate_;
        track.channelCount = channelCount_;
        track.gain         = 1.0; // Unit gain: scheduler exposes no gain API.
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
        outResult->framesRendered   = mixOutput.framesMixed;
        outResult->checksum         = mixOutput.checksum;
        outResult->routedTrackCount = mixTracksUsed;
        outResult->mixCalled        = true;
        outResult->silence          = false;
    }

    return SchedulerResult::kOk;
}

} // namespace audio
} // namespace vanguard
