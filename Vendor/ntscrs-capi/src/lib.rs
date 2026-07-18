//! Minimal C ABI around the ntsc-rs core library (crates/ntscrs).
//!
//! Surface (all strings UTF-8; caller frees returned strings with
//! `ntsc_string_free`):
//!   - ntsc_settings_descriptors_json(): schema tree for auto-generated UIs
//!   - ntsc_new / ntsc_free: opaque instance holding NtscEffectFullSettings
//!   - ntsc_settings_to_json / ntsc_settings_from_json: the stable
//!     `"version": 1` preset format used by the ntsc-rs GUI
//!   - ntsc_process_frame: apply the effect in place to an RGBA8/BGRA8
//!     buffer with explicit row stride; frame_index drives field selection
//!     and the deterministic RNG.

use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};

use ntsc_rs::settings::standard::NtscEffectFullSettings;
use ntsc_rs::settings::{SettingDescriptor, SettingKind, SettingsList};
use ntsc_rs::yiq_fielding::{BlitInfo, Bgrx, DeinterlaceMode, Rgbx, YiqOwned, YiqView};
use ntsc_rs::NtscEffect;

pub struct NtscInstance {
    settings: NtscEffectFullSettings,
}

fn to_c_string(s: String) -> *mut c_char {
    CString::new(s.replace('\0', ""))
        .map(|c| c.into_raw())
        .unwrap_or(std::ptr::null_mut())
}

/// # Safety
/// `s` must be a pointer previously returned by this library.
#[no_mangle]
pub unsafe extern "C" fn ntsc_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}

#[no_mangle]
pub extern "C" fn ntsc_new() -> *mut NtscInstance {
    Box::into_raw(Box::new(NtscInstance {
        settings: NtscEffectFullSettings::default(),
    }))
}

/// # Safety
/// `inst` must be a pointer previously returned by `ntsc_new`.
#[no_mangle]
pub unsafe extern "C" fn ntsc_free(inst: *mut NtscInstance) {
    if !inst.is_null() {
        drop(Box::from_raw(inst));
    }
}

// ---- descriptors ----

fn esc(out: &mut String, s: &str) {
    for ch in s.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
}

fn descriptor_json(out: &mut String, d: &SettingDescriptor<NtscEffectFullSettings>) {
    out.push_str("{\"name\":\"");
    esc(out, d.id.name);
    out.push_str("\",\"label\":\"");
    esc(out, d.label);
    out.push('"');
    if let Some(desc) = d.description {
        out.push_str(",\"description\":\"");
        esc(out, desc);
        out.push('"');
    }
    match &d.kind {
        SettingKind::Boolean => out.push_str(",\"kind\":\"boolean\""),
        SettingKind::Percentage { logarithmic } => {
            out.push_str(&format!(",\"kind\":\"percentage\",\"logarithmic\":{logarithmic}"));
        }
        SettingKind::IntRange { range } => {
            out.push_str(&format!(
                ",\"kind\":\"int\",\"min\":{},\"max\":{}",
                range.start(),
                range.end()
            ));
        }
        SettingKind::FloatRange { range, logarithmic } => {
            out.push_str(&format!(
                ",\"kind\":\"float\",\"min\":{},\"max\":{},\"logarithmic\":{}",
                range.start(),
                range.end(),
                logarithmic
            ));
        }
        SettingKind::Enumeration { options } => {
            out.push_str(",\"kind\":\"enum\",\"options\":[");
            for (i, o) in options.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                out.push_str("{\"label\":\"");
                esc(out, o.label);
                out.push_str("\",\"index\":");
                out.push_str(&o.index.to_string());
                if let Some(d2) = o.description {
                    out.push_str(",\"description\":\"");
                    esc(out, d2);
                    out.push('"');
                }
                out.push('}');
            }
            out.push(']');
        }
        SettingKind::Group { children } => {
            out.push_str(",\"kind\":\"group\",\"children\":[");
            for (i, c) in children.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                descriptor_json(out, c);
            }
            out.push(']');
        }
        _ => out.push_str(",\"kind\":\"unknown\""),
    }
    out.push('}');
}

#[no_mangle]
pub extern "C" fn ntsc_settings_descriptors_json() -> *mut c_char {
    let result = catch_unwind(|| {
        let list = SettingsList::<NtscEffectFullSettings>::new();
        let mut out = String::with_capacity(16 * 1024);
        out.push('[');
        for (i, d) in list.setting_descriptors.iter().enumerate() {
            if i > 0 {
                out.push(',');
            }
            descriptor_json(&mut out, d);
        }
        out.push(']');
        out
    });
    match result {
        Ok(s) => to_c_string(s),
        Err(_) => std::ptr::null_mut(),
    }
}

// ---- settings JSON ----

/// # Safety
/// `inst` must be a valid instance pointer.
#[no_mangle]
pub unsafe extern "C" fn ntsc_settings_to_json(inst: *const NtscInstance) -> *mut c_char {
    let Some(inst) = inst.as_ref() else {
        return std::ptr::null_mut();
    };
    let result = catch_unwind(AssertUnwindSafe(|| {
        let list = SettingsList::<NtscEffectFullSettings>::new();
        list.to_json_string(&inst.settings)
    }));
    match result {
        Ok(Ok(s)) => to_c_string(s),
        _ => std::ptr::null_mut(),
    }
}

/// Returns 0 on success. On failure returns nonzero and, if `err_out` is
/// non-null, sets it to a malloc'd message (free with ntsc_string_free).
///
/// # Safety
/// `inst` must be a valid instance pointer; `json` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn ntsc_settings_from_json(
    inst: *mut NtscInstance,
    json: *const c_char,
    err_out: *mut *mut c_char,
) -> i32 {
    if !err_out.is_null() {
        *err_out = std::ptr::null_mut();
    }
    let Some(inst) = inst.as_mut() else { return 1 };
    if json.is_null() {
        return 1;
    }
    let Ok(json) = CStr::from_ptr(json).to_str() else {
        return 1;
    };
    let result = catch_unwind(|| {
        SettingsList::<NtscEffectFullSettings>::new().from_json(json)
    });
    match result {
        Ok(Ok(settings)) => {
            inst.settings = settings;
            0
        }
        Ok(Err(e)) => {
            if !err_out.is_null() {
                *err_out = to_c_string(format!("{e}"));
            }
            2
        }
        Err(_) => 3,
    }
}

// ---- processing ----

pub const NTSC_RGBA8: i32 = 0;
pub const NTSC_BGRA8: i32 = 1;

/// Apply the effect in place. `data` is width*height 4-byte pixels with
/// `row_bytes` stride (>= width*4). Returns 0 on success.
///
/// Note: ntsc-rs writes alpha as opaque; callers that need source alpha
/// must save/restore it themselves.
///
/// # Safety
/// `inst` valid; `data` points to at least `row_bytes * height` bytes.
#[no_mangle]
pub unsafe extern "C" fn ntsc_process_frame(
    inst: *const NtscInstance,
    fmt: i32,
    data: *mut u8,
    width: u32,
    height: u32,
    row_bytes: u32,
    frame_index: i64,
) -> i32 {
    let Some(inst) = inst.as_ref() else { return 1 };
    if data.is_null() || width == 0 || height == 0 || row_bytes < width * 4 {
        return 1;
    }
    let buf = std::slice::from_raw_parts_mut(data, row_bytes as usize * height as usize);
    let dims = (width as usize, height as usize);
    let frame = frame_index.max(0) as usize;

    let result = catch_unwind(AssertUnwindSafe(|| {
        let effect: NtscEffect = (&inst.settings).into();
        let field = effect.use_field.to_yiq_field(frame);
        let mut yiq_buf = vec![0f32; YiqView::buf_length_for(dims, field)];
        let mut view = YiqView::from_parts(&mut yiq_buf, dims, field);
        let blit = BlitInfo::from_full_frame(dims.0, dims.1, row_bytes as usize);
        match fmt {
            NTSC_BGRA8 => {
                view.set_from_strided_buffer::<Bgrx, u8, _>(buf, blit, ());
                effect.apply_effect_to_yiq(&mut view, frame, [1.0, 1.0]);
                view.write_to_strided_buffer::<Bgrx, u8, _>(buf, blit, DeinterlaceMode::Bob, ());
                0
            }
            NTSC_RGBA8 => {
                view.set_from_strided_buffer::<Rgbx, u8, _>(buf, blit, ());
                effect.apply_effect_to_yiq(&mut view, frame, [1.0, 1.0]);
                view.write_to_strided_buffer::<Rgbx, u8, _>(buf, blit, DeinterlaceMode::Bob, ());
                0
            }
            _ => 1,
        }
    }));
    result.unwrap_or(2)
}

// Silence unused warning if YiqOwned turns out unnecessary.
#[allow(unused)]
fn _typecheck() {
    let _ = std::mem::size_of::<Option<YiqOwned>>();
}
