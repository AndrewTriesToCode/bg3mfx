#!/usr/bin/env python3
"""Inspect local diagnostic waterfall mesh captures; never writes game assets."""
import argparse
import json
from pathlib import Path
import struct


def analyze(path):
    info = json.loads(path.read_text())
    layout = info['pipeline']['vertexLayout']
    color = next(a for a in layout['attributes'] if a['attribute'] == 6)
    stream = next(b for b in layout['layouts'] if b['buffer'] == color['buffer'])
    if color['format'] != 9 or stream['stepFunction'] != 1 or stream['stepRate'] != 1:
        raise ValueError('Expected per-vertex UChar4Normalized color')
    stride, offset = stream['stride'], color['offset']
    if stride <= 0 or offset < 0 or offset + 4 > stride:
        raise ValueError('Invalid color layout')

    def read_binding(name):
        binding = info['bindings'][name]
        data = (path.parent / binding['file']).read_bytes()
        if len(data) != binding['capturedLength']:
            raise ValueError(f'{name}: incomplete buffer readback')
        # Capture bytes already start at the native binding offset.
        return data

    draw = info['draw']
    sizes = {0: ('H', 2), 1: ('I', 4)}
    if draw['indexType'] not in sizes:
        raise ValueError('Unsupported index type')
    code, size = sizes[draw['indexType']]
    count = draw['indexCount']
    indices = read_binding('index')
    if count <= 0 or count * size > len(indices):
        raise ValueError('Empty or truncated index capture')
    vertices = sorted({i + draw['baseVertex'] for (i,) in
                       struct.iter_unpack('<' + code, indices[:count * size])})
    data = read_binding(f"vertex:{color['buffer']}")
    if vertices[0] < 0 or vertices[-1] * stride + offset + 4 > len(data):
        raise ValueError('Referenced vertex lies outside captured bytes')
    green = [data[i * stride + offset + 1] for i in vertices]
    zero = [i for i, g in zip(vertices, green) if g == 0]
    return {'capture': str(path), 'shader': info['pipeline']['vertex'],
            'mode': info['mode'], 'indices': count, 'uniqueVertices': len(vertices),
            'zeroGreenVertices': zero, 'greenByteRange': [min(green), max(green)],
            'limitation': 'Mesh evidence only; does not replay shader or prove a repair.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('captures', type=Path, nargs='+')
    args = parser.parse_args()
    failed = False
    for path in args.captures:
        try:
            print(json.dumps(analyze(path)))
        except (ValueError, KeyError, StopIteration, OSError) as error:
            print(json.dumps({'capture': str(path), 'error': str(error)}))
            failed = True
    return int(failed)


if __name__ == '__main__':
    raise SystemExit(main())
