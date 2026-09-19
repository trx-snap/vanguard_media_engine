// VGGreenScreenFilterNode.m
// Implementation intentionally lives in VGCameraGraphSession.m while the
// generated Pods projects enumerate dev-pod sources explicitly (a file added
// after the last `pod install` is not compiled or linked until the Pods
// project is regenerated, and Pods regeneration is outside this slice).
// Same precedent as VGOfflineFilterBundle.m, VGStillImageFilterFactory.m and
// VGLiveGreenScreenVisionMaskProvider.m.
//
// This file is deliberately comment-only: the podspec globs
// Classes/**/*.{swift,h,m,mm}, so a later Pods regeneration will compile it,
// and it must never define VGGreenScreenFilterNode (or any other symbol) a
// second time. Do not add code here without first moving the implementation
// out of VGCameraGraphSession.m.
