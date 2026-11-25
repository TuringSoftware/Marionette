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
    };

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
        return float4(colour.rgb, 1.0);
    }

    // The pointer. Premultiplied alpha in, premultiplied alpha out.
    fragment float4 marionette_cursor_fragment(QuadVaryings in [[stage_in]],
                                        texture2d<float> image [[texture(0)]],
                                        sampler imageSampler [[sampler(0)]]) {
        return image.sample(imageSampler, in.uv);
    }
    """
}

/// Mirrors `QuadUniforms` in the shader source.
struct QuadUniforms {
    var rect: SIMD4<Float>
    var options: SIMD4<Float> = .zero
}
