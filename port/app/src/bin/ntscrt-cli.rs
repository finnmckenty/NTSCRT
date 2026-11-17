//! `ntscrt-cli.exe`: NTSCRT's command line in a terminal. `ntscrt.exe` is a
//! windowed (GUI-subsystem) program, so a terminal doesn't wait for it or show
//! its output; this console program runs it with the terminal's own input and
//! output, waits, and passes on its exit code. `ntscrt-cli render …` is
//! `ntscrt render …` on the Mac. (Pipes, as MCP clients use, work with
//! `ntscrt.exe` directly.)

use std::process::{Command, ExitCode};

fn main() -> ExitCode {
    let Some(exe) = std::env::current_exe().ok().and_then(|p| Some(p.parent()?.join(if cfg!(windows) { "ntscrt.exe" } else { "ntscrt" }))) else {
        eprintln!("ntscrt-cli: can't tell where it is");
        return ExitCode::from(1);
    };
    let mut args: Vec<std::ffi::OsString> = std::env::args_os().skip(1).collect();
    if args.is_empty() {
        args.push("help".into());
    }
    let mut child = match Command::new(&exe).args(&args).spawn() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("ntscrt-cli: couldn't start {}: {e}", exe.display());
            return ExitCode::from(1);
        }
    };
    #[cfg(windows)]
    let _job = kill_with_us(&child);
    match child.wait() {
        Ok(s) => ExitCode::from(s.code().unwrap_or(1).clamp(0, 255) as u8),
        Err(e) => {
            eprintln!("ntscrt-cli: {e}");
            ExitCode::from(1)
        }
    }
}

/// Ctrl+C ends this program; the job object ends ntscrt.exe with it.
#[cfg(windows)]
fn kill_with_us(child: &std::process::Child) -> Option<windows::Win32::Foundation::HANDLE> {
    use std::os::windows::io::AsRawHandle;
    use windows::Win32::Foundation::HANDLE;
    use windows::Win32::System::JobObjects::{
        AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation, SetInformationJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
        JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
    };
    unsafe {
        let job = CreateJobObjectW(None, windows::core::PCWSTR::null()).ok()?;
        let mut info = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        SetInformationJobObject(job, JobObjectExtendedLimitInformation, &info as *const _ as _, std::mem::size_of_val(&info) as u32).ok()?;
        AssignProcessToJobObject(job, HANDLE(child.as_raw_handle() as _)).ok()?;
        Some(job)
    }
}
