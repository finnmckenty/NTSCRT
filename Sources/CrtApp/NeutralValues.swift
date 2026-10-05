import Foundation
import CrtCore

/// Where each property's effect is weakest — the value a double-click on its
/// slider knob goes to. Decided per property:
///
/// - strengths, amounts, weights and offsets: 0
/// - multipliers (brightness, contrast, saturation, color boost): 1
/// - scale and "detail" controls: their minimum (smallest, smoothest effect)
/// - geometry: flat (largest curvature radius, smallest corner and border)
/// - beam widths: their maximum (fat beams leave the least scanline gap)
/// - controls that change an effect's character rather than its amount
///   (frequency, speed, shape, gamma, position): the default
enum Neutral {
    case value(Double)
    case minimum
    case maximum
    case defaultValue

    func resolve(min lo: Double, max hi: Double, default def: Double) -> Double {
        switch self {
        case .value(let v): return Swift.min(hi, Swift.max(lo, v))
        case .minimum: return lo
        case .maximum: return hi
        case .defaultValue: return def
        }
    }

    // MARK: NTSC (ntsc-rs settings)

    static let ntsc: [String: Neutral] = [
        "bandwidth_scale": .minimum,                  // Horizontal intensity
        "vertical_scale": .minimum,                   // Vertical intensity
        "composite_preemphasis": .value(0),           // sharpening
        "composite_noise_intensity": .value(0),
        "composite_noise_frequency": .defaultValue,
        "composite_noise_detail": .minimum,
        "snow_intensity": .value(0),
        "snow_anisotropy": .defaultValue,
        "video_scanline_phase_shift_offset": .defaultValue,
        "luma_smear": .value(0),
        "head_switching_height": .value(0),
        "head_switching_offset": .defaultValue,
        "head_switching_horizontal_shift": .value(0),
        "head_switching_mid_line_position": .defaultValue,
        "head_switching_mid_line_jitter": .value(0),
        "tracking_noise_height": .value(0),
        "tracking_noise_wave_intensity": .value(0),
        "tracking_noise_snow_intensity": .value(0),
        "tracking_noise_snow_anisotropy": .defaultValue,
        "tracking_noise_noise_intensity": .value(0),
        "ringing_frequency": .defaultValue,
        "ringing_power": .defaultValue,
        "ringing_scale": .value(0),
        "luma_noise_intensity": .value(0),
        "luma_noise_frequency": .defaultValue,
        "luma_noise_detail": .minimum,
        "chroma_noise_intensity": .value(0),
        "chroma_noise_frequency": .defaultValue,
        "chroma_noise_detail": .minimum,
        "chroma_phase_error": .value(0),
        "chroma_phase_noise_intensity": .value(0),
        "chroma_delay_horizontal": .value(0),
        "chroma_delay_vertical": .value(0),
        "vhs_chroma_loss": .value(0),
        "vhs_sharpen": .value(0),
        "vhs_sharpen_frequency": .defaultValue,
        "vhs_edge_wave": .value(0),
        "vhs_edge_wave_speed": .defaultValue,
        "vhs_edge_wave_frequency": .defaultValue,
        "vhs_edge_wave_detail": .minimum,
    ]

    // MARK: CRT shader parameters (names shared across presets mean the same)

    static let shader: [String: Neutral] = [
        // CRT Aperture
        "GLOW_WIDTH": .minimum, "GLOW_HEIGHT": .minimum,
        "GLOW_HALATION": .value(0), "GLOW_DIFFUSION": .value(0),
        "MASK_STRENGTH": .value(0),
        "SCANLINE_SIZE_MIN": .maximum, "SCANLINE_SIZE_MAX": .maximum,
        "SCANLINE_SHAPE": .defaultValue,
        "GAMMA_INPUT": .defaultValue, "GAMMA_OUTPUT": .defaultValue,
        "BRIGHTNESS": .value(1),
        // CRT Easymode
        "SHARPNESS_H": .defaultValue, "SHARPNESS_V": .defaultValue,
        "MASK_DOT_WIDTH": .defaultValue, "MASK_DOT_HEIGHT": .defaultValue,
        "MASK_STAGGER": .defaultValue, "MASK_SIZE": .defaultValue,
        "SCANLINE_STRENGTH": .value(0),
        "SCANLINE_BEAM_WIDTH_MIN": .defaultValue, "SCANLINE_BEAM_WIDTH_MAX": .defaultValue,
        "SCANLINE_BRIGHT_MIN": .defaultValue, "SCANLINE_BRIGHT_MAX": .defaultValue,
        "SCANLINE_CUTOFF": .defaultValue,
        "BRIGHT_BOOST": .value(1),
        // CRT Glow (Gaussian, Lanczos)
        "INPUT_GAMMA": .defaultValue, "OUTPUT_GAMMA": .defaultValue,
        "BOOST": .value(1),
        "GLOW_WHITEPOINT": .defaultValue, "GLOW_ROLLOFF": .defaultValue,
        "BLOOM_STRENGTH": .value(0),
        "warpX": .value(0), "warpY": .value(0),
        "cornersize": .minimum, "cornersmooth": .defaultValue,
        "noise_amt": .value(0),
        "maskDark": .value(1), "maskLight": .value(1),     // 1/1 = no mask
        // CRT Hyllian
        "H_InputGamma": .defaultValue, "H_OUTPUT_GAMMA": .defaultValue,
        "BRIGHTBOOST": .value(1),
        "BEAM_MIN_WIDTH": .maximum, "BEAM_MAX_WIDTH": .maximum,
        "SCANLINES_STRENGTH": .value(0),
        "H_MaskGamma": .defaultValue, "SCANLINES_CUTOFF": .defaultValue,
        "GLOW_RADIUS": .minimum, "GLOW_STRENGTH": .value(0),
        "h_radius": .maximum,                                // curvature radius: flat
        "h_cornersize": .minimum, "h_cornersmooth": .defaultValue,
        // CRT Royale
        "convergence_offset_x_r": .value(0), "convergence_offset_x_g": .value(0),
        "convergence_offset_x_b": .value(0), "convergence_offset_y_r": .value(0),
        "convergence_offset_y_g": .value(0), "convergence_offset_y_b": .value(0),
        "geom_tilt_angle_x": .value(0), "geom_tilt_angle_y": .value(0),
        "geom_radius": .maximum, "geom_view_dist": .defaultValue,
        "geom_aspect_ratio_x": .defaultValue, "geom_aspect_ratio_y": .defaultValue,
        "geom_overscan_x": .value(1), "geom_overscan_y": .value(1),
        "border_compress": .defaultValue, "border_darkness": .value(0), "border_size": .minimum,
        "beam_horiz_linear_rgb_weight": .defaultValue,
        "crt_gamma": .defaultValue, "lcd_gamma": .defaultValue,
        "levels_contrast": .value(1),
        "bloom_underestimate_levels": .defaultValue, "bloom_excess": .value(0),
        "halation_weight": .value(0), "diffusion_weight": .value(0),
        "beam_min_sigma": .defaultValue, "beam_max_sigma": .defaultValue,
        "beam_min_shape": .defaultValue, "beam_max_shape": .defaultValue,
        "beam_spot_power": .defaultValue, "beam_shape_power": .defaultValue,
        "beam_horiz_sigma": .defaultValue,
        "mask_triad_size_desired": .defaultValue, "mask_num_triads_desired": .defaultValue,
        "aa_gauss_sigma": .defaultValue, "aa_cubic_c": .defaultValue,
        // CRT Sim
        "Tuning_Sharp": .value(0),
        "Tuning_Persistence_R": .value(0), "Tuning_Persistence_G": .value(0),
        "Tuning_Persistence_B": .value(0),
        "Tuning_Bleed": .value(0), "Tuning_Artifacts": .value(0),
        "NTSCArtifactScale": .defaultValue, "CRTMask_Scale": .defaultValue,
        "Tuning_Satur": .value(1),
        "Tuning_Mask_Brightness": .value(1), "Tuning_Mask_Opacity": .value(0),
        "bloom_scale_down": .defaultValue, "bloom_scale_up": .defaultValue,
        "BloomPower": .defaultValue, "BloomScalar": .value(0),
        "Tuning_Overscan": .value(1), "Tuning_Barrel": .value(0),
    ]
}
