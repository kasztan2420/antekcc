"""Minimal Serum 2 .SerumPreset writer.

Container (little-endian):
    b"XferJson\\0" | u64 len(meta) | meta JSON | u32 len(cbor) | u32 2 | zstd(cbor(state))
meta["hash"] is the MD5 hex digest of the zstd block.

The state is a CBOR map of modules (Oscillator0..4, VoiceFilter0..1, Env0..3,
LFO0..9, Macro0..7, ModSlot0..63, FXRack0..2, RoutingSlot0..6, Global0, ...).
Every module has "plainParams": either "default" or a dict holding only the
non-default parameters, in real units.

Units used below (checked against presets saved by Serum 2 and the measured
tables of github.com/btesser/serum2vital):
    Oscillator  kParamVolume 0..1 knob (0.75 default), kParamOctave int,
                kParamPitch semitones, kParamFine cents, kParamPan -50..50,
                kParamUnison voices, kParamDetune 0..1
    WTOsc       kParamTablePos 1..256 across the whole table,
                kParamRandomPhase / kParamInitialPhase
    VoiceFilter kParamFreq 0..1 (8 Hz * (22050/8)**n), kParamReso %, kParamDrive %
    Env         kParamAttack/Hold/Decay/Release seconds, kParamSustain 0..1
    LFO         kParamBeatSync 0 => kParamRate is Hz; kParamMode "Free"
    ModSlot     kParamAmount -100..100 % of the destination's range
    FX          Hz / ms / seconds / % as Serum displays them
"""
from __future__ import annotations

import copy
import hashlib
import json
import math
import struct
from pathlib import Path

import cbor2
import zstandard

MAGIC = b"XferJson\x00"
INIT = Path(__file__).with_name("init_state.json")

# Factory wavetables (path relative to Serum 2's Tables folder -> sample count).
TABLES = {
    "PolySaw II": ("S2 Tables/Analog/PolySaw II.wav", 10240),
    "Yet Another Saw": ("S2 Tables/Analog/Yet Another Saw.wav", 2048),
    "AT Juno 106": ("S2 Tables/Analog/AT Juno 106.wav", 6144),
    "SynStringSaw": ("S2 Tables/Analog/SynStringSaw.wav", 53248),
    "Saw Drift": ("S2 Tables/Analog/Saw Drift.wav", 165888),
    "Solina Viola": ("S2 Tables/Analog/Solina Viola.wav", 421888),
    "Mello": ("S2 Tables/Analog/Mello.wav", 65536),
    "Triangle Sub Morph": ("S2 Tables/Analog/Triangle Sub Morph.wav", 8192),
    "RMrK1 Tine": ("S2 Tables/Digital/RMrK1 Tine.wav", 4096),
    "FM Piano": ("S2 Tables/Digital/FM Piano.wav", 4096),
    "Memory Organ": ("S2 Tables/Digital/Memory Organ.wav", 16384),
    "Basic OPL": ("S2 Tables/Digital/Basic OPL.wav", 16384),
    "Braids Bell Pluck": ("S2 Tables/Digital/Braids Bell Pluck.wav", 88064),
    "Xylo Pluck": ("S2 Tables/Digital/Xylo Pluck.wav", 260096),
    "Vocal Hum": ("S2 Tables/Digital/Vocal Hum.wav", 514048),
    "Mario": ("Digital/Mario.wav", 8192),
}

# Factory noise samples (relative to the Noises folder) -> (samples, channels).
NOISES = {
    "Air Can 1": ("Organics/Air Can 1.wav", 82688, 1),
    "H-Breath": ("Organics/H-Breath.wav", 41346, 1),
}

# Mod matrix source ids.
SRC_ENV = {1: 2, 2: 3, 3: 4, 4: 5}
SRC_LFO = {n: 5 + n for n in range(1, 11)}
SRC_VELOCITY = 16
SRC_MODWHEEL = 1
SRC_MACRO = {n: 24 + n for n in range(1, 9)}

# (destModuleTypeString, destModuleParamName) -> destModuleParamID.
PARAM_IDS = {
    ("Oscillator", "kParamVolume"): 1,
    ("Oscillator", "kParamFine"): 5,
    ("VoiceFilter", "kParamFreq"): 3,
    ("FXReverb", "kParamWet"): 1,
    ("FXDelay", "kParamWet"): 1,
}

FX_TYPES = {
    "FXDistortion": 0, "FXChorus": 3, "FXDelay": 4, "FXComp": 5,
    "FXReverb": 6, "FXEQ": 7, "FXHyperD": 9,
}

OSC = {"A": 0, "B": 1, "C": 2, "N": 3, "S": 4}

# Synced delay: stored seconds are a knob position, quantised by Serum.
DELAY_SYNC = {"1/8": 0.0387, "1/4": 0.0832, "1/2": 0.15}

# Curve layouts copied from presets saved by Serum 2.
_LFO_TRIANGLE = {
    "curveVals": [0.5, 0.5, 0.5],
    "loopbackPointNum": 65,
    "numPoints": 2,
    "xVals": [0.0, 0.5, 1.0],
    "yVals": [1.0, 0.0, 1.0],
}
_FLEX_LINEAR = {
    "curveVals": [0.5, 0.5],
    "numPoints": 1,
    "xVals": [0.0, 1.0],
    "yVals": [1.0, 0.0],
}


def cutoff(hz: float) -> float:
    """Hz -> Serum's 0..1 filter knob (8 Hz .. 22.05 kHz, exponential)."""
    hz = min(max(hz, 8.0), 22050.0)
    return math.log(hz / 8.0) / math.log(22050.0 / 8.0)


def frame(k: int, frames: int) -> float:
    """1-based frame k of a table with `frames` frames -> kParamTablePos."""
    return 1.0 if frames <= 1 else 1.0 + (k - 1) * 255.0 / (frames - 1)


def _num(v):
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else v


class Patch:
    def __init__(self, name: str, author: str, tags: list[str], description: str = ""):
        init = json.loads(INIT.read_text())
        self.meta = init["meta"]
        self.s = init["state"]
        self.name = name
        for target in (self.meta, self.s):
            target["presetName"] = name
            target["presetAuthor"] = author
            target["presetDescription"] = description
            target["tags"] = list(tags)
        self._slot = 0

    # -- low level -------------------------------------------------------------
    @staticmethod
    def _set(block: dict, **params) -> None:
        if not isinstance(block.get("plainParams"), dict):
            block["plainParams"] = {}
        for k, v in params.items():
            if v is not None:
                block["plainParams"]["kParam" + k] = _num(v)

    # -- sources -----------------------------------------------------------------
    def osc(self, slot: str, table: str, pos: float = 1.0, vol: float = 0.75, octave: int = 0,
            unison: int = 1, detune: float | None = None, fine: float | None = None,
            pan: float | None = None, retrigger: bool = False) -> "Patch":
        i = OSC[slot]
        path, samples = TABLES[table]
        osc = self.s[f"Oscillator{i}"]
        wt = osc[f"WTOsc{i}"]
        wt.update({"relativePathToWT": path, "numFrames": samples, "numChannels": 1, "sampleRate": 44100})
        self._set(wt, TablePos=pos if pos != 1.0 else None, RandomPhase=0.0 if retrigger else None)
        self._set(osc, Enable=1.0, Volume=vol, Octave=octave or None,
                  Unison=unison if unison > 1 else None,
                  Detune=detune if unison > 1 else None, Fine=fine, Pan=pan)
        self.route(slot)
        return self

    def noise(self, sample: str, vol: float) -> "Patch":
        path, samples, channels = NOISES[sample]
        osc = self.s["Oscillator3"]
        osc["NoiseOsc3"].update({"relativePathToNoiseSample": path, "numFrames": samples,
                                 "numChannels": channels, "sampleRate": 44100})
        self._set(osc, Enable=1.0, Volume=vol)
        self.route("N")
        return self

    def route(self, slot: str, dest: str = "kRoutingDestFilter") -> None:
        self._set(self.s[f"RoutingSlot{OSC[slot]}"], RoutingDest=dest)

    # -- voice -------------------------------------------------------------------
    def filt(self, ftype: str, hz: float, reso: float = 10.0, drive: float | None = None) -> "Patch":
        self._set(self.s["VoiceFilter0"], Enable=1.0, Type=ftype, Freq=cutoff(hz), Reso=reso, Drive=drive)
        return self

    def env(self, n: int, a: float, d: float, s: float, r: float, h: float | None = None) -> "Patch":
        self._set(self.s[f"Env{n - 1}"], Attack=a, Hold=h, Decay=d, Sustain=s, Release=r)
        return self

    def lfo(self, n: int, hz: float) -> "Patch":
        block = self.s[f"LFO{n - 1}"]
        block["curveData"] = copy.deepcopy(_LFO_TRIANGLE)
        self._set(block, BeatSync=0.0, Rate=hz, Mode="Free", DefaultMode=0.0)
        return self

    def mod(self, source: int, dest_type: str, dest_id: int, param: str, amount: float,
            bipolar: bool = False, aux: int = 0) -> "Patch":
        if self._slot >= 64:
            raise RuntimeError(f"{self.name}: out of mod slots")
        params = {"kParamAmount": float(amount)}
        if bipolar:
            params["kParamBipolar"] = 1.0
        self.s[f"ModSlot{self._slot}"] = {
            "destModuleID": dest_id,
            "destModuleParamID": PARAM_IDS[(dest_type, param)],
            "destModuleParamName": param,
            "destModuleTypeString": dest_type,
            "plainParams": params,
            "source": [source, aux],
        }
        self._slot += 1
        return self

    def wow(self, lfo: int, hz: float, cents: float, *slots: str) -> "Patch":
        """Tape-style pitch drift: a free LFO swinging Fine by +-cents, centred on the note."""
        self.lfo(lfo, hz)
        for slot in slots:
            self.mod(SRC_LFO[lfo], "Oscillator", OSC[slot], "kParamFine", cents, bipolar=True)
        return self

    def macro(self, n: int, name: str, value: float = 0.0) -> "Patch":
        block = self.s[f"Macro{n - 1}"]
        block["name"] = name
        if value:
            self._set(block, Value=value)
        return self

    def glob(self, volume: float, poly: int | None = None, mono: bool = False,
             porta: float | None = None) -> "Patch":
        self._set(self.s["Global0"], MasterVolume=volume, PolyCount=poly,
                  MonoToggle=1.0 if mono else None, Legato=1.0 if mono else None,
                  PortamentoTime=porta)
        return self

    # -- effects -----------------------------------------------------------------
    def fx(self, kind: str, **params) -> int:
        """Append an effect to the main rack; returns its module id for the mod matrix."""
        entry: dict = {kind: {"plainParams": {}}, "type": FX_TYPES[kind]}
        if kind == "FXHyperD":
            entry["kUIParamMixOrGainDimE"] = 0.0
            entry["kUIParamMixOrGainHyper"] = 0.0
        elif kind != "FXEQ":
            entry["kUIParamMixOrGain"] = 0.0
        if kind == "FXDistortion":
            entry["flex"] = [copy.deepcopy(_FLEX_LINEAR), copy.deepcopy(_FLEX_LINEAR)]
        self._set(entry[kind], **params)
        rack = self.s["FXRack0"]["FX"]
        rack.append(entry)
        return len(rack) - 1

    def hyper(self, wet: float, detune: float = 25.0, unison: int = 4, dim_size: float = 0.0,
              dim_wet: float = 0.0) -> int:
        return self.fx("FXHyperD", Wet=wet, Detune=detune, Unison=unison,
                       DimESize=dim_size or None, DimEWet=dim_wet or None)

    def chorus(self, wet: float, rate_hz: float = 0.4, depth_ms: float = 6.0,
               delay_ms: float = 6.0, delay2_ms: float = 9.0, feedback: float = 10.0,
               lowpass_hz: float = 9000.0) -> int:
        return self.fx("FXChorus", BeatSync=0.0, Rate=rate_hz, Depth=depth_ms, Delay=delay_ms,
                       Delay2=delay2_ms, Feedback=feedback, Filt=lowpass_hz, Wet=wet)

    def eq(self, highpass_hz: float, shelf_hz: float = 9000.0, shelf_db: float = 0.0) -> int:
        return self.fx("FXEQ", Type1=2.0, Freq1=highpass_hz, Freq2=shelf_hz, Gain2=shelf_db or None)

    def tape(self, drive: float, mode: str = "kTapeSat") -> int:
        return self.fx("FXDistortion", Mode=mode, Drive=drive, Wet=100.0)

    def delay(self, wet: float, division: str = "1/8", dotted: bool = True, feedback: float = 35.0,
              pingpong: bool = True, tone_hz: float = 1600.0, bandwidth: float = 2.5) -> int:
        t = DELAY_SYNC[division]
        offset = 1.5 if dotted else None
        return self.fx("FXDelay", BeatSync=1.0, TimeL=t, TimeR=t, OffsetL=offset, OffsetR=offset,
                       Link=1.0, Mode=1.0 if pingpong else None, Feedback=feedback,
                       Freq=tone_hz, BW=bandwidth, Wet=wet)

    def reverb(self, kind: str, size: float, wet: float, decay: float | None = None,
               locut: float = 20.0, hicut: float = 40.0, damp: float = 40.0,
               predelay_s: float = 0.02) -> int:
        """kind: kPlate / kHall / kVintage. `decay` is kParamDelay (Hall decay control)."""
        return self.fx("FXReverb", Type=kind if kind != "kPlate" else None, Size=size, Wet=wet,
                       Delay=decay, Freq=locut, FreqB=hicut, FreqC=damp, PreDelay=predelay_s)

    # -- output ------------------------------------------------------------------
    def encode(self) -> bytes:
        _collapse_defaults(self.s)
        raw = cbor2.dumps(self.s)
        blob = zstandard.ZstdCompressor(level=3).compress(raw)
        meta = dict(self.meta, hash=hashlib.md5(blob).hexdigest())
        js = json.dumps(meta, separators=(",", ":"), sort_keys=True).encode()
        return MAGIC + struct.pack("<Q", len(js)) + js + struct.pack("<II", len(raw), 2) + blob

    def write(self, path: Path) -> Path:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(self.encode())
        return path


def _collapse_defaults(node) -> None:
    """Serum saves an untouched module as plainParams "default", never as an empty map."""
    if isinstance(node, dict):
        if node.get("plainParams") == {}:
            node["plainParams"] = "default"
        for v in node.values():
            _collapse_defaults(v)
    elif isinstance(node, list):
        for v in node:
            _collapse_defaults(v)


def decode(path: Path) -> tuple[dict, dict]:
    data = Path(path).read_bytes()
    if not data.startswith(MAGIC):
        raise ValueError(f"{path}: not a Serum 2 preset")
    n = struct.unpack_from("<Q", data, len(MAGIC))[0]
    meta = json.loads(data[17:17 + n])
    raw_len, encoding = struct.unpack_from("<II", data, 17 + n)
    blob = data[25 + n:]
    if encoding != 2 or meta.get("hash") != hashlib.md5(blob).hexdigest():
        raise ValueError(f"{path}: bad encoding or hash")
    raw = zstandard.ZstdDecompressor().decompress(blob, max_output_size=raw_len)
    if len(raw) != raw_len:
        raise ValueError(f"{path}: payload length mismatch")
    return meta, cbor2.loads(raw)
