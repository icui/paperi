#!/usr/bin/env python3
"""Compress a screen recording and generate its README preview.

Docs tooling: pip install imageio-ffmpeg
Usage: python scripts/compress-demo.py path/to/recording.mov
"""
import subprocess
import sys
from pathlib import Path
import imageio_ffmpeg

ROOT = Path(__file__).resolve().parents[1]


def main():
    source = Path(sys.argv[1]).resolve()
    output = ROOT / 'assets/demos/workspace-demo.mp4'
    ffmpeg = imageio_ffmpeg.get_ffmpeg_exe()
    subprocess.run([ffmpeg, '-hide_banner', '-loglevel', 'warning', '-y',
        '-i', str(source), '-vf', 'fps=30,scale=1440:-2,format=yuv420p',
        '-map', '0:v:0', '-an', '-c:v', 'libx264', '-preset', 'slow', '-crf', '26',
        '-movflags', '+faststart', str(output)], check=True)
    subprocess.run([ffmpeg, '-v', 'error', '-y', '-ss', '5.1', '-i', str(output),
        '-frames:v', '1', '-q:v', '3', str(output.with_suffix('.jpg'))], check=True)
    print(f'{output.relative_to(ROOT)}: {output.stat().st_size:,} bytes')


if __name__ == '__main__':
    main()
