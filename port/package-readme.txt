NTSCRT for Windows (preview)
============================

Unzip the folder anywhere and run ntscrt.exe. It isn't code-signed yet, so
Windows may say it protected your PC: click More info, then Run anyway.
Keep the folders next to it: shaders\ (the RetroArch CRT
shaders), presets\ (the bundled looks) and licenses\.

Open a picture (PNG, JPEG, HEIC) or a video (MP4/MOV) with Open... or by
dropping it on the window (HEIC needs Microsoft's free HEIF Image
Extensions from the Microsoft Store), shape the look in the sidebar, and use Export... for PNG, MP4 or GIF.
Preset > Load/Save reads and writes the same look files as the Mac app.

Claude and other AI apps: Help > Connect to Claude... lets Claude Desktop
or Claude Code preview, render and save looks with NTSCRT (its MCP server,
ntscrt.exe mcp). Extract this folder somewhere it can stay first.

Command line: in a terminal, run ntscrt-cli.exe from this folder, e.g.
  ntscrt-cli render clip.mp4 -o out.mp4 --look "90s VHS bootleg"
ntscrt-cli help lists the options; describe and looks list the controls.

This is an early build of the Windows port: every feature of the Mac app
except ProRes export. NTSCRT is MIT-licensed (LICENSE); the shaders and libraries
it carries keep their own licenses (THIRD_PARTY_NOTICES.md, licenses\).
