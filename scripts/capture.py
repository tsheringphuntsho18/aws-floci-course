#!/usr/bin/env python3
import getpass
import os
import re
import socket
import subprocess
import sys
from PIL import Image, ImageDraw, ImageFont

BG_COLOR = (11, 12, 14)
PROMPT_USER_COLOR = (85, 225, 85)    # Bold green: tshering@linux-os
PROMPT_PATH_COLOR = (65, 130, 255)   # Bold blue: ~/Desktop/DSO303/...
CMD_COLOR = (75, 140, 255)           # Blue command text
DEFAULT_OUT_COLOR = (75, 140, 255)   # Blue standard output
WHITE_COLOR = (225, 230, 235)
GREEN_COLOR = (85, 225, 85)
RED_COLOR = (245, 85, 85)
YELLOW_COLOR = (240, 200, 75)

ANSI_MAP = {
    30: (140, 145, 155),
    31: RED_COLOR,
    32: GREEN_COLOR,
    33: YELLOW_COLOR,
    34: (65, 130, 255),
    35: (205, 115, 235),
    36: (75, 210, 225),
    37: WHITE_COLOR,
    90: (135, 140, 150),
    91: RED_COLOR,
    92: GREEN_COLOR,
    93: YELLOW_COLOR,
    94: (85, 150, 255),
    95: (220, 135, 245),
    96: (95, 225, 240),
    97: (245, 248, 252),
}

ANSI_RE = re.compile(r"\x1b\[([0-9;]*)m")


def load_fonts(size: int = 16):
    candidates = [
        ("/usr/share/fonts/truetype/ubuntu/UbuntuMono-R.ttf",
         "/usr/share/fonts/truetype/ubuntu/UbuntuMono-B.ttf"),
        ("/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
         "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf"),
        ("/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
         "/usr/share/fonts/truetype/liberation/LiberationMono-Bold.ttf"),
    ]
    for reg_path, bold_path in candidates:
        if os.path.exists(reg_path):
            reg = ImageFont.truetype(reg_path, size)
            bold = ImageFont.truetype(bold_path, size) if os.path.exists(bold_path) else reg
            return reg, bold
    default = ImageFont.load_default()
    return default, default


def build_prompt_spans(cmd: str):
    user = getpass.getuser()
    host = socket.gethostname()
    cwd = os.getcwd()
    home = os.path.expanduser("~")
    if cwd.startswith(home):
        cwd = "~" + cwd[len(home):]
    return [
        (f"{user}@{host}", PROMPT_USER_COLOR, True),
        (":", WHITE_COLOR, False),
        (cwd, PROMPT_PATH_COLOR, True),
        ("$ ", WHITE_COLOR, False),
        (cmd, CMD_COLOR, False),
    ]


def parse_ansi_line(line: str):
    if "\x1b[" not in line:
        if line.startswith("==="):
            return [(line, PROMPT_PATH_COLOR, True)]
        if "[ok]" in line:
            parts = line.split("[ok]", 1)
            return [
                (parts[0], DEFAULT_OUT_COLOR, False),
                ("[ok]", GREEN_COLOR, True),
                (parts[1], DEFAULT_OUT_COLOR, False),
            ]
        if any(err in line for err in ("ERROR", "Error", "Failed", "Exception", "denied")):
            return [(line, RED_COLOR, False)]
        return [(line, DEFAULT_OUT_COLOR, False)]

    spans = []
    color = DEFAULT_OUT_COLOR
    bold = False
    pos = 0
    for match in ANSI_RE.finditer(line):
        if match.start() > pos:
            spans.append((line[pos:match.start()], color, bold))
        codes = [int(c) for c in match.group(1).split(";") if c.isdigit()] or [0]
        for code in codes:
            if code == 0:
                color, bold = DEFAULT_OUT_COLOR, False
            elif code == 1:
                bold = True
            elif code == 22:
                bold = False
            elif code in ANSI_MAP:
                color = ANSI_MAP[code]
        pos = match.end()
    if pos < len(line):
        spans.append((line[pos:], color, bold))
    return spans


def wrap_spans(spans, max_cols: int = 112):
    rows = [[]]
    col = 0
    for text, color, bold in spans:
        for ch in text:
            if col >= max_cols:
                rows.append([])
                col = 0
            if rows[-1] and rows[-1][-1][1] == color and rows[-1][-1][2] == bold:
                prev_txt, _, _ = rows[-1][-1]
                rows[-1][-1] = (prev_txt + ch, color, bold)
            else:
                rows[-1].append((ch, color, bold))
            col += 1
    return rows


def render_png(cmd: str, raw_output: str, out_path: str):
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    reg_font, bold_font = load_fonts(size=16)

    raw_lines = raw_output.splitlines()
    if len(raw_lines) > 55:
        raw_lines = (
            raw_lines[:14]
            + ["... [output truncated for readability] ..."]
            + raw_lines[-36:]
        )

    styled_rows = wrap_spans(build_prompt_spans(cmd))
    for line in raw_lines:
        styled_rows.extend(wrap_spans(parse_ansi_line(line)))

    char_w = reg_font.getlength("M")
    line_h = 22
    pad_x, pad_y = 10, 8
    max_line_cols = max((sum(len(seg[0]) for seg in row) for row in styled_rows), default=60)
    width = max(760, min(1150, int(pad_x * 2 + max(max_line_cols, 72) * char_w)))
    height = max(80, pad_y * 2 + len(styled_rows) * line_h)

    img = Image.new("RGB", (width, height), color=BG_COLOR)
    draw = ImageDraw.Draw(img)

    y = pad_y
    for row in styled_rows:
        x = pad_x
        for text, color, bold in row:
            font = bold_font if bold else reg_font
            draw.text((x, y), text, fill=color, font=font)
            x += font.getlength(text)
        y += line_h

    img.save(out_path)


if __name__ == "__main__":
    out_png, cmd = sys.argv[1], sys.argv[2]
    env = os.environ.copy()
    env["FORCE_COLOR"] = "1"
    env["CLICOLOR_FORCE"] = "1"
    env["TERM"] = "xterm-256color"

    proc = subprocess.run(cmd, shell=True, text=True, capture_output=True, env=env)
    combined_raw = f"{proc.stdout}{proc.stderr}".rstrip()
    render_png(cmd, combined_raw, out_png)

    clean_lines = ANSI_RE.sub("", combined_raw).splitlines()
    if len(clean_lines) > 24:
        summary_lines = clean_lines[:12] + ["... [truncated] ..."] + clean_lines[-12:]
    else:
        summary_lines = clean_lines

    print(f"EXIT={proc.returncode} | PNG={out_png}")
    if summary_lines:
        print("\n".join(summary_lines))
    sys.exit(proc.returncode)