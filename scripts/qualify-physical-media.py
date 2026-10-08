#!/usr/bin/env python3
"""Full saved-media checks. Output dimensions do not qualify upload geometry,
fresh motion, visible scoring or perceptual synchronization; those are separate gates.
"""
import argparse
import bisect
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import time


def summarize_media(data):
    streams = {s['codec_type']: s for s in data['streams']}
    assert set(streams) == {'video', 'audio'} and len(data['streams']) == 2, 'Require exactly one video and audio stream'
    frames = data['frames']
    video = [float(f['best_effort_timestamp_time']) for f in frames if f['media_type'] == 'video']
    audio = [f for f in frames if f['media_type'] == 'audio']
    rate = int(streams['audio']['sample_rate'])
    assert len(video) >= 2 and len(audio) >= 2 and rate > 0, 'Missing decoded A/V samples'
    assert all(math.isfinite(t) for t in video), 'Nonfinite video timestamp'
    gaps = [b-a for a, b in zip(video, video[1:])]
    audio_gaps = [float(b['best_effort_timestamp_time'])-float(a['best_effort_timestamp_time'])-int(a['nb_samples'])/rate for a, b in zip(audio, audio[1:])]
    assert all(math.isfinite(g) for g in audio_gaps), 'Nonfinite audio timing'
    rolling = [(bisect.bisect_left(video, t+5)-i)/5 for i, t in enumerate(video) if t+5 <= video[-1]]
    assert rolling, 'Need at least five seconds of video'
    expected = round((video[-1]-video[0])*30)+1
    ends = {kind: float(s['start_time'])+float(s['duration']) for kind, s in streams.items()}
    return {'streams': streams, 'videoFrames': len(video), 'audioSamples': sum(int(f['nb_samples']) for f in audio),
            'videoDurationSeconds': video[-1]-video[0], 'maximumVideoGapSeconds': max(gaps),
            'nonIncreasingVideoPTS': sum(g <= 0 for g in gaps), 'maximumAudioGapSeconds': max(audio_gaps),
            'maximumAudioOverlapSeconds': max(0, -min(audio_gaps)),
            'trackEndOffsetSeconds': abs(ends['video']-ends['audio']),
            'minimumRolling5sEncodedFPS': min(rolling), 'rolling5sWindows': len(rolling),
            'rolling5sFractionBelow24fps': sum(f < 24 for f in rolling)/len(rolling),
            'missingEncodedFractionAt30fps': max(0, expected-len(video))/expected}


def media_gates(summary, width, height, minimum_duration=0):
    v, a = summary['streams']['video'], summary['streams']['audio']
    return {'encoding': v['codec_name'] == 'h264' and a['codec_name'] == 'aac',
            'dimensions': v['width'] == width and v['height'] == height,
            'duration': summary['videoDurationSeconds'] >= minimum_duration,
            'videoOrder': summary['nonIncreasingVideoPTS'] == 0,
            'encodedCadence': summary['missingEncodedFractionAt30fps'] < .01 and summary['rolling5sFractionBelow24fps'] <= .01,
            'audioContinuity': summary['maximumAudioGapSeconds'] <= .005 and summary['maximumAudioOverlapSeconds'] <= .005,
            'trackEnds': summary['trackEndOffsetSeconds'] <= .1}


def native_packets(data, report, path):
    assert report['contract'] == 'scorebug-native-export-v1' and report['fullDecodeCompleted'] is True, 'Native full decode evidence required'
    assert report['fileName'] == path.name and report['bytes'] == path.stat().st_size, 'Native evidence must identify the exact transferred export'
    assert path.name.startswith(report['recordingID']+'-') and path.suffix == '.mp4', 'Native recording identity mismatch'
    streams = {s['codec_type']: s for s in data['streams']}
    rate = int(streams['audio']['sample_rate'])
    frames, pending_skip = [], 0
    for packet in data['packets']:
        if packet['codec_type'] != 'audio':
            frames.append({'media_type': packet['codec_type'], 'best_effort_timestamp_time': packet['pts_time']})
            continue
        samples = round(float(packet['duration_time'])*rate)
        assert samples > 0, 'Invalid encoded audio duration'
        discard = 0
        # AV_PKT_DATA_SKIP_SAMPLES describes codec priming/padding, not lost
        # playable audio. Priming can span several AAC packets (2,112 samples
        # on the phone); retain all other timestamp gaps and count checks.
        for side in packet.get('side_data_list', []):
            if side.get('side_data_type') != 'Skip Samples': continue
            skip, tail = side.get('skip_samples', 0), side.get('discard_padding', 0)
            assert type(skip) is int and type(tail) is int and skip >= 0 and tail >= 0, 'Invalid audio padding metadata'
            pending_skip += skip
            discard += tail
        skipped = min(samples, pending_skip)
        pending_skip -= skipped
        assert discard <= samples-skipped, 'Audio padding exceeds its packet'
        kept = samples-skipped-discard
        if kept:
            frames.append({'media_type': 'audio',
                           'best_effort_timestamp_time': float(packet['pts_time'])+skipped/rate,
                           'nb_samples': kept})
    assert pending_skip == 0, 'Audio priming exceeds available packets'
    assert sum(f['media_type'] == 'video' for f in frames) == report['videoFrames'], 'Native decoded video count differs from packets'
    assert abs(sum(f['nb_samples'] for f in frames if f['media_type'] == 'audio')-report['audioSamples']) <= 1024, 'Native decoded audio count differs from packets'
    return {**data, 'frames': frames}


def inspect_media(path, artifact, index, ffprobe, native=None, width=1920, height=1080, minimum_duration=0):
    assert not path.is_symlink(), 'Require the original regular MP4 path'
    path = path.resolve(strict=True)
    assert path.is_file(), 'Require a saved regular MP4'
    output, error = artifact/f'probe-{index}.json', artifact/f'probe-{index}.log'
    mode = (['-show_packets', '-show_entries', 'packet=codec_type,pts_time,duration_time'] if native else
            ['-err_detect', 'explode', '-threads', '8', '-show_frames', '-show_entries', 'frame=media_type,best_effort_timestamp_time,nb_samples'])
    started = time.monotonic()
    with output.open('x') as stdout, error.open('x') as stderr:
        result = subprocess.run([ffprobe, '-v', 'error', *mode, '-show_streams', '-show_format', '-of', 'json', str(path)], stdout=stdout, stderr=stderr, timeout=2400)
    errors = error.read_text()
    assert result.returncode == 0 and not errors, f'Full media inspection failed: {error}'
    data = json.loads(output.read_text())
    if native: data = native_packets(data, native, path)
    summary = summarize_media(data)
    with path.open('rb') as handle: digest = hashlib.file_digest(handle, 'sha256').hexdigest()
    gates = media_gates(summary, width, height, minimum_duration)
    return {'file': str(path), 'sha256': digest, 'bytes': path.stat().st_size,
            'decodeEngine': 'production AVFoundation full decode + packet correlation' if native else 'ffprobe/libavcodec full decode with explode',
            'elapsedSeconds': time.monotonic()-started, 'summary': summary, 'gates': gates, 'passed': all(gates.values())}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--artifact', type=Path, required=True)
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--proxy', type=Path, required=True)
    parser.add_argument('--mock', type=Path, required=True)
    parser.add_argument('--native-validation', type=Path)
    parser.add_argument('--minimum-duration', type=int, default=0)
    parser.add_argument('--ffprobe', default=os.getenv('FFPROBE_PATH', '/opt/homebrew/opt/ffmpeg-full/bin/ffprobe' if os.uname().sysname == 'Darwin' else 'ffprobe'))
    args = parser.parse_args()
    assert 0 <= args.minimum_duration <= 7200, 'Bounded duration required'
    args.artifact.mkdir(mode=0o700, parents=True, exist_ok=False)
    originals = [args.archive, args.proxy, args.mock]
    assert all(not path.is_symlink() for path in originals), 'Require original regular MP4 paths'
    paths = [path.resolve(strict=True) for path in originals]
    assert len(set(paths)) == 3, 'Require three distinct media files'
    native = json.loads(args.native_validation.read_text()) if args.native_validation else None
    report = {'contract': 'scorebug-physical-saved-media-v1', 'results': [], 'passed': False,
              'sustained1080Qualified': False, 'freshMotionQualified': False, 'visibleOverlayQualified': False, 'perceptualSyncQualified': False}
    try:
        for index, path in enumerate(paths):
            print(f'Inspecting {path.name}', flush=True)
            report['results'].append(inspect_media(path, args.artifact, index, args.ffprobe,
                native if index == 0 else None, 3840 if index == 0 else 1920, 2160 if index == 0 else 1080, args.minimum_duration))
        report['passed'] = all(r['passed'] for r in report['results'])
    except Exception as error:
        report['failure'] = str(error)
    (args.artifact/'result.json').write_text(json.dumps(report, indent=2)+'\n')
    raise SystemExit(0 if report['passed'] else 1)

if __name__ == '__main__': main()
