// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

/// Metal shading language source, compiled at run time.
///
/// Kept as a string because SwiftPM's command-line build does not compile `.metal` files, and the
/// package has to build and test with `swift test` on a clean checkout.
enum Shaders {
    static let vertexFunction = "marionette_quad_vertex"
    static let frameFragmentFunction = "marionette_frame_fragment"
    static let cursorFragmentFunction = "marionette_cursor_fragment"

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct QuadUniforms {
        float4 rect;     // left, top, right, bottom in normalised device coordinates
        float4 options;  // x > 0.5: average four taps (used when the image is drawn smaller than it is)
                         // y > 0.5: the image is PQ-encoded; otherwise sRGB-encoded
                         // z > 0.5: the target is PQ-encoded; otherwise sRGB-encoded
                         // w: SDR white in the PQ encoding, in nits
    };

    // sRGB's transfer function, both ways.
    static float3 srgb_to_linear(float3 c) {
        return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
    }

    static float3 linear_to_srgb(float3 c) {
        return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308);
    }

    // SMPTE ST 2084 (PQ), both ways, with 1.0 linear meaning 10 000 nits.
    constant float pq_m1 = 2610.0 / 16384.0;
    constant float pq_m2 = 2523.0 / 4096.0 * 128.0;
    constant float pq_c1 = 3424.0 / 4096.0;
    constant float pq_c2 = 2413.0 / 4096.0 * 32.0;
    constant float pq_c3 = 2392.0 / 4096.0 * 32.0;

    static float3 pq_to_linear(float3 e) {
        float3 p = pow(max(e, 0.0), 1.0 / pq_m2);
        return pow(max(p - pq_c1, 0.0) / (pq_c2 - pq_c3 * p), 1.0 / pq_m1);
    }

    static float3 linear_to_pq(float3 y) {
        float3 p = pow(max(y, 0.0), pq_m1);
        return pow((pq_c1 + pq_c2 * p) / (1.0 + pq_c3 * p), pq_m2);
    }

    // Re-encodes a colour for the target when the two encodings differ. SDR white sits at
    // `options.w` nits in PQ; PQ above it is clipped on the way to sRGB.
    static float3 to_target(float3 c, float4 options) {
        bool fromPQ = options.y > 0.5;
        bool toPQ = options.z > 0.5;
        if (fromPQ == toPQ) {
            return c;
        }
        if (toPQ) {
            return linear_to_pq(srgb_to_linear(saturate(c)) * (options.w / 10000.0));
        }
        return linear_to_srgb(saturate(pq_to_linear(c) * (10000.0 / options.w)));
    }

    struct QuadVaryings {
        float4 position [[position]];
        float2 uv;
    };

    vertex QuadVaryings marionette_quad_vertex(uint vertexID [[vertex_id]],
                                        constant QuadUniforms &uniforms [[buffer(0)]]) {
        float2 corner = float2(float(vertexID & 1), float((vertexID >> 1) & 1));
        QuadVaryings out;
        out.position = float4(mix(uniforms.rect.x, uniforms.rect.z, corner.x),
                              mix(uniforms.rect.y, uniforms.rect.w, corner.y),
                              0.0, 1.0);
        out.uv = corner;
        return out;
    }

    // The remote display. Always opaque: the alpha byte of a framebuffer carries no meaning.
    fragment float4 marionette_frame_fragment(QuadVaryings in [[stage_in]],
                                       constant QuadUniforms &uniforms [[buffer(0)]],
                                       texture2d<float> image [[texture(0)]],
                                       sampler imageSampler [[sampler(0)]]) {
        float2 dx = dfdx(in.uv) * 0.25;
        float2 dy = dfdy(in.uv) * 0.25;
        float4 colour;
        if (uniforms.options.x > 0.5) {
            // Zero-copy surfaces have no mipmaps. Four bilinear taps spread over the output pixel
            // cover up to a 4 x 4 block of source pixels, which keeps small text legible when a
            // large desktop is fitted onto a phone.
            colour = 0.25 * (image.sample(imageSampler, in.uv - dx - dy)
                           + image.sample(imageSampler, in.uv + dx - dy)
                           + image.sample(imageSampler, in.uv - dx + dy)
                           + image.sample(imageSampler, in.uv + dx + dy));
        } else {
            colour = image.sample(imageSampler, in.uv);
        }
        return float4(to_target(colour.rgb, uniforms.options), 1.0);
    }

    // The pointer, sRGB-encoded. Premultiplied alpha in, premultiplied alpha out.
    fragment float4 marionette_cursor_fragment(QuadVaryings in [[stage_in]],
                                        constant QuadUniforms &uniforms [[buffer(0)]],
                                        texture2d<float> image [[texture(0)]],
                                        sampler imageSampler [[sampler(0)]]) {
        float4 colour = image.sample(imageSampler, in.uv);
        if (uniforms.options.z < 0.5 || colour.a <= 0.0) {
            return colour;
        }
        return float4(to_target(colour.rgb / colour.a, uniforms.options) * colour.a, colour.a);
    }
    """
}

/// Mirrors `QuadUniforms` in the shader source.
struct QuadUniforms {
    var rect: SIMD4<Float>
    var options: SIMD4<Float> = .zero

    /// Sets the encodings of the image and of the target (`options.y`, `options.z`, `options.w`).
    mutating func setEncodings(imageIsPQ: Bool, targetIsPQ: Bool) {
        options.y = imageIsPQ ? 1 : 0
        options.z = targetIsPQ ? 1 : 0
        options.w = Float(RenderCore.referenceWhiteNits)
    }
}
