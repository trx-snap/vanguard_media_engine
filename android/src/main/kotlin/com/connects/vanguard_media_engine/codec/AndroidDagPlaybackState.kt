package com.connects.vanguard_media_engine.codec

enum class AndroidDagPlaybackState {
    Idle,
    Preparing,
    Prepared,
    Playing,
    Paused,
    Seeking,
    SurfaceLost,
    Backgrounded,
    Completed,
    Failed,
    Disposed,
}
