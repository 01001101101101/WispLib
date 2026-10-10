#param float p_noise = 0.028
#param float p_tearing = 0.035
#param float p_vignette = 0.42
#param float p_motion = 0.0
#param float p_jump = 0.0

// Small deterministic hash for grain and short-lived signal fragments.
float signalHash(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

vec4 effect() {
    float activity = clamp(p_motion * 0.65 + p_jump, 0.0, 1.0);
    float time = u_timer;
    vec2 screen_size = max(vec2(u_screenSize), vec2(1.0));
    vec2 texel = 1.0 / screen_size;
    vec2 uv = v_uv;

    // A slight glass bend makes the filter feel like a screen, not a flat color tint.
    vec2 curve = (uv - 0.5) * 2.0;
    curve *= 1.0 + 0.012 * dot(curve, curve);
    uv = curve * 0.5 + 0.5;
    uv += vec2(sin(uv.y * 17.0 + time * 4.0), cos(uv.x * 13.0 - time * 3.0))
        * (0.0003 + activity * 0.0012);

    // A few changing patches shift locally; the screen does not break into constant bars.
    float frame = floor(time * 12.0);
    for (int i = 0; i < 3; i++) {
        float seed = frame + float(i) * 37.0;
        vec2 center = vec2(signalHash(vec2(seed, 2.0)), signalHash(vec2(seed, 7.0)));
        vec2 size = vec2(0.035 + signalHash(vec2(seed, 4.0)) * 0.11,
                         0.012 + signalHash(vec2(seed, 9.0)) * 0.04);
        vec2 patch_uv = abs(v_uv - center) / size;
        float patch = 1.0 - smoothstep(0.8, 1.15, max(patch_uv.x, patch_uv.y));
        float gate = step(0.68, signalHash(vec2(seed, 12.0)));
        float shift = (signalHash(vec2(seed, 18.0)) - 0.5) * p_tearing
            * (0.25 + activity * 1.5) * patch * gate;
        uv.x += shift;
    }

    uv = clamp(uv, texel * 0.5, vec2(1.0) - texel * 0.5);
    float chroma = 0.0015 * (1.0 + activity * 1.8);
    vec3 color = vec3(
        texture(u_screen, uv + vec2(chroma, 0.0)).r,
        texture(u_screen, uv).g,
        texture(u_screen, uv - vec2(chroma, 0.0)).b
    );

    // Fine grain and faint scan shading stay subtle while standing still.
    float grain = signalHash(floor(v_uv * screen_size) + vec2(19.0, frame));
    float scan = 1.0 - 0.035 * (0.5 + 0.5 * sin(v_uv.y * screen_size.y * 3.14159));
    color = color * scan + (grain - 0.5) * p_noise * (0.45 + activity * 1.6);
    color += vec3(0.008, 0.022, 0.018) * p_jump;

    float edge = length((v_uv - 0.5) * vec2(0.8, 1.0));
    color *= 1.0 - p_vignette * smoothstep(0.4, 1.25, edge);

    vec4 original = texture(u_screen, v_uv);
    return vec4(mix(original.rgb, clamp(color, 0.0, 1.0), u_intensity), original.a);
}
