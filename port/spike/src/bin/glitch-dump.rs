//! glitch-dump <width> <height> <time> [key=value ...]: the Rust receiver's
//! field plan as JSON, matching port/scripts/glitch-ref (the Mac's).
use ntscrt_engine::glitch::receiver::{Raster, Simulator};
use ntscrt_engine::glitch::GlitchSettings;

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let (w, h, time): (usize, usize, f64) = (a[1].parse().unwrap(), a[2].parse().unwrap(), a[3].parse().unwrap());
    let mut s = GlitchSettings::default();
    for kv in &a[4..] {
        let (k, v) = kv.split_once('=').unwrap();
        s.values.insert(k.to_string(), v.parse().unwrap());
    }
    let mut sim = Simulator::new(Raster::new(w, h));
    let mut t = 0.0f64;
    sim.advance(0.0, &s);
    while t < time {
        t = (t + 1.0 / 30.0).min(time);
        sim.advance(t, &s);
    }
    let plan = sim.plan();
    let rows: Vec<Vec<f64>> = plan
        .rows
        .iter()
        .map(|r| {
            vec![r.u0 as f64, r.field_line as f64, r.len_prev as f64, r.len_cur as f64, r.len_next as f64, r.noise_ire as f64, r.hum_ire as f64,
                 r.burst_scale as f64, r.tape_loss as f64, r.gate_shift as f64]
        })
        .collect();
    let drops: Vec<Vec<f64>> = plan.dropouts.iter().map(|d| vec![d.field_line as f64, d.u_start as f64, d.u_length as f64]).collect();
    let out = ntscrt_engine::serde_json::json!({
        "time": sim.time(), "nominalTrigger": sim.nominal_trigger, "rows": rows, "dropouts": drops,
        "chroma": [plan.chroma_phase as f64, plan.chroma_gain as f64, plan.killer as f64, if plan.color_on { 1.0 } else { 0.0 }],
        "pictureGain": plan.picture_gain as f64, "ccBits": plan.cc_bits, "fieldIndex": plan.field_index,
    });
    println!("{out}");
}
