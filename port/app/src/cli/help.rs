//! `ntscrt help` (the Mac's `CLIHelp.swift`, with Windows' names and formats).

use super::CLI_NAME;

pub fn text() -> String {
    TEXT.replace("$ ", &format!("{CLI_NAME} "))
}

const TEXT: &str = concat!(
    "NTSCRT — analog video looks, from the command line.\n",
    "\n",
    "Usage:\n",
    "  $ render <image|video> -o <out.mp4|.gif|.png> [options]\n",
    "  $ describe [stage…] [--crt <preset>|all]   every control, as JSON\n",
    "  $ looks                                    built-in looks, tapes, decks, formats\n",
    "  $ mcp                                      run as an MCP server (stdio) for AI tools\n",
    "\n",
    "The look (applied in this order; later flags adjust earlier ones):\n",
    "  --look <name|file.json>      start from a built-in look or a saved one\n",
    "  --settings <json|@file>      a whole look as JSON (see `$ describe`)\n",
    "  --crop 9:16[@x,y][*zoom]|off\n",
    "  --downscale <width>|off      --downscale-method chunky|smooth\n",
    "  --digital <format>|on|off    --digital-set key=value,…\n",
    "  --ntsc on|off                --ntsc-set key=value,…\n",
    "  --glitch on|off              --glitch-set key=value,…\n",
    "  --vcr on|off  --tape <name>  --deck <name>  --vcr-set key=value,…\n",
    "  --crt <preset>|on|off        --crt-set param=value,…\n",
    "\n",
    "Output:\n",
    "  --format h264|hevc|gif|png   (default: from -o's extension; no ProRes on Windows)\n",
    "  --long-edge N                long edge in pixels (default 1920)\n",
    "  --gif-width N  --gif-fps N   GIF size and rate (default 480, 12)\n",
    "  --duration S  --fps N        a still's video length (default 5 s at 30)\n",
    "  --time S[,S…]                PNG: the frame at these times (one file each)\n",
    "  --zoom N  --zoom-at x,y      PNG: a close-up, as the preview zoomed in (1–12×)\n",
    "  --quality standard|high|very-high|maximum   --loops N   --snap\n",
    "  --save-look <file.json>      also save the look\n",
    "  --dry-run                    resolve the look and size, render nothing\n",
    "\n",
    "Values: numbers, on/off, or a choice's name (tape_speed=EP).\n",
    "Prints one JSON line on stdout: {\"ok\":true,\"outputs\":[{\"path\":…}],…}.\n",
    "Progress goes to stderr as {\"progress\":0.42,\"eta\":12.5}.\n",
    "\n",
    "Examples:\n",
    "  $ render clip.mp4 -o out.mp4 --look \"90s VHS bootleg\"\n",
    "  $ render photo.jpg -o tape.mp4 --tape Moldy --deck \"Dirty heads\" --duration 8\n",
    "  $ render photo.jpg -o frame.png --vcr-set tape_creases=0.6 --time 1,3,5\n",
);

