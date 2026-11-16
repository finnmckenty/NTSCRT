enum CLIHelp {
    static let text = """
    NTSCRT — analog video looks, from the command line.

    Usage:
      NTSCRT render <image|video> -o <out.mp4|.mov|.gif|.png> [options]
      NTSCRT describe [stage…] [--crt <preset>|all]   every control, as JSON
      NTSCRT looks                                    built-in looks, tapes, decks, formats
      NTSCRT mcp                                      run as an MCP server (stdio) for AI tools

    The look (applied in this order; later flags adjust earlier ones):
      --look <name|file.json>      start from a built-in look or a saved one
      --settings <json|@file>      a whole look as JSON (see `NTSCRT describe`)
      --crop 9:16[@x,y][*zoom]|off
      --downscale <width>|off      --downscale-method chunky|smooth
      --digital <format>|on|off    --digital-set key=value,…
      --ntsc on|off                --ntsc-set key=value,…
      --glitch on|off              --glitch-set key=value,…
      --vcr on|off  --tape <name>  --deck <name>  --vcr-set key=value,…
      --crt <preset>|on|off        --crt-set param=value,…

    Output:
      --format h264|hevc|prores|prores-hq|gif|png   (default: from -o's extension)
      --long-edge N                long edge in pixels (default 1920)
      --gif-width N  --gif-fps N   GIF size and rate (default 480, 12)
      --duration S  --fps N        a still's video length (default 5 s at 30)
      --time S[,S…]                PNG: the frame at these times (one file each)
      --quality standard|high|very-high|maximum   --loops N   --snap
      --save-look <file.json>      also save the look
      --dry-run                    resolve the look and size, render nothing

    Values: numbers, on/off, or a choice's name (tape_speed=EP).
    Prints one JSON line on stdout: {"ok":true,"outputs":[{"path":…}],…}.
    Progress goes to stderr as {"progress":0.42,"eta":12.5}.

    Examples:
      NTSCRT render clip.mp4 -o out.mp4 --look "90s VHS bootleg"
      NTSCRT render photo.jpg -o tape.mp4 --tape Moldy --deck "Dirty heads" --duration 8
      NTSCRT render photo.jpg -o frame.png --vcr-set tape_creases=0.6 --time 1,3,5
    """
}
