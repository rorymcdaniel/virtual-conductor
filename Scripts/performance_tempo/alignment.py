"""Score-aware offline alignment using Sync Toolbox chroma and pitch onsets."""
import hashlib
import json
import os
from pathlib import Path

os.environ.setdefault('MPLBACKEND', 'Agg')
os.environ.setdefault('MPLCONFIGDIR', '/tmp/vc-tempo-matplotlib')

import librosa
import numpy as np
import pandas as pd
from synctoolbox.dtw.mrmsdtw import sync_via_mrmsdtw_with_anchors
from synctoolbox.dtw.utils import make_path_strictly_monotonic
from synctoolbox.feature.chroma import pitch_to_chroma, quantize_chroma
from synctoolbox.feature.csv_tools import df_to_pitch_features, df_to_pitch_onset_features
from synctoolbox.feature.dlnco import pitch_onset_features_to_DLNCO
from synctoolbox.feature.pitch import audio_to_pitch_features
from synctoolbox.feature.pitch_onset import audio_to_pitch_onset_features

RATE = 50
SAMPLE_RATE = 22050


def sha256(path):
    with open(path, 'rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def audio_features(recording, cache):
    key = sha256(recording)
    path = Path(cache) / f'audio-{key}-v2.npz'
    if path.exists():
        data = np.load(path)
        return {k: data[k] for k in data.files}
    print('Reading recording and estimating tuning…', flush=True)
    audio, _ = librosa.load(recording, sr=SAMPLE_RATE, mono=True)
    if len(audio) < 2 * SAMPLE_RATE or not np.all(np.isfinite(audio)):
        raise ValueError('The recording is empty, too short, or contains invalid samples.')
    # Limit tuning estimation memory; pitch feature extraction still uses the complete recording.
    tuning = int(round(100 * librosa.estimate_tuning(y=audio[::2], sr=SAMPLE_RATE / 2)))
    print(f'Extracting pitch and attack features (tuning {tuning:+d} cents)…', flush=True)
    chroma = quantize_chroma(pitch_to_chroma(audio_to_pitch_features(
        audio, Fs=SAMPLE_RATE, tuning_offset=tuning, feature_rate=RATE, verbose=False)))
    onset = pitch_onset_features_to_DLNCO(audio_to_pitch_onset_features(
        audio, Fs=SAMPLE_RATE, tuning_offset=tuning, verbose=False),
        feature_rate=RATE, feature_sequence_length=chroma.shape[1])
    hop = 441
    rms = np.sqrt(np.mean(audio[:len(audio) // hop * hop].reshape(-1, hop) ** 2, axis=1))
    threshold = max(float(np.percentile(rms, 90)) * 0.15, 1e-6)
    # Ignore isolated room-noise transients before the first musical attack.
    active = np.flatnonzero(np.convolve((rms > threshold).astype(int), np.ones(10), 'valid') >= 9)
    if not len(active):
        raise ValueError('No audible music was detected.')
    result = dict(chroma=chroma, onset=onset, tuning=tuning, duration=len(audio) / SAMPLE_RATE,
                  start=max(0., active[0] / RATE - 0.06),
                  end=min(len(audio) / SAMPLE_RATE, (active[-1] + 10) / RATE + 0.08))
    np.savez_compressed(path, **result)
    return result


def score_features(notes, end):
    # Neutral 120-BPM coordinate system; original score tempos do not bias the match.
    rows = [(q / 2, duration / 2, pitch, velocity, str(track))
            for q, duration, pitch, velocity, track in notes]
    df = pd.DataFrame(rows, columns=['start', 'duration', 'pitch', 'velocity', 'instrument'])
    chroma = quantize_chroma(pitch_to_chroma(df_to_pitch_features(df, feature_rate=RATE)))
    onset = pitch_onset_features_to_DLNCO(df_to_pitch_onset_features(df),
        feature_rate=RATE, feature_sequence_length=chroma.shape[1])
    size = int(end * RATE / 2) + 1
    return (np.pad(chroma, ((0, 0), (0, max(0, size - chroma.shape[1]))))[:, :size],
            np.pad(onset, ((0, 0), (0, max(0, size - onset.shape[1]))))[:, :size])


def read_anchors(path, end, duration):
    if path is None:
        return []
    rows = json.loads(Path(path).read_text())
    result = []
    for row in rows:
        q, t = float(row['quarter']), float(row['seconds'])
        if not np.isfinite(q + t) or not q.is_integer() or not 0 <= q <= end or not 0 <= t < duration:
            raise ValueError('Anchors need whole quarter beats inside the score and seconds inside the recording.')
        if result and (q <= result[-1][0] or t <= result[-1][1]):
            raise ValueError('Anchors must increase strictly in both score position and recording time.')
        result.append((q, t))
    return result


def align(features, notes, end, anchors=(), start=None, finish=None):
    if min(n[0] for n in notes) > 0 and start is None and not (anchors and anchors[0][0] == 0):
        raise ValueError('The score starts with silence. Specify --start at the silent first beat in the recording.')
    start = float(features['start']) if start is None else start
    finish = float(features['end']) if finish is None else finish
    if anchors and anchors[0][0] == 0:
        start = anchors[0][1]
    if anchors and anchors[-1][0] == end:
        finish = anchors[-1][1]
    duration = float(features['duration'])
    if not 0 <= start < finish <= duration:
        raise ValueError('Recording start/end are invalid.')
    first, last = round(start * RATE), round(finish * RATE)
    if last - first < 100:
        raise ValueError('Select at least two seconds of music.')
    start, finish = first / RATE, last / RATE
    ac, ao = features['chroma'][:, first:last + 1], features['onset'][:, first:last + 1]
    sc, so = score_features(notes, end)
    pairs = [(t - start, q / 2) for q, t in anchors if 0 < q < end]
    if any(not 0 < a < finish - start for a, _ in pairs):
        raise ValueError('An anchor lies outside the selected recording interval.')
    print('Matching score positions to the performance…', flush=True)
    path = sync_via_mrmsdtw_with_anchors(f_chroma1=ac, f_chroma2=sc, f_onset1=ao, f_onset2=so,
        input_feature_rate=RATE, step_weights=np.array([1.5, 1.5, 2.]),
        threshold_rec=10**6, anchor_pairs=pairs or None, verbose=False)
    strict = make_path_strictly_monotonic(path)
    # No observation supports a change of speed inside a completely held sonority.
    # Interpolate between note attacks instead of differentiating arbitrary DTW stairs.
    quarters = np.array(sorted({0., float(end), *[n[0] for n in notes]}))
    observed = np.interp(quarters * RATE / 2, strict[1], strict[0]) / RATE + start
    observed[0], observed[-1] = start, finish
    # Enforce user landmarks exactly in the interpolation as well as in the DTW search.
    for q, t in anchors:
        index = np.searchsorted(quarters, q)
        if index < len(quarters) and quarters[index] == q:
            observed[index] = t
        else:
            quarters = np.insert(quarters, index, q)
            observed = np.insert(observed, index, t)
    times = np.interp(np.arange(end + 1), quarters, observed)
    if np.any(np.diff(times) <= 0):
        raise ValueError('Alignment collapsed beats. Add landmarks around the ambiguous passage.')
    x, y = path.astype(int)
    similarity = np.sum(ac[:, x] * sc[:, y], axis=0) / np.maximum(
        np.linalg.norm(ac[:, x], axis=0) * np.linalg.norm(sc[:, y], axis=0), 1e-12)
    measures = []
    for q in range(0, end, 4):
        values = similarity[(y >= q * RATE / 2) & (y < (q + 4) * RATE / 2)]
        local = 60 / np.diff(times[q:q + 5])
        similarity_mean = float(np.mean(values)) if len(values) else 0.
        reasons = []
        if similarity_mean < 0.65:
            reasons.append('weak pitch match')
        if max(local) / min(local) > 1.7:
            reasons.append('uneven beat timing')
        if q == 0 or q == end - 4:
            reasons.append('check recording boundary')
        measures.append(dict(measure=q // 4 + 1, seconds=float(times[q]),
                             bpm=float(240 / (times[q + 4] - times[q])),
                             similarity=similarity_mean, review=reasons))
    return times, measures, path
