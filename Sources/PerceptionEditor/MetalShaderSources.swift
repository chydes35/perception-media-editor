/// Metal source compiled at run time. The Command Line Tools have no `metal` compiler, so shaders
/// ship as strings and are built with `MTLDevice.makeLibrary(source:options:)` on first use.
///
/// The parameter structs here mirror `DecodeParameters` and `EncodeParameters` in
/// `VideoColorKernels.swift`: every field is a 4-byte float, so there is no padding to get wrong.
enum MetalShaderSources {
    static let videoColor = """
    #include <metal_stdlib>
    using namespace metal;

    struct DecodeParameters {
        float codeScale;      // unorm sample -> integer code (255 for 8-bit, 65535/64 for 10 bits in the top of 16)
        float yOffset;        // Y' = (code - yOffset) / yScale
        float yScale;
        float cOffset;        // C = (code - cOffset) / cScale
        float cScale;
        float kr;             // luma coefficients of the matrix
        float kb;
        float chromaSubX;     // luma pixels per chroma sample, 1 or 2
        float chromaSubY;
        float sitingX;        // luma pixels from the first luma pixel of a pair to the chroma sample
        float sitingY;
    };

    struct EncodeParameters {
        float kr;
        float kb;
        float yOffset;        // code = offset + value * scale
        float yScale;
        float cOffset;
        float cScale;
        float minCode;
        float maxCode;
        float unormPerCode;   // 64 / 65535 for 10 bits stored in the top of 16
    };

    /// Y'CbCr code values in two planes to R'G'B' half float. The result is not clamped, so
    /// super-white and out-of-gamut values survive for the grade.
    kernel void decodeYCbCr(
        texture2d<float, access::read> luma [[texture(0)]],
        texture2d<float, access::read> chroma [[texture(1)]],
        texture2d<half, access::write> output [[texture(2)]],
        constant DecodeParameters &p [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= output.get_width() || gid.y >= output.get_height()) { return; }

        float yCode = round(luma.read(gid).r * p.codeScale);

        // Bilinear chroma, in chroma-sample coordinates.
        float2 position = (float2(gid) - float2(p.sitingX, p.sitingY)) / float2(p.chromaSubX, p.chromaSubY);
        float2 base = floor(position);
        float2 f = position - base;
        int2 low = int2(base);
        int2 maxIndex = int2(chroma.get_width() - 1, chroma.get_height() - 1);
        int2 a = clamp(low, int2(0), maxIndex);
        int2 b = clamp(low + int2(1), int2(0), maxIndex);
        float2 c00 = round(chroma.read(uint2(a.x, a.y)).rg * p.codeScale);
        float2 c10 = round(chroma.read(uint2(b.x, a.y)).rg * p.codeScale);
        float2 c01 = round(chroma.read(uint2(a.x, b.y)).rg * p.codeScale);
        float2 c11 = round(chroma.read(uint2(b.x, b.y)).rg * p.codeScale);
        float2 c = mix(mix(c00, c10, f.x), mix(c01, c11, f.x), f.y);

        float y = (yCode - p.yOffset) / p.yScale;
        float cb = (c.x - p.cOffset) / p.cScale;
        float cr = (c.y - p.cOffset) / p.cScale;
        float r = y + 2.0 * (1.0 - p.kr) * cr;
        float b2 = y + 2.0 * (1.0 - p.kb) * cb;
        float g = (y - p.kr * r - p.kb * b2) / (1.0 - p.kr - p.kb);
        output.write(half4(half(r), half(g), half(b2), half(1.0)), gid);
    }

    inline float3 rgbToYCbCr(float3 rgb, constant EncodeParameters &p) {
        float y = p.kr * rgb.r + (1.0 - p.kr - p.kb) * rgb.g + p.kb * rgb.b;
        return float3(y, (rgb.b - y) / (2.0 * (1.0 - p.kb)), (rgb.r - y) / (2.0 * (1.0 - p.kr)));
    }

    /// R'G'B' half float to the luma plane of video-range 10-bit Y'CbCr.
    kernel void encodeLuma(
        texture2d<half, access::read> input [[texture(0)]],
        texture2d<float, access::write> luma [[texture(1)]],
        constant EncodeParameters &p [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= luma.get_width() || gid.y >= luma.get_height()) { return; }
        float y = rgbToYCbCr(float3(input.read(gid).rgb), p).x;
        float code = clamp(round(p.yOffset + y * p.yScale), p.minCode, p.maxCode);
        luma.write(float4(code * p.unormPerCode, 0.0, 0.0, 1.0), gid);
    }

    /// R'G'B' half float to a co-sited 4:2:2 chroma plane: a 1-2-1 filter centered on every other pixel.
    kernel void encodeChroma422(
        texture2d<half, access::read> input [[texture(0)]],
        texture2d<float, access::write> chroma [[texture(1)]],
        constant EncodeParameters &p [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= chroma.get_width() || gid.y >= chroma.get_height()) { return; }
        int maxX = int(input.get_width()) - 1;
        int x = int(gid.x) * 2;
        float2 left = rgbToYCbCr(float3(input.read(uint2(clamp(x - 1, 0, maxX), gid.y)).rgb), p).yz;
        float2 center = rgbToYCbCr(float3(input.read(uint2(clamp(x, 0, maxX), gid.y)).rgb), p).yz;
        float2 right = rgbToYCbCr(float3(input.read(uint2(clamp(x + 1, 0, maxX), gid.y)).rgb), p).yz;
        float2 c = (left + 2.0 * center + right) * 0.25;
        float2 code = clamp(round(p.cOffset + c * p.cScale), p.minCode, p.maxCode);
        chroma.write(float4(code * p.unormPerCode, 0.0, 1.0), gid);
    }

    struct FitParameters {
        float a;              // upright point p -> stored point (a*p.x + c*p.y + tx, b*p.x + d*p.y + ty)
        float b;
        float c;
        float d;
        float tx;
        float ty;
        float orientedWidth;  // size of the upright frame, in stored pixels
        float orientedHeight;
    };

    /// Turns the image upright and scales it to fit the output with its aspect ratio kept, on black.
    kernel void fitToRenderSize(
        texture2d<half, access::sample> source [[texture(0)]],
        texture2d<half, access::write> output [[texture(1)]],
        constant FitParameters &p [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= output.get_width() || gid.y >= output.get_height()) { return; }
        float2 s = float2(source.get_width(), source.get_height());
        float2 o = float2(p.orientedWidth, p.orientedHeight);
        float2 d = float2(output.get_width(), output.get_height());
        float scale = min(d.x / o.x, d.y / o.y);
        float2 origin = (d - o * scale) * 0.5;
        float2 upright = (float2(gid) + 0.5 - origin) / scale;
        bool inside = all(upright >= float2(0.0)) && all(upright <= o);
        float2 stored = float2(p.a * upright.x + p.c * upright.y + p.tx, p.b * upright.x + p.d * upright.y + p.ty);
        constexpr sampler bilinear(filter::linear, address::clamp_to_edge, coord::normalized);
        half4 color = inside ? source.sample(bilinear, stored / s) : half4(0.0h, 0.0h, 0.0h, 1.0h);
        output.write(color, gid);
    }

    kernel void fillBlack(
        texture2d<half, access::write> output [[texture(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= output.get_width() || gid.y >= output.get_height()) { return; }
        output.write(half4(0.0h, 0.0h, 0.0h, 1.0h), gid);
    }


    // MARK: Scopes

    /// Averages a 4×4 grid of bilinear taps over each output pixel's footprint, so a 4K frame
    /// shrinks to scope size without skipping fine detail.
    kernel void downsampleForScope(
        texture2d<half, access::sample> source [[texture(0)]],
        texture2d<half, access::write> output [[texture(1)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= output.get_width() || gid.y >= output.get_height()) { return; }
        float2 s = float2(source.get_width(), source.get_height());
        float2 scale = s / float2(output.get_width(), output.get_height());
        constexpr sampler bilinear(filter::linear, address::clamp_to_edge, coord::normalized);
        float3 sum = float3(0.0);
        for (int j = 0; j < 4; j++) {
            for (int i = 0; i < 4; i++) {
                float2 p = (float2(gid) + (float2(i, j) + 0.5) / 4.0) * scale;
                sum += float3(source.sample(bilinear, p / s).rgb);
            }
        }
        output.write(half4(half3(sum / 16.0), 1.0h), gid);
    }

    struct ScopeParameters {
        float kr;
        float kb;
        uint columns;   // waveform columns, or the vectorscope's side
        uint bins;      // waveform bins (code values 0…bins-1)
        uint mode;      // 0 luma, 1 RGB parade
    };

    kernel void waveformAccumulate(
        texture2d<half, access::read> image [[texture(0)]],
        device atomic_uint *histogram [[buffer(0)]],
        constant ScopeParameters &p [[buffer(1)]],
        uint2 gid [[thread_position_in_grid]])
    {
        uint width = image.get_width();
        if (gid.x >= width || gid.y >= image.get_height()) { return; }
        float3 c = float3(image.read(gid).rgb);
        float top = float(p.bins - 1);
        if (p.mode == 0) {
            float y = p.kr * c.r + (1.0 - p.kr - p.kb) * c.g + p.kb * c.b;
            uint column = gid.x * p.columns / width;
            uint bin = uint(clamp(round(y * top), 0.0, top));
            atomic_fetch_add_explicit(&histogram[column * p.bins + bin], 1u, memory_order_relaxed);
        } else {
            uint panel = p.columns / 3;
            uint column = gid.x * panel / width;
            for (uint channel = 0; channel < 3; channel++) {
                uint bin = uint(clamp(round(c[channel] * top), 0.0, top));
                atomic_fetch_add_explicit(&histogram[(channel * panel + column) * p.bins + bin], 1u, memory_order_relaxed);
            }
        }
    }

    // Counts into a threadgroup-local histogram first, so flat regions don't all contend on one global bin.
    kernel void histogramAccumulate(
        texture2d<half, access::read> image [[texture(0)]],
        device atomic_uint *bins [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]],
        uint2 local2 [[thread_position_in_threadgroup]],
        uint2 group2 [[threads_per_threadgroup]])
    {
        uint lid = local2.y * group2.x + local2.x;
        uint groupSize = group2.x * group2.y;
        threadgroup atomic_uint local[768];
        for (uint i = lid; i < 768; i += groupSize) { atomic_store_explicit(&local[i], 0u, memory_order_relaxed); }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (gid.x < image.get_width() && gid.y < image.get_height()) {
            float3 c = float3(image.read(gid).rgb);
            for (uint channel = 0; channel < 3; channel++) {
                uint bin = uint(clamp(round(c[channel] * 255.0), 0.0, 255.0));
                atomic_fetch_add_explicit(&local[channel * 256 + bin], 1u, memory_order_relaxed);
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint i = lid; i < 768; i += groupSize) {
            uint count = atomic_load_explicit(&local[i], memory_order_relaxed);
            if (count > 0) { atomic_fetch_add_explicit(&bins[i], count, memory_order_relaxed); }
        }
    }

    kernel void vectorscopeAccumulate(
        texture2d<half, access::read> image [[texture(0)]],
        device atomic_uint *grid [[buffer(0)]],
        constant ScopeParameters &p [[buffer(1)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= image.get_width() || gid.y >= image.get_height()) { return; }
        float3 c = float3(image.read(gid).rgb);
        float y = p.kr * c.r + (1.0 - p.kr - p.kb) * c.g + p.kb * c.b;
        float cb = (c.b - y) / (2.0 * (1.0 - p.kb));
        float cr = (c.r - y) / (2.0 * (1.0 - p.kr));
        float top = float(p.columns - 1);
        uint u = uint(clamp(round((cb + 0.5) * top), 0.0, top));
        uint v = uint(clamp(round((0.5 - cr) * top), 0.0, top));
        atomic_fetch_add_explicit(&grid[v * p.columns + u], 1u, memory_order_relaxed);
    }

    struct ScopeRenderParameters {
        uint columns;
        uint bins;
        uint mode;
        float gain;     // a count that shows at full brightness (log scale)
    };

    /// Columns become x; bins become y, highest code at the top. Guides at code values 0, 64, 512,
    /// 940 and 1023 (black, video black, middle, video white, full scale).
    kernel void renderWaveform(
        device const uint *histogram [[buffer(0)]],
        constant ScopeRenderParameters &p [[buffer(1)]],
        texture2d<float, access::write> output [[texture(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        uint height = output.get_height();
        if (gid.x >= output.get_width() || gid.y >= height) { return; }
        uint column = gid.x * p.columns / output.get_width();
        uint binsPerRow = max(1u, p.bins / height);
        uint low = (height - 1 - gid.y) * binsPerRow;
        uint count = 0;
        bool guide = false;
        for (uint b = low; b < low + binsPerRow; b++) {
            count += histogram[column * p.bins + b];
            guide = guide || b == 0 || b == 64 || b == 512 || b == 940 || b == p.bins - 1;
        }
        float intensity = clamp(log2(1.0 + float(count)) / log2(1.0 + p.gain), 0.0, 1.0);
        float3 tint = float3(1.0);
        if (p.mode == 1) {
            uint panel = column * 3 / p.columns;
            tint = panel == 0 ? float3(1.0, 0.35, 0.3) : (panel == 1 ? float3(0.35, 1.0, 0.4) : float3(0.4, 0.55, 1.0));
        }
        float3 color = tint * intensity;
        if (guide) { color = max(color, float3(0.28)); }
        output.write(float4(color, 1.0), gid);
    }

    /// `targets` holds the 75% and 100% bar positions in bins; `skin` is the skin-tone direction.
    kernel void renderVectorscope(
        device const uint *grid [[buffer(0)]],
        constant ScopeRenderParameters &p [[buffer(1)]],
        constant float2 *targets [[buffer(2)]],
        constant float2 &skin [[buffer(3)]],
        texture2d<float, access::write> output [[texture(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        uint size = p.columns;
        if (gid.x >= size || gid.y >= size) { return; }
        float intensity = clamp(log2(1.0 + float(grid[gid.y * size + gid.x])) / log2(1.0 + p.gain), 0.0, 1.0);
        float3 color = float3(0.45, 1.0, 0.55) * intensity;
        float2 pixel = float2(gid);
        float2 center = float2(float(size - 1) * 0.5);
        float2 offset = pixel - center;
        float line = 0.0;
        // Crosshair, the skin-tone line, and a box around each bar target.
        if (abs(offset.x) < 0.5 || abs(offset.y) < 0.5) { line = 0.12; }
        float along = dot(offset, skin);
        if (along > 0.0 && length(offset - along * skin) < 0.7) { line = max(line, 0.3); }
        for (int t = 0; t < 12; t++) {
            float2 d = abs(pixel - targets[t]);
            float half_ = t < 6 ? 5.0 : 7.0;
            if (max(d.x, d.y) <= half_ && max(d.x, d.y) > half_ - 1.0) { line = max(line, t < 6 ? 0.5 : 0.3); }
        }
        output.write(float4(max(color, float3(line)), 1.0), gid);
    }
    """
}
