class_name SfxSynth
extends RefCounted
## Shared procedural battle-SFX synthesizer (arena + menu preview).
## No audio assets ship: every effect is a sine(+sweep) under exp decay
## plus a white-noise wash, packed once into 16-bit AudioStreamWAV.
## Palettes are recipe tables only - same engine, different character.
## Judge by ear via the menu SOUND row (palette picker + Preview).

const RATE := 22050 # synth sample rate; covers every effect below at
	# half the memory of 44100. Raise only for brighter tops.
const PALETTES := ["classic", "punchy", "bright"]
const EFFECTS := ["thump", "clash", "tear", "boom", "beep", "fight"]


static func recipes(palette: String) -> Dictionary:
	# name -> [freq, secs, decay, noise, sweep]. freq_end 0 = no sweep.
	# classic = soft sine hits (original tuning). punchy = pitch-drop
	# kick, tight metallic tick, sub cannon. bright = higher, glassier.
	match palette:
		"punchy":
			return {
				"thump": [160.0, 0.22, 16.0, 0.5, 45.0],
				"clash": [2200.0, 0.09, 36.0, 0.2, 1500.0],
				"tear": [700.0, 0.30, 11.0, 0.65, 150.0],
				"boom": [48.0, 0.90, 5.0, 0.45, 0.0],
				"beep": [990.0, 0.08, 30.0, 0.0, 0.0],
				"fight": [1480.0, 0.22, 15.0, 0.0, 0.0],
			}
		"bright":
			return {
				"thump": [120.0, 0.14, 26.0, 0.35, 0.0],
				"clash": [2600.0, 0.10, 32.0, 0.15, 1900.0],
				"tear": [1000.0, 0.30, 10.0, 0.5, 300.0],
				"boom": [65.0, 0.60, 7.0, 0.3, 0.0],
				"beep": [1040.0, 0.08, 30.0, 0.0, 0.0],
				"fight": [1560.0, 0.22, 15.0, 0.0, 0.0],
			}
		_: # "classic" and any unknown name fall back here.
			return {
				"thump": [90.0, 0.18, 22.0, 0.45, 0.0],
				"clash": [1560.0, 0.12, 30.0, 0.25, 1180.0],
				"tear": [800.0, 0.35, 9.0, 0.6, 200.0],
				"boom": [55.0, 0.70, 6.0, 0.35, 0.0],
				"beep": [880.0, 0.09, 28.0, 0.0, 0.0],
				"fight": [1320.0, 0.25, 14.0, 0.0, 0.0],
			}


static func wav_from_floats(samples: PackedFloat32Array) -> AudioStreamWAV:
	# 16-bit packing is LOAD-BEARING: AudioStreamWAV defaults to
	# FORMAT_8_BITS (signed), which plays float-packed buffers as
	# garbage. mix_rate must equal RATE or pitch shifts.
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = RATE
	stream.stereo = false
	var bytes := PackedByteArray()
	bytes.resize(samples.size() * 2)
	for i in samples.size():
		bytes.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32767.0))
	stream.data = bytes
	return stream


static func tone(freq: float, secs: float, decay: float, noise_amt: float = 0.0, freq_end: float = 0.0) -> AudioStreamWAV:
	var n := int(RATE * secs)
	var samples := PackedFloat32Array()
	samples.resize(n)
	var phase := 0.0
	for i in n:
		var t := float(i) / RATE
		var f := freq if freq_end <= 0.0 else lerpf(freq, freq_end, float(i) / maxf(n - 1.0, 1.0))
		phase += TAU * f / RATE
		var env := exp(-t * decay)
		samples[i] = (sin(phase) * (1.0 - noise_amt) + (randf() * 2.0 - 1.0) * noise_amt) * env
	return wav_from_floats(samples)


static func build(palette: String) -> Dictionary:
	# name -> AudioStreamWAV for the whole palette. Pure (no nodes):
	# callers own playback.
	var table := recipes(palette)
	var out := {}
	for effect in EFFECTS:
		var r: Array = table[effect]
		out[effect] = tone(float(r[0]), float(r[1]), float(r[2]),
			float(r[3]), float(r[4]))
	return out
