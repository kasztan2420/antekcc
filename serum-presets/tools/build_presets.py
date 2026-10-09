#!/usr/bin/env python3
"""Builds the "Drain Dreams" Serum 2 bank.

Cloud-rap / Drain Gang palette (Whitearmor, Yung Sherman, Blank Body):
wide detuned saws, glassy keys, chip leads, bells and big washed pads.

"Detuned but in key": the only pitch offsets are whole octaves; width comes
from symmetric unison detune, chorus and Hyper, and the tape wobble is a
bipolar LFO on Fine pitch, so every note stays centred on its own pitch.

Usage:  python build_presets.py [output_dir]
"""
from __future__ import annotations

import sys
from pathlib import Path

from serum2 import OSC, SRC_ENV, SRC_LFO, SRC_MACRO, SRC_MODWHEEL, SRC_VELOCITY, Patch, frame

AUTHOR = "kasztan"
PACK = "Drain Dreams"

OPL_SINE = 1.0                  # Basic OPL frame 1: pure sine
OPL_ABS_SINE = frame(3, 8)      # Basic OPL frame 3: abs-sine (octave-up, hollow)


def brightness_space(p: Patch, reverb_id: int, cutoff_amount: float = 25.0, space_amount: float = 40.0) -> Patch:
    """Macro 1 opens the filter, Macro 2 pushes the reverb."""
    p.macro(1, "Brightness").macro(2, "Space")
    p.mod(SRC_MACRO[1], "VoiceFilter", 0, "kParamFreq", cutoff_amount)
    p.mod(SRC_MACRO[2], "FXReverb", reverb_id, "kParamWet", space_amount)
    return p


def vibrato(p: Patch, lfo: int, hz: float, cents: float, wheel_cents: float, *slots: str) -> Patch:
    """Always-on light vibrato plus extra depth on the mod wheel."""
    p.lfo(lfo, hz)
    for slot in slots:
        p.mod(SRC_LFO[lfo], "Oscillator", OSC[slot], "kParamFine", cents, bipolar=True)
        p.mod(SRC_LFO[lfo], "Oscillator", OSC[slot], "kParamFine", wheel_cents, bipolar=True, aux=SRC_MODWHEEL)
    return p


# --------------------------------------------------------------------------- synths

def sy_whitearmor_supersaw() -> Patch:
    p = Patch("SY Whitearmor Supersaw", AUTHOR, ["Wavetable", "Poly", "Synth"],
              "9-voice trance saw + octave saw layer, Hyper, ping-pong 1/8., long hall. M1 Brightness, M2 Space.")
    p.osc("A", "PolySaw II", vol=0.68, unison=9, detune=0.22)
    p.osc("B", "Yet Another Saw", vol=0.36, octave=1, unison=5, detune=0.16)
    p.filt("MgL24", 7000, reso=8)
    p.env(1, a=0.004, d=1.2, s=0.85, r=0.7)
    p.wow(1, 0.32, 4, "A", "B")
    p.hyper(wet=20, detune=25, unison=4, dim_size=40, dim_wet=25)
    p.eq(140, shelf_hz=9000, shelf_db=-3)
    p.delay(wet=14, division="1/8", dotted=True, feedback=30)
    rv = p.reverb("kHall", size=65, wet=24, decay=45, locut=30, hicut=40, damp=35)
    p.glob(volume=0.5, poly=12)
    return brightness_space(p, rv)


def sy_sherman_juno_chords() -> Patch:
    p = Patch("SY Sherman Juno Chords", AUTHOR, ["Wavetable", "Poly", "Synth"],
              "Warm Juno chord synth with a soft filter bloom, chorus and plate. M1 Brightness, M2 Space.")
    p.osc("A", "AT Juno 106", vol=0.72, unison=4, detune=0.12)
    p.osc("B", "AT Juno 106", vol=0.36, octave=-1, unison=2, detune=0.08)
    p.filt("L12", 3200, reso=12)
    p.env(1, a=0.008, d=1.5, s=0.75, r=0.55)
    p.env(2, a=0.005, d=0.9, s=0.35, r=0.6)
    p.mod(SRC_ENV[2], "VoiceFilter", 0, "kParamFreq", 18)
    p.mod(SRC_VELOCITY, "VoiceFilter", 0, "kParamFreq", 8)
    p.wow(1, 0.45, 5, "A", "B")
    p.chorus(wet=35, rate_hz=0.35, depth_ms=6)
    p.eq(120, shelf_hz=8000, shelf_db=-2)
    p.delay(wet=10, division="1/4", dotted=True, feedback=28)
    rv = p.reverb("kPlate", size=32, wet=22, locut=30, hicut=45, damp=40)
    p.glob(volume=0.6, poly=12)
    return brightness_space(p, rv)


def sy_drain_saw_wash() -> Patch:
    p = Patch("SY Drain Saw Wash", AUTHOR, ["Wavetable", "Poly", "Synth"],
              "Darker drifting saw stack with air noise, tape and a big hall. M1 Brightness, M2 Space.")
    p.osc("A", "Saw Drift", pos=128.0, vol=0.66, unison=7, detune=0.2)
    p.osc("B", "SynStringSaw", pos=128.0, vol=0.3, octave=1, unison=3, detune=0.1)
    p.noise("Air Can 1", vol=0.12)
    p.filt("MgL12", 2600, reso=10)
    p.env(1, a=0.03, d=2.0, s=0.8, r=1.1)
    p.wow(1, 0.28, 7, "A", "B")
    p.lfo(2, 0.07)
    p.mod(SRC_LFO[2], "VoiceFilter", 0, "kParamFreq", 6, bipolar=True)
    p.tape(drive=18)
    p.chorus(wet=30, rate_hz=0.3, depth_ms=7)
    p.eq(130, shelf_hz=7000, shelf_db=-3)
    rv = p.reverb("kHall", size=75, wet=30, decay=50, locut=35, hicut=50, damp=50)
    p.glob(volume=0.55, poly=12)
    return brightness_space(p, rv)


def sy_cloud_pluck() -> Patch:
    p = Patch("SY Cloud Pluck", AUTHOR, ["Wavetable", "Poly", "Pluck"],
              "Juno pluck for arps and chops: filter-env snap into dotted-8th ping-pong. M1 Brightness, M2 Space.")
    p.osc("A", "AT Juno 106", vol=0.74, unison=3, detune=0.1)
    p.osc("B", "Basic OPL", pos=OPL_SINE, vol=0.3, octave=1, retrigger=True)
    p.filt("MgL24", 900, reso=15)
    p.env(1, a=0.001, d=0.9, s=0.25, r=0.5)
    p.env(2, a=0.0, d=0.35, s=0.1, r=0.3)
    p.mod(SRC_ENV[2], "VoiceFilter", 0, "kParamFreq", 35)
    p.mod(SRC_VELOCITY, "VoiceFilter", 0, "kParamFreq", 10)
    p.wow(1, 0.4, 4, "A", "B")
    p.chorus(wet=20, rate_hz=0.5, depth_ms=5)
    p.eq(160)
    p.delay(wet=22, division="1/8", dotted=True, feedback=45)
    rv = p.reverb("kHall", size=65, wet=25, decay=45, locut=35, hicut=40, damp=40)
    p.glob(volume=0.62, poly=16)
    return brightness_space(p, rv, cutoff_amount=20)


# --------------------------------------------------------------------------- keys

def ky_memory_rhodes() -> Patch:
    p = Patch("KY Memory Rhodes", AUTHOR, ["Wavetable", "Poly", "Keyboard"],
              "Tine EP with sine body, tremolo, tape warmth, chorus and plate. M1 Brightness, M2 Space.")
    p.osc("A", "RMrK1 Tine", vol=0.8, unison=2, detune=0.05, retrigger=True)
    p.osc("B", "Basic OPL", pos=OPL_SINE, vol=0.35, retrigger=True)
    p.filt("L12", 5200, reso=5)
    p.env(1, a=0.002, d=3.0, s=0.3, r=0.45)
    p.env(2, a=0.001, d=0.6, s=0.2, r=0.4)
    p.mod(SRC_ENV[2], "VoiceFilter", 0, "kParamFreq", 15)
    p.mod(SRC_VELOCITY, "VoiceFilter", 0, "kParamFreq", 10)
    p.lfo(1, 4.8)
    p.mod(SRC_LFO[1], "Oscillator", OSC["A"], "kParamVolume", 8, bipolar=True)
    p.wow(2, 0.4, 3, "A", "B")
    p.tape(drive=12)
    p.chorus(wet=25, rate_hz=0.6, depth_ms=4)
    p.eq(90, shelf_hz=8000, shelf_db=-2)
    rv = p.reverb("kPlate", size=28, wet=20, locut=30, hicut=50, damp=45)
    p.glob(volume=0.68, poly=16)
    return brightness_space(p, rv)


def ky_lofi_fm_piano() -> Patch:
    p = Patch("KY Lofi FM Piano", AUTHOR, ["Wavetable", "Poly", "Keyboard"],
              "FM piano with heavy tape wow, saturation and a short vintage room. M1 Brightness, M2 Space.")
    p.osc("A", "FM Piano", vol=0.78, retrigger=True)
    p.osc("B", "FM Piano", pos=256.0, vol=0.22, octave=1, unison=2, detune=0.06, retrigger=True)
    p.filt("MgL12", 4500, reso=8)
    p.env(1, a=0.002, d=2.4, s=0.22, r=0.5)
    p.env(2, a=0.001, d=0.5, s=0.2, r=0.4)
    p.mod(SRC_ENV[2], "VoiceFilter", 0, "kParamFreq", 12)
    p.mod(SRC_VELOCITY, "VoiceFilter", 0, "kParamFreq", 10)
    p.wow(1, 0.55, 6, "A", "B")
    p.tape(drive=22)
    p.chorus(wet=20, rate_hz=0.45, depth_ms=5)
    p.eq(110, shelf_hz=7000, shelf_db=-4)
    rv = p.reverb("kVintage", size=40, wet=22, locut=30, hicut=45, damp=40)
    p.glob(volume=0.66, poly=16)
    return brightness_space(p, rv)


def ky_toy_organ_dream() -> Patch:
    p = Patch("KY Toy Organ Dream", AUTHOR, ["Wavetable", "Poly", "Keyboard"],
              "Soft organ with hollow octave layer, organ-style vibrato and a hall. M1 Brightness, M2 Space.")
    p.osc("A", "Memory Organ", vol=0.7, unison=3, detune=0.08)
    p.osc("B", "Basic OPL", pos=OPL_ABS_SINE, vol=0.25, octave=1)
    p.filt("L12", 4000, reso=5)
    p.env(1, a=0.012, d=1.0, s=0.9, r=0.35)
    p.lfo(1, 5.2)
    p.mod(SRC_LFO[1], "Oscillator", OSC["A"], "kParamFine", 4, bipolar=True)
    p.wow(2, 0.3, 3, "A", "B")
    p.chorus(wet=35, rate_hz=0.8, depth_ms=5)
    p.eq(100, shelf_hz=8000, shelf_db=-2)
    rv = p.reverb("kHall", size=50, wet=20, decay=35, locut=30, hicut=45, damp=40)
    p.glob(volume=0.6, poly=16)
    return brightness_space(p, rv)


# --------------------------------------------------------------------------- leads

def ld_blank_body_chip() -> Patch:
    p = Patch("LD Blank Body Chip", AUTHOR, ["Wavetable", "Mono", "Lead"],
              "Mono chip pulse lead with triangle body, glide, vibrato (more on mod wheel), ping-pong + hall.")
    p.osc("A", "Mario", vol=0.62, unison=2, detune=0.04)
    p.osc("B", "Triangle Sub Morph", vol=0.35, octave=-1)
    p.filt("L12", 6500, reso=5)
    p.env(1, a=0.003, d=0.8, s=0.8, r=0.25)
    vibrato(p, 1, 5.6, 8, 20, "A", "B")
    p.eq(180)
    p.delay(wet=18, division="1/8", dotted=True, feedback=35)
    rv = p.reverb("kHall", size=55, wet=22, decay=40, locut=35, hicut=40, damp=40)
    p.glob(volume=0.6, mono=True, porta=0.045)
    return brightness_space(p, rv)


def ld_whitearmor_trance() -> Patch:
    p = Patch("LD Whitearmor Trance", AUTHOR, ["Wavetable", "Mono", "Lead"],
              "Mono supersaw lead with octave layer, glide, vibrato on the mod wheel, dotted delay, big hall.")
    p.osc("A", "Yet Another Saw", vol=0.66, unison=7, detune=0.14)
    p.osc("B", "PolySaw II", vol=0.3, octave=1, unison=3, detune=0.1)
    p.filt("MgL24", 5200, reso=12)
    p.env(1, a=0.004, d=1.0, s=0.85, r=0.35)
    p.env(2, a=0.003, d=0.5, s=0.5, r=0.3)
    p.mod(SRC_ENV[2], "VoiceFilter", 0, "kParamFreq", 12)
    vibrato(p, 1, 5.2, 5, 20, "A", "B")
    p.hyper(wet=15, detune=20, unison=4)
    p.eq(200)
    p.delay(wet=20, division="1/8", dotted=True, feedback=40)
    rv = p.reverb("kHall", size=70, wet=26, decay=50, locut=35, hicut=40, damp=35)
    p.glob(volume=0.52, mono=True, porta=0.06)
    return brightness_space(p, rv)


def ld_glass_whistle() -> Patch:
    p = Patch("LD Glass Whistle", AUTHOR, ["Wavetable", "Mono", "Lead"],
              "Breathy sine/triangle whistle-ocarina lead with vibrato, glide and long tails.")
    p.osc("A", "Basic OPL", pos=OPL_SINE, vol=0.72)
    p.osc("B", "Triangle Sub Morph", vol=0.2, octave=1)
    p.noise("H-Breath", vol=0.14)
    p.filt("L12", 7000, reso=0)
    p.env(1, a=0.035, d=1.0, s=0.9, r=0.3)
    vibrato(p, 1, 5.0, 9, 25, "A", "B")
    p.chorus(wet=20, rate_hz=0.4, depth_ms=5)
    p.eq(220)
    p.delay(wet=18, division="1/4", dotted=True, feedback=35)
    rv = p.reverb("kHall", size=65, wet=28, decay=45, locut=35, hicut=40, damp=40)
    p.glob(volume=0.62, mono=True, porta=0.07)
    return brightness_space(p, rv)


# --------------------------------------------------------------------------- bells

def bl_braids_glass_bell() -> Patch:
    p = Patch("BL Braids Glass Bell", AUTHOR, ["Wavetable", "Poly", "Bell"],
              "Bell pluck with octave sine shimmer, filter-env sparkle, dotted ping-pong, long hall.")
    p.osc("A", "Braids Bell Pluck", vol=0.72, retrigger=True)
    p.osc("B", "Basic OPL", pos=OPL_SINE, vol=0.3, octave=1, retrigger=True)
    p.filt("L12", 3500, reso=0)
    p.env(1, a=0.001, d=2.2, s=0.0, r=1.6)
    p.env(2, a=0.0, d=0.4, s=0.0, r=0.3)
    p.mod(SRC_ENV[2], "VoiceFilter", 0, "kParamFreq", 25)
    p.mod(SRC_VELOCITY, "VoiceFilter", 0, "kParamFreq", 8)
    p.wow(1, 0.4, 3, "A", "B")
    p.chorus(wet=18, rate_hz=0.5, depth_ms=4)
    p.eq(250)
    p.delay(wet=18, division="1/8", dotted=True, feedback=38)
    rv = p.reverb("kHall", size=70, wet=30, decay=55, locut=35, hicut=40, damp=35)
    p.glob(volume=0.66, poly=16)
    return brightness_space(p, rv)


def bl_music_box_haze() -> Patch:
    p = Patch("BL Music Box Haze", AUTHOR, ["Wavetable", "Poly", "Bell"],
              "Warped music box: sine + hollow sine + xylo tick, tape wow and saturation, vintage room.")
    p.osc("A", "Basic OPL", pos=OPL_SINE, vol=0.7, octave=1, retrigger=True)
    p.osc("B", "Basic OPL", pos=OPL_ABS_SINE, vol=0.3, octave=1, retrigger=True)
    p.osc("C", "Xylo Pluck", vol=0.25, octave=1, retrigger=True)
    p.filt("L12", 6000, reso=0)
    p.env(1, a=0.001, d=1.4, s=0.0, r=1.0)
    p.wow(1, 0.6, 6, "A", "B", "C")
    p.tape(drive=15)
    p.chorus(wet=25, rate_hz=0.5, depth_ms=5)
    p.eq(300, shelf_hz=6500, shelf_db=-4)
    p.delay(wet=12, division="1/4", dotted=False, feedback=30)
    rv = p.reverb("kVintage", size=55, wet=28, locut=35, hicut=45, damp=40)
    p.glob(volume=0.62, poly=16)
    return brightness_space(p, rv)


def bl_xylo_snow() -> Patch:
    p = Patch("BL Xylo Snow", AUTHOR, ["Wavetable", "Poly", "Bell"],
              "Xylophone pluck with a two-octave sine sparkle, Hyper width and a snowy hall.")
    p.osc("A", "Xylo Pluck", vol=0.72, retrigger=True)
    p.osc("B", "Basic OPL", pos=OPL_SINE, vol=0.16, octave=2, retrigger=True)
    p.filt("MgL12", 7000, reso=5)
    p.env(1, a=0.001, d=1.1, s=0.0, r=0.9)
    p.mod(SRC_VELOCITY, "VoiceFilter", 0, "kParamFreq", 8)
    p.wow(1, 0.35, 3, "A", "B")
    p.hyper(wet=12, detune=20, unison=4)
    p.eq(250)
    p.delay(wet=15, division="1/8", dotted=True, feedback=30)
    rv = p.reverb("kHall", size=60, wet=26, decay=45, locut=35, hicut=40, damp=40)
    p.glob(volume=0.66, poly=16)
    return brightness_space(p, rv)


# --------------------------------------------------------------------------- pads

def pd_whitearmor_heaven() -> Patch:
    p = Patch("PD Whitearmor Heaven", AUTHOR, ["Wavetable", "Poly", "Pad"],
              "Huge slow supersaw pad, string-saw octave, sine body, breathing filter, 7 s hall. M1 Brightness, M2 Space.")
    p.osc("A", "PolySaw II", vol=0.6, unison=9, detune=0.24)
    p.osc("B", "SynStringSaw", pos=128.0, vol=0.3, octave=1, unison=5, detune=0.18)
    p.osc("C", "Basic OPL", pos=OPL_SINE, vol=0.22, octave=-1)
    p.filt("MgL24", 3800, reso=8)
    p.env(1, a=0.9, d=2.0, s=1.0, r=2.5)
    p.wow(1, 0.25, 5, "A", "B")
    p.lfo(2, 0.06)
    p.mod(SRC_LFO[2], "VoiceFilter", 0, "kParamFreq", 7, bipolar=True)
    p.hyper(wet=20, detune=25, unison=4, dim_size=50, dim_wet=25)
    p.chorus(wet=20, rate_hz=0.3, depth_ms=7)
    p.eq(120, shelf_hz=8000, shelf_db=-3)
    p.delay(wet=12, division="1/4", dotted=True, feedback=35)
    rv = p.reverb("kHall", size=85, wet=35, decay=60, locut=35, hicut=40, damp=35, predelay_s=0.03)
    p.glob(volume=0.48, poly=10)
    return brightness_space(p, rv)


def pd_solina_tears() -> Patch:
    p = Patch("PD Solina Tears", AUTHOR, ["Wavetable", "Poly", "Pad"],
              "String-machine ensemble pad with octave layer, heavy chorus and plate. M1 Brightness, M2 Space.")
    p.osc("A", "Solina Viola", pos=128.0, vol=0.68, unison=4, detune=0.1)
    p.osc("B", "Solina Viola", pos=128.0, vol=0.3, octave=1, unison=2, detune=0.06)
    p.filt("L12", 4200, reso=6)
    p.env(1, a=0.45, d=2.0, s=0.95, r=1.8)
    p.wow(1, 0.3, 5, "A", "B")
    p.chorus(wet=45, rate_hz=0.8, depth_ms=8, feedback=15)
    p.eq(140, shelf_hz=8000, shelf_db=-2)
    rv = p.reverb("kPlate", size=40, wet=26, locut=35, hicut=50, damp=45)
    p.glob(volume=0.55, poly=12)
    return brightness_space(p, rv)


def pd_mello_fog() -> Patch:
    p = Patch("PD Mello Fog", AUTHOR, ["Wavetable", "Poly", "Pad"],
              "Lo-fi tape pad: mellow table, air noise, strong wow, saturation, dark vintage verb. M1 Brightness, M2 Space.")
    p.osc("A", "Mello", vol=0.7, unison=3, detune=0.08)
    p.osc("B", "Basic OPL", pos=OPL_SINE, vol=0.18, octave=1)
    p.noise("Air Can 1", vol=0.16)
    p.filt("MgL12", 2400, reso=12)
    p.env(1, a=0.6, d=2.0, s=0.9, r=2.0)
    p.wow(1, 0.38, 8, "A", "B")
    p.lfo(2, 0.09)
    p.mod(SRC_LFO[2], "VoiceFilter", 0, "kParamFreq", 6, bipolar=True)
    p.tape(drive=20)
    p.chorus(wet=30, rate_hz=0.4, depth_ms=6)
    p.eq(120, shelf_hz=6000, shelf_db=-5)
    rv = p.reverb("kVintage", size=70, wet=30, locut=35, hicut=55, damp=50)
    p.glob(volume=0.6, poly=12)
    return brightness_space(p, rv)


def pd_ice_choir() -> Patch:
    p = Patch("PD Ice Choir", AUTHOR, ["Wavetable", "Poly", "Pad"],
              "Vowel choir pad with sine halo, slow filter drift, Hyper and an 8 s hall. M1 Brightness, M2 Space.")
    p.osc("A", "Vocal Hum", pos=100.0, vol=0.65, unison=5, detune=0.12)
    p.osc("B", "Basic OPL", pos=OPL_SINE, vol=0.2, octave=1)
    p.filt("L12", 5000, reso=5)
    p.env(1, a=1.2, d=2.0, s=1.0, r=3.0)
    p.wow(1, 0.22, 4, "A", "B")
    p.lfo(2, 0.05)
    p.mod(SRC_LFO[2], "VoiceFilter", 0, "kParamFreq", 5, bipolar=True)
    p.hyper(wet=25, detune=25, unison=4, dim_size=60, dim_wet=30)
    p.eq(160)
    p.delay(wet=10, division="1/2", dotted=False, feedback=30)
    rv = p.reverb("kHall", size=90, wet=40, decay=65, locut=35, hicut=40, damp=35, predelay_s=0.03)
    p.glob(volume=0.52, poly=10)
    return brightness_space(p, rv)


BANK = {
    "Synths": [sy_whitearmor_supersaw, sy_sherman_juno_chords, sy_drain_saw_wash, sy_cloud_pluck],
    "Keys": [ky_memory_rhodes, ky_lofi_fm_piano, ky_toy_organ_dream],
    "Leads": [ld_blank_body_chip, ld_whitearmor_trance, ld_glass_whistle],
    "Bells": [bl_braids_glass_bell, bl_music_box_haze, bl_xylo_snow],
    "Pads": [pd_whitearmor_heaven, pd_solina_tears, pd_mello_fog, pd_ice_choir],
}


def main() -> None:
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent / PACK
    for folder, builders in BANK.items():
        for build in builders:
            patch = build()
            path = patch.write(out / folder / f"{patch.name}.SerumPreset")
            print(path.relative_to(out.parent))


if __name__ == "__main__":
    main()
