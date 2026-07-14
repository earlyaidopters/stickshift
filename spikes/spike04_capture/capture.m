// Spike 4: in-process ScreenCaptureKit capture of a target window + Vision OCR,
// measuring capture -> recognition latency against the 150ms frame-age gate.
// This is the FALLBACK state source (Warp uses AX text per spikes 2/3); it must
// work for terminals that don't expose AX text and for splits.
//
// Build: clang -fobjc-arc -framework AppKit -framework ScreenCaptureKit \
//        -framework CoreMedia -framework Vision -framework CoreImage capture.m -o capture
#import <AppKit/AppKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <Vision/Vision.h>
#import <mach/mach_time.h>

static double ms(uint64_t a, uint64_t b){ static mach_timebase_info_data_t t; if(!t.denom)mach_timebase_info(&t); return (double)(b-a)*t.numer/t.denom/1e6; }

int main(int argc, char **argv) {
    @autoreleasepool {
        pid_t target = argc > 1 ? (pid_t)atoi(argv[1]) : 0;
        // Establish a WindowServer/CGS connection (required before SCScreenshotManager
        // capture from a bare CLI, else CGS_REQUIRE_INIT asserts).
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        __block SCShareableContent *content = nil;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *c, NSError *e){
            content = c; dispatch_semaphore_signal(sem);
        }];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC));
        if (!content) { printf("SCShareableContent nil (screen-record TCC?)\n"); return 1; }

        SCWindow *win = nil;
        for (SCWindow *w in content.windows) {
            if (w.owningApplication.processID == target && w.onScreen && w.frame.size.height > 200) {
                if (!win || w.frame.size.width*w.frame.size.height > win.frame.size.width*win.frame.size.height) win = w;
            }
        }
        if (!win) { printf("no on-screen window for pid %d\n", target); return 1; }
        printf("target window: title=%s frame=%.0fx%.0f\n",
               win.title.UTF8String ?: "?", win.frame.size.width, win.frame.size.height);

        SCContentFilter *filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:win];
        SCStreamConfiguration *cfg = [[SCStreamConfiguration alloc] init];
        CGFloat scale = NSScreen.mainScreen.backingScaleFactor;
        cfg.width = (size_t)(win.frame.size.width * scale);
        cfg.height = (size_t)(win.frame.size.height * scale);
        cfg.showsCursor = NO;

        // capture 3 frames, measure capture + OCR (full window and bottom-strip crop)
        for (int i = 0; i < 3; i++) {
            uint64_t t0 = mach_absolute_time();
            __block CGImageRef img = NULL;
            dispatch_semaphore_t s2 = dispatch_semaphore_create(0);
            [SCScreenshotManager captureImageWithFilter:filter configuration:cfg
                completionHandler:^(CGImageRef image, NSError *e){
                    if (image) img = CGImageRetain(image);
                    dispatch_semaphore_signal(s2);
                }];
            dispatch_semaphore_wait(s2, dispatch_time(DISPATCH_TIME_NOW, 3*NSEC_PER_SEC));
            uint64_t t1 = mach_absolute_time();
            if (!img) { printf("frame %d: capture failed\n", i); continue; }

            // crop bottom 25% (where the input+status line live)
            size_t W = CGImageGetWidth(img), H = CGImageGetHeight(img);
            CGRect crop = CGRectMake(0, H*0.75, W, H*0.25);
            CGImageRef cropImg = CGImageCreateWithImageInRect(img, crop);

            for (int pass = 0; pass < 2; pass++) {
                CGImageRef use = pass == 0 ? img : cropImg;
                const char *label = pass == 0 ? "full" : "crop";
                uint64_t o0 = mach_absolute_time();
                VNImageRequestHandler *h = [[VNImageRequestHandler alloc] initWithCGImage:use options:@{}];
                VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc] init];
                req.recognitionLevel = VNRequestTextRecognitionLevelFast;
                req.usesLanguageCorrection = NO;
                [h performRequests:@[req] error:nil];
                uint64_t o1 = mach_absolute_time();
                NSMutableArray *lines = [NSMutableArray array];
                for (VNRecognizedTextObservation *ob in req.results) {
                    VNRecognizedText *tx = [[ob topCandidates:1] firstObject];
                    if (tx.string.length) [lines addObject:tx.string];
                }
                double cap = ms(t0,t1), ocr = ms(o0,o1);
                printf("frame %d %-4s: capture=%.1fms ocr_fast=%.1fms total=%.1fms lines=%lu %s\n",
                       i, label, cap, ocr, cap+ocr, (unsigned long)lines.count,
                       (cap+ocr) <= 150 ? "<=150 OK" : ">150 OVER");
                if (i == 0 && pass == 1) {
                    printf("  crop sample: ");
                    for (NSString *l in [lines subarrayWithRange:NSMakeRange(0, MIN(4,lines.count))])
                        printf("[%s] ", [l substringToIndex:MIN(30,l.length)].UTF8String);
                    printf("\n");
                }
            }
            if (cropImg) CGImageRelease(cropImg);
            CGImageRelease(img);
        }
    }
    return 0;
}
