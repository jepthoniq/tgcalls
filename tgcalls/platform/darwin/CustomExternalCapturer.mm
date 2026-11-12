#include "CustomExternalCapturer.h"

#import <AVFoundation/AVFoundation.h>

#include "rtc_base/logging.h"
#import "base/RTCLogging.h"
#import "base/RTCVideoFrameBuffer.h"
#import "TGRTCCVPixelBuffer.h"
#import "sdk/objc/native/src/objc_video_track_source.h"
#import "sdk/objc/native/src/objc_frame_buffer.h"
//#import "api/video_track_source_proxy.h"

#import "helpers/UIDevice+RTCDevice.h"

#import "helpers/AVCaptureSession+DevicePosition.h"
#import "helpers/RTCDispatcher+Private.h"
#import "base/RTCVideoFrame.h"

#include "common_video/libyuv/include/webrtc_libyuv.h"
#include "rtc_base/checks.h"
#include "rtc_base/logging.h"
#include "third_party/libyuv/include/libyuv.h"
#include "pc/video_track_source_proxy.h"

#include "DarwinVideoSource.h"

#include <mutex>
#include <memory>
#include "api/video/video_sink_interface.h"
#include "api/video/video_frame.h"

static const int64_t kNanosecondsPerSecond = 1000000000;
static const int64_t kNanosecondsPerMicrosecond = 1000;

// Joker: the local outgoing view sink (set from the call screen via setUncroppedSink:).
// passPixelBuffer: is a class method and cannot see it, so it lives in one process-global slot
// (the app only broadcasts to one call at a time), guarded by a mutex.
static std::mutex &uncroppedSinkMutex() {
    static std::mutex mutex;
    return mutex;
}
static std::shared_ptr<rtc::VideoSinkInterface<webrtc::VideoFrame>> &uncroppedSinkStorage() {
    static std::shared_ptr<rtc::VideoSinkInterface<webrtc::VideoFrame>> storage;
    return storage;
}

static tgcalls::DarwinVideoTrackSource *getObjCVideoSource(const webrtc::scoped_refptr<webrtc::VideoTrackSourceInterface> nativeSource) {
    webrtc::VideoTrackSourceProxy *proxy_source =
    static_cast<webrtc::VideoTrackSourceProxy *>(nativeSource.get());
    return static_cast<tgcalls::DarwinVideoTrackSource *>(proxy_source->internal());
}

@interface CustomExternalCapturer () {
    webrtc::scoped_refptr<webrtc::VideoTrackSourceInterface> _source;
}

@end

@implementation CustomExternalCapturer

- (instancetype)initWithSource:(webrtc::scoped_refptr<webrtc::VideoTrackSourceInterface>)source {
    self = [super init];
    if (self != nil) {
        _source = source;
    }
    return self;
}

- (void)setUncroppedSink:(std::shared_ptr<rtc::VideoSinkInterface<webrtc::VideoFrame>>)sink {
    std::lock_guard<std::mutex> lock(uncroppedSinkMutex());
    uncroppedSinkStorage() = sink;
}

- (void)dealloc {
}

+ (void)passPixelBuffer:(CVPixelBufferRef)pixelBuffer sampleBufferReference:(CMSampleBufferRef)sampleBufferReference rotation:(RTCVideoRotation)rotation toSource:(webrtc::scoped_refptr<webrtc::VideoTrackSourceInterface>)source croppingBuffer:(std::vector<uint8_t> &)croppingBuffer {
    TGRTCCVPixelBuffer *rtcPixelBuffer = [[TGRTCCVPixelBuffer alloc] initWithPixelBuffer:pixelBuffer];
    if (sampleBufferReference) {
        [rtcPixelBuffer storeSampleBufferReference:sampleBufferReference];
    }
    rtcPixelBuffer.deviceRelativeVideoRotation = -1;

    int width = rtcPixelBuffer.width;
    int height = rtcPixelBuffer.height;

    width -= width % 4;
    height -= height % 4;

    if (width != rtcPixelBuffer.width || height != rtcPixelBuffer.height) {
        CVPixelBufferRef outputPixelBufferRef = NULL;
        OSType pixelFormat = CVPixelBufferGetPixelFormatType(rtcPixelBuffer.pixelBuffer);
        CVPixelBufferCreate(NULL, width, height, pixelFormat, NULL, &outputPixelBufferRef);
        if (outputPixelBufferRef) {
            int bufferSize = [rtcPixelBuffer bufferSizeForCroppingAndScalingToWidth:width height:height];
            if (croppingBuffer.size() < bufferSize) {
                croppingBuffer.resize(bufferSize);
            }
            if ([rtcPixelBuffer cropAndScaleTo:outputPixelBufferRef withTempBuffer:croppingBuffer.data()]) {
                rtcPixelBuffer = [[TGRTCCVPixelBuffer alloc] initWithPixelBuffer:outputPixelBufferRef];
                rtcPixelBuffer.deviceRelativeVideoRotation = -1;
            }
            CVPixelBufferRelease(outputPixelBufferRef);
        }
    }

    int64_t timeStampNs = CACurrentMediaTime() * kNanosecondsPerSecond;
    RTCVideoFrame *videoFrame = [[RTCVideoFrame alloc] initWithBuffer:(id<RTCVideoFrameBuffer>)[rtcPixelBuffer toI420] rotation:rotation timeStampNs:timeStampNs];

    getObjCVideoSource(source)->OnCapturedFrame(videoFrame);

    // Joker: mirror the frame to the local outgoing view, like the camera capturer does.
    std::shared_ptr<rtc::VideoSinkInterface<webrtc::VideoFrame>> sink;
    {
        std::lock_guard<std::mutex> lock(uncroppedSinkMutex());
        sink = uncroppedSinkStorage();
    }
    if (sink) {
        RTCVideoFrame *localFrame = [[RTCVideoFrame alloc] initWithBuffer:rtcPixelBuffer rotation:rotation timeStampNs:timeStampNs];
        webrtc::scoped_refptr<webrtc::VideoFrameBuffer> buffer = new rtc::RefCountedObject<webrtc::ObjCFrameBuffer>(localFrame.buffer);
        webrtc::VideoRotation localRotation = static_cast<webrtc::VideoRotation>(rotation);
        sink->OnFrame(webrtc::VideoFrame::Builder()
                .set_video_frame_buffer(buffer)
                .set_rotation(localRotation)
                .set_timestamp_us(timeStampNs / kNanosecondsPerMicrosecond)
                .build());
    }
}

@end
