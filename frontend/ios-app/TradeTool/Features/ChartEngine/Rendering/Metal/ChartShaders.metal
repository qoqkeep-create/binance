#include <metal_stdlib>
using namespace metal;

struct ChartCandleInstance {
    float4 geometry;
    float4 style;
};

struct ChartLineInstance {
    float4 geometry;
    float4 style;
    float4 color;
    float4 flags;
};

struct ChartBarInstance {
    float4 geometry;
    float4 color;
    float4 flags;
};

struct ChartGlyphInstance {
    float4 geometry;
    float4 uv;
    float4 color;
    float4 flags;
};

struct ChartUniforms {
    float2 viewportSize;
    float2 translationAndScale;
    float2 horizontalPlotBounds;
    float2 timelineBodyStyle;
    float4 positiveColor;
    float4 negativeColor;
};

struct ChartVertexOut {
    float4 position [[position]];
    float4 color;
    float pixelX;
    float2 horizontalClip;
};

vertex ChartVertexOut chartCandleVertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    const device ChartCandleInstance *instances [[buffer(0)]],
    constant ChartUniforms &uniforms [[buffer(1)]]
) {
    const ChartCandleInstance instance = instances[instanceID];
    const uint localVertex = vertexID % 6;
    const bool isWick = vertexID < 6;

    const float2 corners[6] = {
        float2(0.0, 0.0),
        float2(1.0, 0.0),
        float2(0.0, 1.0),
        float2(0.0, 1.0),
        float2(1.0, 0.0),
        float2(1.0, 1.0)
    };

    const bool appliesTimelineTransform = instance.style.w > 0.5;
    const float sourceX = appliesTimelineTransform
        ? instance.geometry.x
            * uniforms.translationAndScale.y
            + uniforms.translationAndScale.x
        : instance.geometry.x;
    const float openY = instance.geometry.y;
    const float highY = instance.geometry.z;
    const float lowY = instance.geometry.w;
    const float closeY = instance.style.x;
    const float horizontalScale = appliesTimelineTransform
        ? uniforms.translationAndScale.y
        : 1.0;
    const float transformedBodyHalfWidth =
        uniforms.timelineBodyStyle.x > 0.0
        ? uniforms.timelineBodyStyle.x
        : max(0.5, instance.style.y) * horizontalScale;
    const float halfWidth = isWick
        ? uniforms.timelineBodyStyle.y
        : transformedBodyHalfWidth;
    const float top = isWick
        ? min(highY, lowY)
        : min(openY, closeY);
    const float bottom = isWick
        ? max(highY, lowY)
        : max(top + 1.0, max(openY, closeY));

    const float2 corner = corners[localVertex];
    const float2 pixel = float2(
        mix(sourceX - halfWidth, sourceX + halfWidth, corner.x),
        mix(top, bottom, corner.y)
    );
    const float2 safeViewport = max(
        uniforms.viewportSize,
        float2(1.0)
    );
    const float2 clip = float2(
        pixel.x / safeViewport.x * 2.0 - 1.0,
        1.0 - pixel.y / safeViewport.y * 2.0
    );

    ChartVertexOut output;
    output.position = float4(clip, 0.0, 1.0);
    output.color = instance.style.z > 0.5
        ? uniforms.positiveColor
        : uniforms.negativeColor;
    output.pixelX = pixel.x;
    output.horizontalClip = appliesTimelineTransform
        ? uniforms.horizontalPlotBounds
        : float2(-1.0e20, 1.0e20);
    return output;
}

fragment float4 chartCandleFragment(
    ChartVertexOut input [[stage_in]]
) {
    if (input.pixelX < input.horizontalClip.x
        || input.pixelX > input.horizontalClip.y) {
        discard_fragment();
    }
    return input.color;
}

struct ChartLineVertexOut {
    float4 position [[position]];
    float4 color;
    float distanceAlong;
    float4 dash;
    float pixelX;
    float2 horizontalClip;
    float2 localPixel;
    float lineLength;
    float halfWidth;
    float antialias;
};

vertex ChartLineVertexOut chartLineVertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    const device ChartLineInstance *instances [[buffer(0)]],
    constant ChartUniforms &uniforms [[buffer(1)]]
) {
    const ChartLineInstance instance = instances[instanceID];
    const float2 corners[6] = {
        float2(0.0, -1.0),
        float2(1.0, -1.0),
        float2(0.0, 1.0),
        float2(0.0, 1.0),
        float2(1.0, -1.0),
        float2(1.0, 1.0)
    };

    float2 start = instance.geometry.xy;
    float2 end = instance.geometry.zw;
    const float timelineTransformMode = instance.flags.x;
    const bool appliesTimelineTransform = timelineTransformMode > 0.5;
    if (appliesTimelineTransform) {
        start.x = start.x
            * uniforms.translationAndScale.y
            + uniforms.translationAndScale.x;
        if (timelineTransformMode < 1.5) {
            end.x = end.x
                * uniforms.translationAndScale.y
                + uniforms.translationAndScale.x;
        }
    }

    const float2 delta = end - start;
    const float lineLength = max(length(delta), 0.001);
    const float2 direction = delta / lineLength;
    const float2 perpendicular = float2(
        -direction.y,
        direction.x
    );
    const float2 corner = corners[vertexID];
    const bool antialias = instance.flags.y > 0.5;
    const float halfWidth = max(0.5, instance.style.x * 0.5);
    // Expand the rasterized quad to include the one-pixel coverage fringe
    // and round caps. Caps also close the gaps at polyline joints.
    const float cap = antialias ? halfWidth + 0.5 : 0.0;
    const float along = mix(-cap, lineLength + cap, corner.x);
    const float across = corner.y * (halfWidth + (antialias ? 0.5 : 0.0));
    const float2 pixel = antialias
        ? start + direction * along + perpendicular * across
        : mix(start, end, corner.x) + perpendicular * corner.y * halfWidth;
    const float2 safeViewport = max(
        uniforms.viewportSize,
        float2(1.0)
    );

    ChartLineVertexOut output;
    output.position = float4(
        pixel.x / safeViewport.x * 2.0 - 1.0,
        1.0 - pixel.y / safeViewport.y * 2.0,
        0.0,
        1.0
    );
    output.color = instance.color;
    output.distanceAlong = antialias ? along : corner.x * lineLength;
    output.dash = instance.style;
    output.pixelX = pixel.x;
    output.horizontalClip = appliesTimelineTransform
        ? uniforms.horizontalPlotBounds
        : float2(-1.0e20, 1.0e20);
    output.localPixel = float2(along, across);
    output.lineLength = lineLength;
    output.halfWidth = halfWidth;
    output.antialias = antialias ? 1.0 : 0.0;
    return output;
}

fragment float4 chartLineFragment(
    ChartLineVertexOut input [[stage_in]]
) {
    if (input.pixelX < input.horizontalClip.x
        || input.pixelX > input.horizontalClip.y) {
        discard_fragment();
    }
    float coverage = 1.0;
    if (input.antialias > 0.5) {
        const float beyondEnd = max(
            max(-input.localPixel.x, input.localPixel.x - input.lineLength),
            0.0
        );
        const float distance = length(float2(beyondEnd, input.localPixel.y))
            - input.halfWidth;
        coverage = 1.0 - smoothstep(-0.5, 0.5, distance);
    }
    const float dashLength = input.dash.y;
    const float gapLength = input.dash.z;
    const float cycle = dashLength + gapLength;
    if (dashLength > 0.0 && gapLength > 0.0 && cycle > 0.0) {
        const float phase = fmod(input.distanceAlong + input.dash.w, cycle);
        if (input.antialias > 0.5) {
            const float position = phase < 0.0 ? phase + cycle : phase;
            const float distanceToDash = max(
                min(position, dashLength - position),
                position - cycle
            );
            coverage *= smoothstep(-0.5, 0.5, distanceToDash);
        } else if (phase > dashLength) {
            discard_fragment();
        }
    }
    if (coverage <= 0.0) { discard_fragment(); }
    return float4(input.color.rgb, input.color.a * coverage);
}

struct ChartBarVertexOut {
    float4 position [[position]];
    float4 color;
    float2 localPixel;
    float2 halfSize;
    float cornerRadius;
    float pixelX;
    float2 horizontalClip;
};

vertex ChartBarVertexOut chartBarVertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    const device ChartBarInstance *instances [[buffer(0)]],
    constant ChartUniforms &uniforms [[buffer(1)]]
) {
    const ChartBarInstance instance = instances[instanceID];
    const float2 corners[6] = {
        float2(0.0, 0.0),
        float2(1.0, 0.0),
        float2(0.0, 1.0),
        float2(0.0, 1.0),
        float2(1.0, 0.0),
        float2(1.0, 1.0)
    };
    const bool appliesTimelineTransform = instance.flags.x > 0.5;
    float left = instance.geometry.x;
    float right = instance.geometry.z;
    if (appliesTimelineTransform) {
        // These rectangles also represent hollow borders and full-slot fills.
        // Preserve both edges; candle body sizing applies only to candles.
        left = left * uniforms.translationAndScale.y + uniforms.translationAndScale.x;
        right = right * uniforms.translationAndScale.y + uniforms.translationAndScale.x;
    }
    const float2 corner = corners[vertexID];
    const float2 pixel = float2(
        mix(left, right, corner.x),
        mix(
            instance.geometry.y,
            instance.geometry.w,
            corner.y
        )
    );
    const float2 safeViewport = max(
        uniforms.viewportSize,
        float2(1.0)
    );

    const float2 center = float2(
        (left + right) * 0.5,
        (instance.geometry.y + instance.geometry.w) * 0.5
    );
    const float2 halfSize = float2(
        max(0.0, (right - left) * 0.5),
        max(0.0, (instance.geometry.w - instance.geometry.y) * 0.5)
    );
    ChartBarVertexOut output;
    output.position = float4(
        pixel.x / safeViewport.x * 2.0 - 1.0,
        1.0 - pixel.y / safeViewport.y * 2.0,
        0.0,
        1.0
    );
    output.color = instance.color;
    output.localPixel = pixel - center;
    output.halfSize = halfSize;
    output.cornerRadius = min(
        max(0.0, instance.flags.y),
        min(halfSize.x, halfSize.y)
    );
    output.pixelX = pixel.x;
    output.horizontalClip = appliesTimelineTransform
        ? uniforms.horizontalPlotBounds
        : float2(-1.0e20, 1.0e20);
    return output;
}

fragment float4 chartBarFragment(
    ChartBarVertexOut input [[stage_in]]
) {
    if (input.pixelX < input.horizontalClip.x
        || input.pixelX > input.horizontalClip.y) {
        discard_fragment();
    }
    if (input.cornerRadius <= 0.0) {
        return input.color;
    }
    const float2 roundedHalfSize = max(
        float2(0.0),
        input.halfSize - input.cornerRadius
    );
    const float2 distanceVector = abs(input.localPixel)
        - roundedHalfSize;
    const float signedDistance = length(max(distanceVector, 0.0))
        + min(max(distanceVector.x, distanceVector.y), 0.0)
        - input.cornerRadius;
    const float coverage = 1.0 - smoothstep(
        -0.5,
        0.5,
        signedDistance
    );
    if (coverage <= 0.0) {
        discard_fragment();
    }
    return float4(
        input.color.rgb,
        input.color.a * coverage
    );
}

struct ChartGlyphVertexOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
    float pixelX;
    float2 horizontalClip;
};

vertex ChartGlyphVertexOut chartGlyphVertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    const device ChartGlyphInstance *instances [[buffer(0)]],
    constant ChartUniforms &uniforms [[buffer(1)]]
) {
    const ChartGlyphInstance instance = instances[instanceID];
    const float2 corners[6] = {
        float2(0.0, 0.0),
        float2(1.0, 0.0),
        float2(0.0, 1.0),
        float2(0.0, 1.0),
        float2(1.0, 0.0),
        float2(1.0, 1.0)
    };
    const float2 corner = corners[vertexID];
    float left = instance.geometry.x;
    float right = instance.geometry.z;
    const bool appliesTimelineTransform = instance.flags.x > 0.5;
    if (appliesTimelineTransform) {
        const float anchor = instance.flags.y;
        const float transformedAnchor = anchor
            * uniforms.translationAndScale.y
            + uniforms.translationAndScale.x;
        const float offset = transformedAnchor - anchor;
        left += offset;
        right += offset;
    }
    const float2 pixel = float2(
        mix(left, right, corner.x),
        mix(
            instance.geometry.y,
            instance.geometry.w,
            corner.y
        )
    );
    const float2 safeViewport = max(
        uniforms.viewportSize,
        float2(1.0)
    );

    ChartGlyphVertexOut output;
    output.position = float4(
        pixel.x / safeViewport.x * 2.0 - 1.0,
        1.0 - pixel.y / safeViewport.y * 2.0,
        0.0,
        1.0
    );
    output.uv = float2(
        mix(instance.uv.x, instance.uv.z, corner.x),
        mix(instance.uv.y, instance.uv.w, corner.y)
    );
    output.color = instance.color;
    output.pixelX = pixel.x;
    output.horizontalClip = appliesTimelineTransform
        ? uniforms.horizontalPlotBounds
        : float2(-1.0e20, 1.0e20);
    return output;
}

fragment float4 chartGlyphFragment(
    ChartGlyphVertexOut input [[stage_in]],
    texture2d<float> atlas [[texture(0)]]
) {
    if (input.pixelX < input.horizontalClip.x
        || input.pixelX > input.horizontalClip.y) {
        discard_fragment();
    }
    constexpr sampler glyphSampler(
        coord::normalized,
        address::clamp_to_zero,
        filter::linear
    );
    const float coverage = atlas.sample(
        glyphSampler,
        input.uv
    ).r;
    return float4(
        input.color.rgb,
        input.color.a * coverage
    );
}
