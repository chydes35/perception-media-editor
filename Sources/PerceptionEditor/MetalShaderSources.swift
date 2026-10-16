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

    """
}
