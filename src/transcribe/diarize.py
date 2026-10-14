"""Local speaker diarization via sherpa-onnx.

A screen recording gives us one mixed mono track, so speakers have to be
recovered from the audio itself. sherpa-onnx does this with two small ONNX
models (~46 MB total) and no PyTorch: pyannote segmentation finds speech turns,
a TitaNet embedding model gives each turn a voice fingerprint, and those get
clustered into distinct speakers.

Clustering yields anonymous labels ("Speaker 1", "Speaker 2"). Turning those
into real names is a separate, LLM-driven step -- see ``notes.resolve_speaker_names``.
"""

import os
import tarfile
import urllib.request
import wave

SHERPA_RELEASE = "https://github.com/k2-fsa/sherpa-onnx/releases/download"
SEGMENTATION_ARCHIVE = "sherpa-onnx-pyannote-segmentation-3-0"
SEGMENTATION_URL = f"{SHERPA_RELEASE}/speaker-segmentation-models/{SEGMENTATION_ARCHIVE}.tar.bz2"
# The upstream release tag really is spelled "recongition".
EMBEDDING_MODEL = "nemo_en_titanet_small.onnx"
EMBEDDING_URL = f"{SHERPA_RELEASE}/speaker-recongition-models/{EMBEDDING_MODEL}"


def model_dir():
    """Where the diarization ONNX models live, resolved per call so it follows $HOME."""
    return os.path.expanduser("~/.transcribe/models")


# A cluster holding less than this share of the meeting's speech is noise --
# crosstalk, a cough, a notification -- not a participant.
MICRO_CLUSTER_SHARE = 0.01
MICRO_CLUSTER_FLOOR_SECONDS = 5.0


class DiarizationUnavailable(RuntimeError):
    """Raised when diarization cannot run (missing dependency or model)."""


def _download(url, dest_path, label):
    """Download ``url`` to ``dest_path`` atomically, printing progress."""
    os.makedirs(os.path.dirname(dest_path), exist_ok=True)
    print(f"{label} not found. Downloading from {url} ...")

    def _report(block_num, block_size, total_size):
        if total_size <= 0:
            return
        pct = min(block_num * block_size * 100 // total_size, 100)
        print(f"\r  Downloading: {pct}%", end="")

    tmp_path = dest_path + ".part"
    try:
        urllib.request.urlretrieve(url, tmp_path, _report)
        print()
        os.replace(tmp_path, dest_path)
    except Exception:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)
        raise


def ensure_models(models_path=None):
    """Ensure both diarization models are present, downloading them if needed.

    Returns ``(segmentation_model_path, embedding_model_path)``.
    """
    models_path = models_path or model_dir()
    segmentation = os.path.join(models_path, SEGMENTATION_ARCHIVE, "model.onnx")
    if not os.path.exists(segmentation):
        archive = os.path.join(models_path, f"{SEGMENTATION_ARCHIVE}.tar.bz2")
        _download(SEGMENTATION_URL, archive, "Speaker segmentation model")
        with tarfile.open(archive, "r:bz2") as tar:
            _safe_extract(tar, models_path)
        os.unlink(archive)

    embedding = os.path.join(models_path, EMBEDDING_MODEL)
    if not os.path.exists(embedding):
        _download(EMBEDDING_URL, embedding, "Speaker embedding model")

    return segmentation, embedding


def _safe_extract(tar, dest_dir):
    """Extract a tarball, refusing members that escape ``dest_dir``."""
    dest_dir = os.path.abspath(dest_dir)
    for member in tar.getmembers():
        target = os.path.abspath(os.path.join(dest_dir, member.name))
        if not target.startswith(dest_dir + os.sep) and target != dest_dir:
            raise ValueError(f"Refusing to extract {member.name!r} outside {dest_dir}")
        if member.issym() or member.islnk():
            raise ValueError(f"Refusing to extract link member {member.name!r}")
    # Members are validated above; "data" additionally strips unsafe metadata
    # and is the default from Python 3.14.
    tar.extractall(dest_dir, filter="data")


def read_wav_window(audio_path, start=0.0, end=None):
    """Read a slice of a 16 kHz mono WAV as a float32 numpy array in [-1, 1].

    Reading only the window keeps memory bounded: a full 3-hour recording as
    float32 is ~800 MB, but a single meeting is a fraction of that.
    """
    try:
        import numpy as np
    except ImportError as e:  # pragma: no cover - exercised only without numpy
        raise DiarizationUnavailable(
            "numpy is required for diarization. Install with: pip install 'transcribe[diarize]'"
        ) from e

    with wave.open(audio_path, "rb") as handle:
        rate = handle.getframerate()
        total = handle.getnframes()
        start_frame = min(max(int(start * rate), 0), total)
        end_frame = total if end is None else min(max(int(end * rate), start_frame), total)
        handle.setpos(start_frame)
        raw = handle.readframes(end_frame - start_frame)

    samples = np.frombuffer(raw, dtype=np.int16).astype(np.float32)
    del raw  # the byte buffer is twice the size of nothing useful from here on
    # Scale in place. `samples / 32768.0` would allocate a second full-size array,
    # which on a multi-hour meeting is another ~800 MB for no reason.
    samples /= 32768.0
    return samples


def diarize_window(audio_path, config=None, start=0.0, end=None, num_speakers=None):
    """Cluster speakers within one window of an audio file.

    Returns a list of ``(start, end, cluster_id)`` tuples with times expressed
    relative to the start of the *file*, not the window.

    ``num_speakers`` pins the cluster count -- pass it when the attendee list is
    known, since a fixed count is far more reliable than threshold-based
    clustering on short or lopsided conversations.
    """
    config = config or {}
    try:
        import sherpa_onnx
    except ImportError as e:
        raise DiarizationUnavailable(
            f"sherpa-onnx could not be imported ({str(e).splitlines()[0]}). "
            "Install with: pip install 'transcribe[diarize]'"
        ) from e

    segmentation_model, embedding_model = ensure_models(config.get("diarization_model_dir"))
    samples = read_wav_window(audio_path, start, end)
    if len(samples) == 0:
        return []

    threads = int(config.get("diarization_threads") or 8)
    # How far the segmentation window advances each step, as a fraction of its
    # length. The upstream default of 0.1 means 10x overlap: on a 15-minute
    # sample it ran at 10.9x realtime versus 28.9x at 0.25, for the same turns.
    shift_ratio = float(config.get("diarization_window_shift_ratio", 0.25))
    clustering = sherpa_onnx.FastClusteringConfig(
        num_clusters=int(num_speakers) if num_speakers else -1,
        threshold=float(config.get("diarization_threshold", 0.8)),
    )
    diarizer = sherpa_onnx.OfflineSpeakerDiarization(
        sherpa_onnx.OfflineSpeakerDiarizationConfig(
            segmentation=sherpa_onnx.OfflineSpeakerSegmentationModelConfig(
                pyannote=sherpa_onnx.OfflineSpeakerSegmentationPyannoteModelConfig(
                    model=segmentation_model, window_shift_ratio=shift_ratio
                ),
                num_threads=threads,
            ),
            embedding=sherpa_onnx.SpeakerEmbeddingExtractorConfig(
                model=embedding_model, num_threads=threads
            ),
            clustering=clustering,
            min_duration_on=float(config.get("diarization_min_duration_on", 0.3)),
            min_duration_off=float(config.get("diarization_min_duration_off", 0.5)),
        )
    )

    result = diarizer.process(samples).sort_by_start_time()
    return [(start + turn.start, start + turn.end, turn.speaker) for turn in result]


def _drop_micro_clusters(turns, share=MICRO_CLUSTER_SHARE, floor=MICRO_CLUSTER_FLOOR_SECONDS):
    """Discard clusters holding a negligible share of the meeting's speech.

    Threshold-based clustering spawns spurious one-off clusters from crosstalk,
    coughs and notifications. The cut is proportional rather than absolute so it
    behaves the same on a 10-minute call and a 3-hour one.
    """
    totals = {}
    for turn_start, turn_end, cluster in turns:
        totals[cluster] = totals.get(cluster, 0.0) + (turn_end - turn_start)
    min_total = max(floor, sum(totals.values()) * share)
    keep = {cluster for cluster, total in totals.items() if total >= min_total}
    # Never drop everything -- if all clusters are tiny, keep the largest.
    if not keep and totals:
        keep = {max(totals, key=totals.get)}
    return [turn for turn in turns if turn[2] in keep]


def label_clusters(turns):
    """Map raw cluster ids to stable ``Speaker N`` labels ordered by talk time."""
    totals = {}
    for turn_start, turn_end, cluster in turns:
        totals[cluster] = totals.get(cluster, 0.0) + (turn_end - turn_start)
    ordered = sorted(totals, key=lambda cluster: -totals[cluster])
    return {cluster: f"Speaker {i}" for i, cluster in enumerate(ordered, start=1)}


def assign_speakers(segments, turns):
    """Attribute each transcript segment to the speaker it overlaps most.

    Mutates and returns ``segments``. Segments with no overlapping turn keep
    ``speaker = None`` rather than being forced onto a neighbour.
    """
    turns = _drop_micro_clusters(turns)
    if not turns:
        return segments

    labels = label_clusters(turns)
    for segment in segments:
        overlap_by_speaker = {}
        for turn_start, turn_end, cluster in turns:
            if turn_end <= segment.start:
                continue
            if turn_start >= segment.end:
                break  # turns are sorted, so nothing later can overlap
            overlap = min(segment.end, turn_end) - max(segment.start, turn_start)
            if overlap > 0:
                label = labels[cluster]
                overlap_by_speaker[label] = overlap_by_speaker.get(label, 0.0) + overlap
        if overlap_by_speaker:
            segment.speaker = max(overlap_by_speaker, key=overlap_by_speaker.get)
    return segments


def diarize_meeting(meeting, audio_path, config=None, num_speakers=None):
    """Diarize one meeting's audio window and attribute its segments in place.

    Returns True when speakers were assigned, False when diarization was
    unavailable -- the pipeline continues either way, just without attribution.
    """
    try:
        turns = diarize_window(
            audio_path,
            config=config,
            start=meeting.start,
            end=meeting.end,
            num_speakers=num_speakers,
        )
    except DiarizationUnavailable as e:
        print(f"Warning: skipping speaker attribution ({e})")
        return False
    except Exception as e:
        print(f"Warning: diarization failed ({type(e).__name__}: {e})")
        return False

    assign_speakers(meeting.segments, turns)
    return True
