/* Local-only reference adapter, NOT linked to the editor.
 * Compile against pinned external vid.stab sources; retain their license notices.
 * FFmpeg supplies identical diagnostic YUV420 frames; this calls the same public
 * detection/smoothing/transform APIs used by the FFmpeg filters. It is not a test
 * of FFmpeg's filter wrapper, native 10-bit support, HDR, or VFR frame mapping.
 */
#include "libvidstab.h"
#include <fcntl.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>

static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
static void check(int ok, const char *message) { if (!ok) { fprintf(stderr, "%s\n", message); exit(1); } }
static FILE *exclusive(const char *path) {
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
    check(fd >= 0, "Refusing existing/inaccessible reference output");
    FILE *file = fdopen(fd, "wb"); check(file != NULL, "fdopen failed"); return file;
}

int main(int argc, char **argv) {
    check(argc == 7, "Usage: reference INPUT.yuv NEW_OUTPUT.yuv NEW_REPORT.json WIDTH HEIGHT SMOOTHING_FRAMES");
    int width = atoi(argv[4]), height = atoi(argv[5]), smoothing = atoi(argv[6]);
    check(width >= 64 && height >= 64 && width <= 960 && height <= 960 && width % 2 == 0 && height % 2 == 0,
          "Invalid diagnostic dimensions");
    check(smoothing > 0 && smoothing <= 120, "Invalid smoothing");
    FILE *input = fopen(argv[1], "rb"); check(input != NULL, "Cannot read derivative input");
    size_t bytes = (size_t)width * height * 3 / 2;
    check(fseek(input, 0, SEEK_END) == 0, "Input not seekable");
    long length = ftell(input);
    check(length > 0 && length % bytes == 0, "Truncated raw video");
    int count = (int)(length / bytes); check(count >= 3 && count <= 15000, "Unexpected frame count");
    rewind(input);
    FILE *output = exclusive(argv[2]); FILE *report = exclusive(argv[3]);
    uint8_t *pixels = malloc(bytes); check(pixels != NULL, "Out of memory");
    VSFrameInfo info; vsFrameInfoInit(&info, width, height, PF_YUV420P);
    VSFrame source, destination; vsFrameNull(&source); vsFrameNull(&destination);
    vsFrameFillFromBuffer(&source, pixels, &info); vsFrameAllocate(&destination, &info);
    VSMotionDetect detector;
    VSMotionDetectConfig detect = vsMotionDetectGetDefaultConfig("probe-reference");
    detect.shakiness = 5; detect.accuracy = 15; detect.numThreads = 1;
    check(vsMotionDetectInit(&detector, &detect, &info) == VS_OK, "Detection init failed");
    VSTransformData transform;
    VSTransformConfig config = vsTransformGetDefaultConfig("probe-reference");
    config.smoothing = smoothing; config.optZoom = 1; config.crop = VSCropBorder;
    config.interpolType = VS_BiLinear; config.camPathAlgo = VSGaussian;
    check(vsTransformDataInit(&transform, &config, &info, &info) == VS_OK, "Transform init failed");
    VSTransformations motions; vsTransformationsInit(&motions);
    motions.len = count; motions.ts = vs_malloc(sizeof(VSTransform) * count);
    check(motions.ts != NULL, "Motion allocation failed");
    double began = now();
    for (int i = 0; i < count; i++) {
        check(fread(pixels, 1, bytes, input) == bytes, "Input read failed");
        LocalMotions local;
        check(vsMotionDetection(&detector, &local, &source) == VS_OK, "Motion detection failed");
        motions.ts[i] = vsMotionsToTransform(&transform, &local, NULL);
        vs_vector_del(&local);
    }
    check(vsPreprocessTransforms(&transform, &motions) == VS_OK, "Smoothing failed");
    double analysis = now() - began;
    double maxZoom = 0;
    began = now(); rewind(input);
    for (int i = 0; i < count; i++) {
        check(fread(pixels, 1, bytes, input) == bytes, "Second input read failed");
        VSTransform motion = vsGetNextTransform(&transform, &motions);
        if (motion.zoom > maxZoom) maxZoom = motion.zoom;
        check(vsTransformPrepare(&transform, &source, &destination) == VS_OK, "Transform prepare failed");
        check(vsDoTransform(&transform, motion) == VS_OK, "Transform failed");
        check(vsTransformFinish(&transform) == VS_OK, "Transform finish failed");
        for (int plane = 0; plane < 3; plane++) {
            int w = plane == 0 ? width : width / 2, h = plane == 0 ? height : height / 2;
            for (int y = 0; y < h; y++)
                check(fwrite(destination.data[plane] + y * destination.linesize[plane], 1, w, output) == (size_t)w,
                      "Output write failed");
        }
    }
    struct rusage usage; getrusage(RUSAGE_SELF, &usage);
    fprintf(report, "{\"frames\":%d,\"analysisSeconds\":%.6f,\"transformSeconds\":%.6f,\"maximumZoomPercent\":%.6f,\"peakRSSMiB\":%.6f,\"smoothingFrames\":%d,\"version\":\"v1.1.1 tag 90c76aca2cb06c3ff6f7476a7cd6851b39436656\"}\n",
            count, analysis, now()-began, maxZoom, usage.ru_maxrss / 1048576.0, smoothing);
    check(fclose(output) == 0 && fclose(report) == 0, "Output close failed");
    fclose(input); vsMotionDetectionCleanup(&detector); vsTransformationsCleanup(&motions);
    vsTransformDataCleanup(&transform); vsFrameFree(&destination); free(pixels);
    return 0;
}
