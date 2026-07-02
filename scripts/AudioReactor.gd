extends RefCounted
## Audio-reactive levels module — mirrors SceneEnvironment / WallConfig.
##
## Taps a Godot AudioServer spectrum analyzer and reduces it each frame to three
## normalized bands (bass/mid/treble) plus a simple beat pulse, so visualizations
## can react to sound. Schema-driven like the other global modules; editable in
## the ParameterPanel and serialized by CompositionIO under "audio".
##
## Two input sources (InputSource):
##   SYSTEM_MIC — captures the OS default input device via an AudioStreamPlayer
##                running an AudioStreamMicrophone stream, routed to a private
##                muted bus. Point the OS input at a loopback device (e.g.
##                BlackHole / Stereo Mix) to react to whatever's playing on the
##                system.
##   MASTER_BUS — analyzes Poly-Vis's own "Master" bus (whatever the app itself
##                plays through an AudioStreamPlayer, if any).
## Both paths attach an AudioEffectSpectrumAnalyzer to the chosen bus (created
## once, reused across mode switches) and read it back each frame via
## get_magnitude_for_frequency_range.
class_name AudioReactor

enum InputSource { SYSTEM_MIC, MASTER_BUS }

const BUS_NAME := "AudioReactor"
const BAND_BASS_HZ := 250.0
const BAND_MID_HZ := 4000.0
const BAND_TREBLE_HZ := 12000.0
## Rolling window (samples, ~1/frame) used to average bass for beat detection.
const BEAT_HISTORY_LEN := 30

## Master toggle — off by default so the app never opens a mic input uninvited.
var enabled: bool = false: set = set_enabled
## Where to tap the signal: the OS mic input (system audio via loopback) or
## Poly-Vis's own Master bus.
var input_source: InputSource = InputSource.SYSTEM_MIC: set = set_input_source
## Exponential smoothing factor for the band levels (0 = instant, near 1 = slow).
var smoothing: float = 0.8: set = set_smoothing
var bass_gain: float = 1.0: set = set_bass_gain
var mid_gain: float = 1.0: set = set_mid_gain
var treble_gain: float = 1.0: set = set_treble_gain
## How far above the rolling bass average a peak must rise to register a beat.
var beat_sensitivity: float = 1.3: set = set_beat_sensitivity

## Normalized (roughly 0..1) smoothed band levels, recomputed every update().
var bass: float = 0.0
var mid: float = 0.0
var treble: float = 0.0
## Rising-edge pulse on a detected beat: jumps to 1.0, decays back to 0.
var beat: float = 0.0

var _host: Node
var _player: AudioStreamPlayer
var _bus_idx: int = -1
var _spectrum: AudioEffectSpectrumAnalyzerInstance
var _bass_history: Array[float] = []
var _was_over: bool = false

## `host` parents the microphone AudioStreamPlayer (we're RefCounted and can't
## add children ourselves) — mirrors SceneEnvironment.bind(env, host).
func bind(host: Node) -> void:
	_host = host
	_reconfigure()

## Reset to the authored defaults (audio off). Called when loading a
## composition that carries no "audio" block, so old comps don't inherit a
## previous session's live mic tap.
func reset_defaults() -> void:
	enabled = false
	input_source = InputSource.SYSTEM_MIC
	smoothing = 0.8
	bass_gain = 1.0
	mid_gain = 1.0
	treble_gain = 1.0
	beat_sensitivity = 1.3

func set_enabled(v: bool) -> void:
	enabled = v
	_reconfigure()

func set_input_source(v: InputSource) -> void:
	input_source = v
	_reconfigure()

func set_smoothing(v: float) -> void:
	smoothing = v

func set_bass_gain(v: float) -> void:
	bass_gain = v

func set_mid_gain(v: float) -> void:
	mid_gain = v

func set_treble_gain(v: float) -> void:
	treble_gain = v

func set_beat_sensitivity(v: float) -> void:
	beat_sensitivity = v

## Called from Main._process every frame. Levels decay to 0 (and the beat
## history resets) whenever disabled or the analyzer isn't wired up yet, so
## dependent parameters fall back to their unmodulated base value.
func update(delta: float) -> void:
	if not enabled or _spectrum == null:
		bass = 0.0
		mid = 0.0
		treble = 0.0
		beat = 0.0
		_bass_history.clear()
		_was_over = false
		return

	var raw_bass := _band_level(20.0, BAND_BASS_HZ) * bass_gain
	var raw_mid := _band_level(BAND_BASS_HZ, BAND_MID_HZ) * mid_gain
	var raw_treble := _band_level(BAND_MID_HZ, BAND_TREBLE_HZ) * treble_gain

	var a := clampf(smoothing, 0.0, 0.98)
	bass = clampf(lerp(raw_bass, bass, a), 0.0, 4.0)
	mid = clampf(lerp(raw_mid, mid, a), 0.0, 4.0)
	treble = clampf(lerp(raw_treble, treble, a), 0.0, 4.0)

	_bass_history.append(bass)
	if _bass_history.size() > BEAT_HISTORY_LEN:
		_bass_history.pop_front()
	var avg := 0.0
	for v in _bass_history:
		avg += v
	avg /= _bass_history.size()

	var over := bass > 0.05 and bass > avg * beat_sensitivity
	if over and not _was_over:
		beat = 1.0
	else:
		beat = maxf(beat - delta * 2.5, 0.0)
	_was_over = over

## dB-normalized magnitude in a frequency range, clamped to ~0..1 (-60dB..0dB).
func _band_level(freq_lo: float, freq_hi: float) -> float:
	var mag: Vector2 = _spectrum.get_magnitude_for_frequency_range(freq_lo, freq_hi)
	var db := linear_to_db(mag.length())
	return clampf(inverse_lerp(-60.0, 0.0, db), 0.0, 1.0)

# ---------------------------------------------------------------------------
# Bus / effect / mic plumbing
# ---------------------------------------------------------------------------
func _reconfigure() -> void:
	if not enabled:
		_teardown_mic()
		_spectrum = null
		return
	match input_source:
		InputSource.MASTER_BUS:
			_teardown_mic()
			_bus_idx = AudioServer.get_bus_index("Master")
		_:
			_bus_idx = _ensure_capture_bus()
			_ensure_mic()
	_spectrum = _ensure_spectrum_effect(_bus_idx)

## Private bus for the mic tap, muted so a live microphone never feeds back
## into the speakers — the spectrum analyzer effect still sees the signal
## ahead of the mute.
func _ensure_capture_bus() -> int:
	var idx := AudioServer.get_bus_index(BUS_NAME)
	if idx == -1:
		AudioServer.add_bus()
		idx = AudioServer.bus_count - 1
		AudioServer.set_bus_name(idx, BUS_NAME)
	AudioServer.set_bus_mute(idx, true)
	return idx

func _ensure_spectrum_effect(bus_idx: int) -> AudioEffectSpectrumAnalyzerInstance:
	if bus_idx < 0:
		return null
	for i in AudioServer.get_bus_effect_count(bus_idx):
		if AudioServer.get_bus_effect(bus_idx, i) is AudioEffectSpectrumAnalyzer:
			return AudioServer.get_bus_effect_instance(bus_idx, i)
	var an := AudioEffectSpectrumAnalyzer.new()
	an.buffer_length = 0.1
	AudioServer.add_bus_effect(bus_idx, an)
	return AudioServer.get_bus_effect_instance(bus_idx, AudioServer.get_bus_effect_count(bus_idx) - 1)

func _ensure_mic() -> void:
	if _host == null or not _host.is_inside_tree():
		return
	if _player == null or not is_instance_valid(_player):
		_player = AudioStreamPlayer.new()
		_player.name = "AudioReactorMic"
		_player.stream = AudioStreamMicrophone.new()
		_host.add_child(_player)
	_player.bus = BUS_NAME
	if not _player.playing:
		_player.play()

func _teardown_mic() -> void:
	if _player != null and is_instance_valid(_player):
		_player.stop()

## Live status readout for the panel's "status" row.
func level_status() -> String:
	if not enabled:
		return "Off"
	return "Bass %.2f  Mid %.2f  Treble %.2f  %s" % [bass, mid, treble,
		("● Beat" if beat > 0.5 else "")]

func get_param_schema() -> Array:
	return [{
		"title": "Audio Reactivity",
		"props": [
			{"name": "enabled", "type": "bool",
				"hint": "Tap an audio input and drive audio-reactive parameters"},
			{"name": "input_source", "type": "enum",
				"options": ["System (Mic Input)", "Master Bus"],
				"hint": "System: OS input device — route a loopback device (e.g. BlackHole / Stereo Mix) to react to system audio. Master Bus: whatever Poly-Vis itself plays"},
			{"name": "smoothing", "type": "float", "min": 0.0, "max": 0.98, "step": 0.01},
			{"name": "bass_gain", "type": "float", "min": 0.0, "max": 4.0, "step": 0.05},
			{"name": "mid_gain", "type": "float", "min": 0.0, "max": 4.0, "step": 0.05},
			{"name": "treble_gain", "type": "float", "min": 0.0, "max": 4.0, "step": 0.05},
			{"name": "beat_sensitivity", "type": "float", "min": 1.0, "max": 3.0, "step": 0.05,
				"hint": "How far above the rolling bass average a peak must rise to register a beat"},
			{"name": "level_status", "type": "status", "label": "Levels", "interval": 0.1},
		]
	}]
