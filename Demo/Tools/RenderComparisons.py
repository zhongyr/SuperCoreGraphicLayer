"""Compose real iPhone 12 recordings into README GIFs and MP4s at normal speed.

Requires pillow and imageio-ffmpeg. Input files: {shape,gradient}-{layers,draw,surface}.mov.
The crop matches the demo's 358x447 pt canvas on a 1170x2532 px iPhone 12 screen.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

import imageio_ffmpeg
from PIL import Image, ImageDraw, ImageFont

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('recordings', type=Path)
parser.add_argument('--output', type=Path, default=Path('Docs/assets'))
parser.add_argument('--font', type=Path, required=True, help='Path to a TrueType font')
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
ffmpeg = imageio_ffmpeg.get_ffmpeg_exe()
backends = ['layers', 'draw', 'surface']
manifest = {'device': 'iPhone 12 / A14', 'os': 'iOS 27.2 beta (24B5110a)',
            'capture': 'AVFoundation USB screen video; no audio',
            'count': 1000, 'workload': 'motion', 'playbackSpeed': 1,
            'sourceTrimSeconds': [1, 5], 'cropPixels': [1074, 1341, 48, 1041],
            'gifFramesPerSecond': {'shape': 25, 'gradient': 20}, 'mp4ContainerFramesPerSecond': 60,
            'notes': ['Separate sequential recordings; no generated or interpolated motion.',
                      'CFR encoding repeats/omits captured frames while preserving elapsed time.',
                      'Recording adds overhead; the motion showcase is separate from the repaint benchmark.'],
            'scenes': {}}

def command(arguments):
    subprocess.run([ffmpeg, '-hide_banner', '-loglevel', 'error', '-y', *arguments], check=True)

for scene in ['shape', 'gradient']:
    sources = [args.recordings / f'{scene}-{backend}.mov' for backend in backends]
    for source in sources:
        if not source.is_file():
            raise SystemExit(f'Missing recording: {source}')
    frame = Image.new('RGB', (880, 500), '#081827')
    draw = ImageDraw.Draw(frame)
    font = lambda size: ImageFont.truetype(str(args.font), size)
    title = '1,000 complex paths in motion' if scene == 'shape' else '1,000 gradients in motion'
    draw.text((24, 16), title, font=font(29), fill='#eef7ff')
    draw.text((24, 54), 'SCGLayer  /  Real iPhone 12 recordings  /  Same scene and motion',
              font=font(13), fill='#a8bed4')
    labels = ['CAShapeLayer' if scene == 'shape' else 'CAGradientLayer', 'drawRect', 'SCGLayer']
    for x, label, color in zip([24, 308, 592], labels, ['#a8bed4', '#70b4ff', '#39d8c2']):
        draw.text((x + 132, 85), label, anchor='mt', font=font(18), fill=color)
        draw.rectangle((x, 110, x + 263, 113), fill=color)
    draw.text((24, 469), '1× playback  ·  separate device recordings  ·  4-second clips',
              font=font(13), fill='#a8bed4')
    background = args.recordings / f'{scene}-frame.png'
    frame.save(background)
    mp4 = args.output / f'{scene}-comparison.mp4'
    inputs = ['-loop', '1', '-framerate', '60', '-i', str(background)]
    for source in sources:
        inputs += ['-i', str(source)]
    filters = []
    for i in range(3):
        filters.append(f'[{i+1}:v]trim=start=1:end=5,setpts=PTS-STARTPTS,'
                       f'crop=1074:1341:48:1041,scale=264:330:flags=lanczos,fps=60[c{i}]')
    last = '0:v'
    for i, x in enumerate([24, 308, 592]):
        filters.append(f'[{last}][c{i}]overlay={x}:119:shortest=1[b{i}]')
        last = f'b{i}'
    command(inputs + ['-filter_complex', ';'.join(filters), '-map', f'[{last}]',
                      '-t', '4', '-an', '-c:v', 'libx264', '-preset', 'slow', '-crf', '18',
                      '-pix_fmt', 'yuv420p', '-movflags', '+faststart', str(mp4)])
    gif = args.output / f'{scene}-comparison.gif'
    preview = 'fps=25' if scene == 'shape' else 'fps=20,scale=760:-2:flags=lanczos'
    palette = 'max_colors=192' if scene == 'shape' else 'max_colors=128'
    command(['-i', str(mp4), '-filter_complex',
             f'[0:v]{preview},split[a][b];[a]palettegen={palette}[p];[b][p]paletteuse=dither=bayer:bayer_scale=3',
             '-loop', '0', str(gif)])
    manifest['scenes'][scene] = {
        'sourceVideoSHA256': {backend: hashlib.sha256(source.read_bytes()).hexdigest()
                             for backend, source in zip(backends, sources)},
        'gif': gif.name, 'video': mp4.name}
    print(f'{scene}: GIF {gif.stat().st_size / 1048576:.2f} MiB, MP4 {mp4.stat().st_size / 1048576:.2f} MiB', flush=True)
(args.output / 'capture-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
