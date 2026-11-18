// The app icon (Finn's color-bar artwork, port/app/ntscrt.ico) in the .exe
// files, for Explorer and the taskbar's pinned item; the window itself loads
// icon-256.png (main.rs). Only when building on and for Windows.
fn main() {
    println!("cargo:rerun-if-changed=ntscrt.ico");
    #[cfg(windows)]
    {
        if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows") {
            let mut res = winresource::WindowsResource::new();
            res.set_icon("ntscrt.ico");
            res.compile().expect("Windows resources (the app icon)");
        }
    }
}
