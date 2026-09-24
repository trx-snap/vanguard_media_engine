// VGGreenScreenBackgroundProvider.h
// vanguard_media_engine — UMF camera graph green screen: static background source
//
// The VGGreenScreenBackgroundProvider interface is declared in
// VGGreenScreenFilterNode.h and its @implementation is inlined in
// VGGreenScreenFilterNode.m (the same translation-unit policy as
// VGStillImageFilterFactory): the CocoaPods umbrella / module map only knows
// the public headers present at the last `pod install`, so importing a
// brand-new header from VGGreenScreenFilterNode.h breaks the Swift module
// build until the Pods project is regenerated. This file is intentionally a
// comment-only pointer; promote the declarations here when that happens.
//
// Import VGGreenScreenFilterNode.h to use the provider.
