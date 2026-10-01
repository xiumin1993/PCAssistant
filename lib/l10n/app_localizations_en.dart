// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'PC Assistant';

  @override
  String get heroConnected => 'Connected';

  @override
  String get heroConnecting => 'Connecting';

  @override
  String get heroConnectFailed => 'Connection failed';

  @override
  String get heroNotConnected => 'Not connected';

  @override
  String get tabWifi => 'WiFi';

  @override
  String get tabUsb => 'USB';

  @override
  String get tabBluetooth => 'Bluetooth';

  @override
  String get serverAddressLabel => 'PC server address';

  @override
  String get serverAddressHint => 'e.g. 192.168.1.100:8080';

  @override
  String get wifiSameNetworkHint =>
      'Phone and PC must be on the same WiFi network; the address is shown in the AudioServer window on the PC.';

  @override
  String get portLabel => 'Port';

  @override
  String get usbHint =>
      'Plug in the USB cable, then run this on the PC: adb reverse tcp:8080 tcp:8080';

  @override
  String get usbIphoneHint =>
      'iPhone has no USB direct channel yet — use WiFi: enter the PC\'s LAN IP address.';

  @override
  String get bluetoothHint =>
      'Bluetooth is not open in this version: classic Bluetooth gives about 1 Mbps, enough for audio but not for video. Everything currently runs over WiFi LAN or a USB cable.';

  @override
  String get btnConnect => 'Connect';

  @override
  String get btnDisconnect => 'Disconnect';

  @override
  String btnConnectWithSwitch(String mode) {
    return 'Connect (disconnects $mode first)';
  }

  @override
  String get btnConnecting => 'Connecting...';

  @override
  String get statusTapToStart => 'Tap Connect to begin';

  @override
  String get statusConnecting => 'Connecting...';

  @override
  String get statusReceiving => 'Receiving audio stream';

  @override
  String get statusConnectFailed =>
      'Connection failed — make sure AudioServer is running on the PC and that the address and port are correct';

  @override
  String get errEnterAddress => 'Please enter the PC server address';

  @override
  String get errEnterPort => 'Please enter the port number';

  @override
  String get devSpeaker => 'Speaker';

  @override
  String get devMic => 'Microphone';

  @override
  String get devCamera => 'Camera';

  @override
  String get statusDisabled => 'Disabled';

  @override
  String get statusOffline => 'Not connected';

  @override
  String get statusPendingCam => 'Awaiting PC request';

  @override
  String get statusPendingMic => 'Awaiting permission';

  @override
  String get statusStandby => 'Standby';

  @override
  String get statusPlayingNow => 'Playing';

  @override
  String get statusRecordingNow => 'Recording';

  @override
  String get statusFilmingNow => 'Streaming';

  @override
  String get gateDisabled => 'Disabled';

  @override
  String get gateEnabledOffline => 'Enabled · Not connected';

  @override
  String get gateEnabledPendingCam => 'Enabled · Waiting for the PC request';

  @override
  String get gateEnabledPendingMic =>
      'Enabled · Waiting for recording permission';

  @override
  String get gateEnabledStandby => 'Enabled · Standby';

  @override
  String get gateEnabledActive => 'Enabled · In use';

  @override
  String get gateSubDisabled =>
      'This device is switched off: the session is unregistered and no hardware starts, so nothing the PC does can wake it.';

  @override
  String get gateSubOffline =>
      'Enabled, but not connected to the PC yet. It goes to standby automatically once connected.';

  @override
  String get gateSubPendingCam =>
      'The camera hardware is OFF. When the PC presses \"Request Phone Camera\" your phone shows a confirmation banner; only after you allow it does the session register and go to standby — this privacy gate is deliberate.';

  @override
  String get gateSubPendingMic =>
      'The phone has no recording permission, so the microphone never reached standby. Open the Microphone page and tap \"Grant\"; allow the system dialog once and it stays usable.';

  @override
  String get standbySpeaker =>
      'Session ready, the PC is not pushing audio yet. Switching to \"Disabled\" stops receiving the stream at once.';

  @override
  String get standbyMic =>
      'Session registered, mic hardware OFF (no green dot, no battery drain). Switching to \"Disabled\" unregisters at once.';

  @override
  String get standbyCamera =>
      'Session registered, camera hardware OFF (no green dot, no battery drain). Switching to \"Disabled\" unregisters the session and closes the camera.';

  @override
  String get activeSpeaker =>
      'The PC is pushing audio to the phone right now. Switching to \"Disabled\" stops playback and drops that channel.';

  @override
  String get activeMic =>
      'A PC app is recording from the phone mic right now, hardware ON. Switching to \"Disabled\" unregisters and closes the mic at once.';

  @override
  String get activeCamera =>
      'A PC app holds the virtual camera right now, camera hardware ON. Switching to \"Disabled\" unregisters the session and closes the camera.';

  @override
  String get detailDisabled => 'Disabled · the PC cannot use it';

  @override
  String get detailOffline =>
      'Goes to standby automatically once the PC is connected';

  @override
  String get detailPendingCam =>
      'Connected - the camera starts automatically once the PC asks';

  @override
  String get detailPendingMic =>
      'Connected · waiting for recording permission on the phone';

  @override
  String get detailStandby => 'On standby · hardware off, no battery drain';

  @override
  String get detailActiveSpeaker => 'Playing the audio the PC sends';

  @override
  String get detailActiveMic => 'The PC is using your microphone right now';

  @override
  String get detailActiveCamera => 'The PC is using your camera right now';

  @override
  String get gateOff => '← Disabled';

  @override
  String get gateOffCurrent => '← Disabled (now)';

  @override
  String get gateOn => 'Enabled →';

  @override
  String get gateOnCurrent => 'Enabled (now) →';

  @override
  String get grantPermission => 'Grant';

  @override
  String get paramsTitle => 'Parameters';

  @override
  String get micNoPermission =>
      'The phone has no recording permission yet; grant it so it can act as the PC microphone';

  @override
  String get micStateRecording => 'Recording: mic hardware ON';

  @override
  String get micStateStandby => 'Standby: mic hardware OFF';

  @override
  String get micStateStarting => 'Starting…';

  @override
  String get micStateOff => 'Not enabled';

  @override
  String get micUplinkBitrate => 'Uplink bitrate';

  @override
  String micUplinkFormat(int khz) {
    return '$khz kHz · Mono';
  }

  @override
  String get micUplinkSampleRate => 'Uplink sample rate';

  @override
  String get micRate48 => '48 kHz · pass-through';

  @override
  String get micRate44 => '44.1 kHz · resampled on PC';

  @override
  String get micParamHint =>
      'Changing the profile while on standby takes effect at once: the app re-sends the registration (mic_start) so the server learns the new rate. While recording, capture restarts silently with a gap of about 100 ms you barely notice.';

  @override
  String get micMuteLabel => 'Mute (session kept, phone mic off)';

  @override
  String get micMutedLabel => 'Muted · tap to resume recording';

  @override
  String get micMuteHint =>
      'Mute keeps the session registered (the PC can still see this phone) but closes the recording hardware at once and tells the PC to drop the leftover audio. To make the PC unable to wake this phone at all, use \"Disabled\" at the top.';

  @override
  String get micHowToUse =>
      'In the meeting / voice-input app on the PC, set the input device to\n\"CABLE Output (VB-Audio Virtual Cable)\"\n(once connected the phone is on standby; the mic turns ON only when a PC app uses it,\nand OFF the instant that app lets go)';

  @override
  String get micStatusDisabled =>
      'Disabled — the PC cannot use the phone microphone';

  @override
  String get micStatusConnectedPerm =>
      'Connected to the PC. Tap the button below to grant recording, then it just works.';

  @override
  String get micStatusConnectedAuto =>
      'Goes to standby automatically once connected to the PC — nothing to do';

  @override
  String get micStatusMuted =>
      'Muted — the mic stays off even when a PC app uses it';

  @override
  String get micStatusStandbyLong =>
      'On standby — mic closed, opens automatically when a PC app needs it';

  @override
  String get micStatusOpening =>
      'The PC is using it, opening the microphone...';

  @override
  String get micStatusLive =>
      'Recording — the PC is using your microphone right now';

  @override
  String get micBadgeWaitingPerm => 'Waiting for recording permission';

  @override
  String get micBadgeOff => 'Not enabled';

  @override
  String get micBadgeMuted => 'Muted · waiting to unmute';

  @override
  String get micBadgeStandby => 'On standby · mic hardware off';

  @override
  String get micBadgeStarting => 'Opening…';

  @override
  String get micBadgeLive => 'Recording · the PC is using it';

  @override
  String get camNoPermission =>
      'The phone has no camera permission; grant it so the PC can use the camera';

  @override
  String get camQuality => 'Quality';

  @override
  String get camNoModes => 'No usable mode for the current lens';

  @override
  String get camProbing =>
      'Probing… (reads the modes this phone supports once the PC connects)';

  @override
  String get camAutoHighest => 'Auto (highest)';

  @override
  String camRotate(int deg) {
    return 'Rotate $deg°';
  }

  @override
  String get camParamHint =>
      'Parameters can be changed in any state: while filming the camera restarts silently to apply them; on standby or disconnected the choice is remembered and applied when the camera opens. Only switching to \"Disabled\" locks them — otherwise the control would be lying to you.';

  @override
  String get camFrozenLabel => 'Frozen · tap to resume the picture';

  @override
  String get camFreezeLabel => 'Freeze frame (session kept, picture stops)';

  @override
  String get camHowToUse =>
      'In the meeting / camera / streaming app on the PC, pick the webcam\n\"Unity Video Capture\"\n(after enabling, the phone waits; the camera opens only while the PC watches,\nand turns OFF the instant it stops)';

  @override
  String get camIosNote =>
      'iPhone note: because of iOS limits the camera can only stream while this page is open and the screen is awake (going to the background or locking stops it). Microphone and speaker are not affected.';

  @override
  String get camRecOverlay => 'REC · the PC is using your camera';

  @override
  String get camPreviewOff => 'Camera off · standby';

  @override
  String get camTapFullscreen => 'Tap for fullscreen';

  @override
  String get camExitFullscreen => 'Exit fullscreen';

  @override
  String camStamp(String quality, String facing) {
    return '$quality · $facing';
  }

  @override
  String camRecStamp(String quality, String facing) {
    return 'REC · $quality · $facing';
  }

  @override
  String get camStatusDisabled =>
      'Disabled — the PC cannot use the phone camera';

  @override
  String get camStatusConnectedPerm =>
      'Connected to the PC; grant the camera and it is ready to use';

  @override
  String get camStatusStandbyAuto =>
      'Standby after connecting; the PC can also request and the phone confirms';

  @override
  String get camStatusFrozen =>
      'Frozen — the camera stays off even while the PC watches';

  @override
  String get camStatusStandbyLong =>
      'On standby — camera closed, opens automatically when the PC watches';

  @override
  String get camStatusOpening => 'The PC is watching, opening the camera...';

  @override
  String get camStatusLive => 'Filming — the PC is using your camera right now';

  @override
  String get camBadgeWaitingPerm => 'Waiting for camera permission';

  @override
  String get camBadgeOff => 'Not enabled';

  @override
  String get camBadgeFrozen => 'Frozen · waiting to resume';

  @override
  String get camBadgeStandby => 'On standby · camera hardware off';

  @override
  String get camBadgeOpening => 'Opening…';

  @override
  String get camBadgeLive => 'Filming · the PC is watching';

  @override
  String get camForceStopped => 'The PC forced the camera off';

  @override
  String get facingBack => 'Rear';

  @override
  String get facingFront => 'Front';

  @override
  String get switchToFront => 'Switch to front';

  @override
  String get switchToBack => 'Switch to rear';

  @override
  String get errConnectFirst => 'Connect to the PC on the Home page first';

  @override
  String get errMicPermission =>
      'Recording permission is needed to act as the PC microphone';

  @override
  String get errCamPermission =>
      'Camera permission is needed to act as the PC webcam';

  @override
  String get errMicDenied =>
      'Recording permission denied — allow it in System Settings';

  @override
  String get errMicBusy =>
      'The microphone is held by another app — close it and retry';

  @override
  String get errMicUnsupported =>
      'Unsupported sample-rate / channel combination';

  @override
  String errMicStart(String code) {
    return 'Microphone failed to start: $code';
  }

  @override
  String get errCamDenied =>
      'Camera permission denied — allow it in System Settings';

  @override
  String get errCamNoLens => 'This phone has no such lens';

  @override
  String get errCamNoCaps =>
      'Cannot read the resolutions this lens supports — camera cannot start';

  @override
  String get errCamTimeout =>
      'Opening the camera timed out — close other camera apps and retry';

  @override
  String get errCamBusy =>
      'The camera is held by another app — close it and retry';

  @override
  String errCamStart(String code) {
    return 'Camera failed to start: $code';
  }

  @override
  String netError(String error) {
    return 'Connection error: $error';
  }

  @override
  String netFailed(String error) {
    return 'Connection failed: $error';
  }

  @override
  String get spkMuteTitle => 'Mute on this phone';

  @override
  String get spkMuteSubtitle =>
      'Keeps the connection and the PC-side state; the phone just stays quiet';

  @override
  String get spkSourceLabel => 'Source';

  @override
  String get spkSourceValue => 'PC system audio (WASAPI loopback capture)';

  @override
  String get spkFormatLabel => 'Audio format';

  @override
  String get audioMono => 'Mono';

  @override
  String get audioStereo => 'Stereo';

  @override
  String spkFormatValue(String khz, String ch) {
    return '$khz kHz · $ch · 16-bit';
  }

  @override
  String get spkBitrateLabel => 'Link rate';

  @override
  String spkBitrateValue(String mbps) {
    return 'about $mbps Mbps';
  }

  @override
  String get spkReceivedLabel => 'Received';

  @override
  String get spkPlayStatusLabel => 'Playback';

  @override
  String get spkPlayDisconnected => 'Not connected';

  @override
  String get spkPlayMuted => 'Receiving (muted on this phone)';

  @override
  String get spkPlayPlaying => 'Playing';

  @override
  String get spkPlayWaiting => 'Connected · waiting for the PC to stream';

  @override
  String get spkParamsLocked =>
      'Phone volume and the buffer profile (low latency ↔ stability) need changes in the native player (AudioTrack volume and bufferDuration) and are not open in this build: use the phone\'s side keys for volume, and the buffer stays fixed by the server\'s lowest-latency policy.';

  @override
  String get spkHowToUse =>
      'Nothing to choose on the PC: AudioServer grabs the system audio directly,\nso the phone becomes the PC\'s second speaker once connected.\nTo stop the phone making any sound at all, switch the slider above to \"Disabled\".';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get languageTitle => 'Language';

  @override
  String get langAuto => 'Follow system';

  @override
  String get langEn => 'English';

  @override
  String get langZh => '简体中文';

  @override
  String langAutoCurrent(String locale) {
    return 'System language detected: $locale';
  }
}
