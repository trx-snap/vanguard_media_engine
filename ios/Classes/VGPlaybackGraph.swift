// VGPlaybackGraph.swift
// One AVFoundation playback graph for VGStreamingPlaybackCoordinator: the asset,
// the item with its video output, and the player. Ordinary playback
// infrastructure, independent of any experiment.
//
// Construction order is the coordinator's original one and is shared by the
// initial graph and a replacement: asset; output; item; attach output; item
// policy; player; player policy. The references are immutable; the session that
// owns the graph swaps the whole graph, never a part of it.
//
// retireForReplacement() is for a graph the session is replacing. Ordinary
// disposal keeps its own cleanup in the coordinator and never calls it.
//
// Threading: main thread only.

import AVFoundation
import Foundation

final class VGPlaybackGraph {

    let asset:       AVURLAsset
    let item:        AVPlayerItem
    let player:      AVPlayer
    let videoOutput: AVPlayerItemVideoOutput

    private(set) var isRetired = false

    private init(asset: AVURLAsset, item: AVPlayerItem, player: AVPlayer, videoOutput: AVPlayerItemVideoOutput) {
        self.asset       = asset
        self.item        = item
        self.player      = player
        self.videoOutput = videoOutput
    }

    /// Builds a graph for `url`. `assetOptions` are the AVURLAsset options; nil or
    /// empty passes none. The policy closures run synchronously: the item one right
    /// after the output is attached, the player one right after the player exists.
    static func build(
        url: URL,
        assetOptions: [String: Any]?,
        applyItemPolicy: (AVPlayerItem) -> Void,
        applyPlayerPolicy: (AVPlayer) -> Void
    ) -> VGPlaybackGraph {
        let options = (assetOptions?.isEmpty ?? true) ? nil : assetOptions
        let asset = AVURLAsset(url: url, options: options)
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: outputSettings)
        let item = AVPlayerItem(asset: asset)
        item.add(videoOutput)
        applyItemPolicy(item)
        let player = AVPlayer(playerItem: item)
        applyPlayerPolicy(player)
        return VGPlaybackGraph(asset: asset, item: item, player: player, videoOutput: videoOutput)
    }

    /// Stops this graph so another can take its place: pause, drop pending prerolls,
    /// remove the output and detach the item. Idempotent. Only for replacement; the
    /// coordinator's own disposal does not call it.
    func retireForReplacement() {
        guard !isRetired else { return }
        isRetired = true
        player.pause()
        player.cancelPendingPrerolls()
        item.remove(videoOutput)
        player.replaceCurrentItem(with: nil)
    }
}
