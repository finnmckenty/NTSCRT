//! The receiver simulation against the Mac's (tests/fixtures/glitch, made by
//! port/scripts/make-glitch-refs.sh from Receiver.swift compiled as-is):
//! every row, the color reference and the VCR's view of each line, exactly.

use ntscrt_engine::glitch::receiver::{Raster, Simulator};
use ntscrt_engine::glitch::GlitchSettings;
use ntscrt_engine::serde_json::{self, Value};

fn close(a: f64, b: f64) -> bool {
    (a - b).abs() <= 1e-6 * a.abs().max(1.0)
}

#[test]
fn field_plans_match_the_mac() {
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/glitch");
    let mut n = 0;
    for entry in std::fs::read_dir(&dir).unwrap() {
        let path = entry.unwrap().path();
        if path.extension().is_none_or(|e| e != "json") {
            continue;
        }
        let mac: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        let args = std::fs::read_to_string(path.with_extension("args")).unwrap();
        let mut words = args.split_whitespace();
        let time: f64 = words.next().unwrap().parse().unwrap();
        let mut s = GlitchSettings::default();
        for kv in words {
            let (k, v) = kv.split_once('=').unwrap();
            s.values.insert(k.into(), v.parse().unwrap());
        }
        // As the reference advances: 30 frames a second from zero.
        let mut sim = Simulator::new(Raster::new(320, 240));
        sim.advance(0.0, &s);
        let mut t = 0.0f64;
        while t < time {
            t = (t + 1.0 / 30.0).min(time);
            sim.advance(t, &s);
        }
        let plan = sim.plan();
        let name = path.file_stem().unwrap().to_string_lossy().to_string();
        assert_eq!(mac["nominalTrigger"].as_u64().unwrap() as usize, sim.nominal_trigger, "{name}");
        assert!(close(mac["time"].as_f64().unwrap(), sim.time()), "{name}: time");
        assert_eq!(mac["fieldIndex"].as_u64().unwrap() as u32, plan.field_index, "{name}: field index");
        assert_eq!(mac["ccBits"].as_u64().unwrap() as u32, plan.cc_bits, "{name}: captions");
        let rows = mac["rows"].as_array().unwrap();
        assert_eq!(rows.len(), plan.rows.len(), "{name}");
        for (y, (m, r)) in rows.iter().zip(&plan.rows).enumerate() {
            let ours = [r.u0 as f64, r.field_line as f64, r.len_prev as f64, r.len_cur as f64, r.len_next as f64, r.noise_ire as f64,
                        r.hum_ire as f64, r.burst_scale as f64, r.gate_shift as f64];
            for (i, (a, b)) in m.as_array().unwrap().iter().zip(ours).enumerate() {
                assert!(close(a.as_f64().unwrap(), b), "{name}: row {y} field {i}: Mac {a}, ours {b}");
            }
        }
        let c = mac["chroma"].as_array().unwrap();
        let ours = [plan.chroma_phase as f64, plan.chroma_gain as f64, plan.killer as f64, if plan.color_on { 1.0 } else { 0.0 }];
        for (a, b) in c.iter().zip(ours) {
            assert!(close(a.as_f64().unwrap(), b), "{name}: chroma Mac {a}, ours {b}");
        }
        let vcr = mac["vcr"].as_array().unwrap();
        let lines = plan.vcr.as_ref().map(|v| v.lines.as_slice()).unwrap_or(&[]);
        assert_eq!(vcr.len(), lines.len(), "{name}: VCR lines");
        for (y, (m, l)) in vcr.iter().zip(lines).enumerate() {
            let ours = [l.origin_base as f64, l.origin_offset as f64, l.along0 as f64, l.spacing as f64, l.grease as f64, l.gain as f64, l.head as f64];
            for (i, (a, b)) in m.as_array().unwrap().iter().zip(ours).enumerate() {
                assert!(close(a.as_f64().unwrap(), b), "{name}: VCR line {y} field {i}: Mac {a}, ours {b}");
            }
        }
        n += 1;
    }
    assert!(n >= 6, "found {n} fixtures");
}
