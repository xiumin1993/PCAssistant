import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'PC Assistant'**
  String get appTitle;

  /// No description provided for @heroConnected.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get heroConnected;

  /// No description provided for @heroConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting'**
  String get heroConnecting;

  /// No description provided for @heroConnectFailed.
  ///
  /// In en, this message translates to:
  /// **'Connection failed'**
  String get heroConnectFailed;

  /// No description provided for @heroNotConnected.
  ///
  /// In en, this message translates to:
  /// **'Not connected'**
  String get heroNotConnected;

  /// No description provided for @tabWifi.
  ///
  /// In en, this message translates to:
  /// **'WiFi'**
  String get tabWifi;

  /// No description provided for @tabUsb.
  ///
  /// In en, this message translates to:
  /// **'USB'**
  String get tabUsb;

  /// No description provided for @tabBluetooth.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth'**
  String get tabBluetooth;

  /// No description provided for @serverAddressLabel.
  ///
  /// In en, this message translates to:
  /// **'PC server address'**
  String get serverAddressLabel;

  /// No description provided for @serverAddressHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. 192.168.1.100:8080'**
  String get serverAddressHint;

  /// No description provided for @wifiSameNetworkHint.
  ///
  /// In en, this message translates to:
  /// **'Phone and PC must be on the same WiFi network; the address is shown in the AudioServer window on the PC.'**
  String get wifiSameNetworkHint;

  /// No description provided for @portLabel.
  ///
  /// In en, this message translates to:
  /// **'Port'**
  String get portLabel;

  /// No description provided for @usbHint.
  ///
  /// In en, this message translates to:
  /// **'Plug in the USB cable, then run this on the PC: adb reverse tcp:8080 tcp:8080'**
  String get usbHint;

  /// No description provided for @usbIphoneHint.
  ///
  /// In en, this message translates to:
  /// **'iPhone has no USB direct channel yet — use WiFi: enter the PC\'s LAN IP address.'**
  String get usbIphoneHint;

  /// No description provided for @bluetoothHint.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth is not open in this version: classic Bluetooth gives about 1 Mbps, enough for audio but not for video. Everything currently runs over WiFi LAN or a USB cable.'**
  String get bluetoothHint;

  /// No description provided for @btnConnect.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get btnConnect;

  /// No description provided for @btnDisconnect.
  ///
  /// In en, this message translates to:
  /// **'Disconnect'**
  String get btnDisconnect;

  /// No description provided for @btnConnectWithSwitch.
  ///
  /// In en, this message translates to:
  /// **'Connect (disconnects {mode} first)'**
  String btnConnectWithSwitch(String mode);

  /// No description provided for @btnConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting...'**
  String get btnConnecting;

  /// No description provided for @statusTapToStart.
  ///
  /// In en, this message translates to:
  /// **'Tap Connect to begin'**
  String get statusTapToStart;

  /// No description provided for @statusConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting...'**
  String get statusConnecting;

  /// No description provided for @statusReceiving.
  ///
  /// In en, this message translates to:
  /// **'Receiving audio stream'**
  String get statusReceiving;

  /// No description provided for @statusConnectFailed.
  ///
  /// In en, this message translates to:
  /// **'Connection failed — make sure AudioServer is running on the PC and that the address and port are correct'**
  String get statusConnectFailed;

  /// No description provided for @errEnterAddress.
  ///
  /// In en, this message translates to:
  /// **'Please enter the PC server address'**
  String get errEnterAddress;

  /// No description provided for @errEnterPort.
  ///
  /// In en, this message translates to:
  /// **'Please enter the port number'**
  String get errEnterPort;

  /// No description provided for @consentTitle.
  ///
  /// In en, this message translates to:
  /// **'The PC wants to use your camera'**
  String get consentTitle;

  /// No description provided for @consentIgnore.
  ///
  /// In en, this message translates to:
  /// **'Ignore'**
  String get consentIgnore;

  /// No description provided for @consentAgree.
  ///
  /// In en, this message translates to:
  /// **'Allow'**
  String get consentAgree;

  /// No description provided for @devSpeaker.
  ///
  /// In en, this message translates to:
  /// **'Speaker'**
  String get devSpeaker;

  /// No description provided for @devMic.
  ///
  /// In en, this message translates to:
  /// **'Microphone'**
  String get devMic;

  /// No description provided for @devCamera.
  ///
  /// In en, this message translates to:
  /// **'Camera'**
  String get devCamera;

  /// No description provided for @statusDisabled.
  ///
  /// In en, this message translates to:
  /// **'Disabled'**
  String get statusDisabled;

  /// No description provided for @statusOffline.
  ///
  /// In en, this message translates to:
  /// **'Not connected'**
  String get statusOffline;

  /// No description provided for @statusPendingCam.
  ///
  /// In en, this message translates to:
  /// **'Awaiting PC request'**
  String get statusPendingCam;

  /// No description provided for @statusPendingMic.
  ///
  /// In en, this message translates to:
  /// **'Awaiting permission'**
  String get statusPendingMic;

  /// No description provided for @statusStandby.
  ///
  /// In en, this message translates to:
  /// **'Standby'**
  String get statusStandby;

  /// No description provided for @statusPlayingNow.
  ///
  /// In en, this message translates to:
  /// **'Playing'**
  String get statusPlayingNow;

  /// No description provided for @statusRecordingNow.
  ///
  /// In en, this message translates to:
  /// **'Recording'**
  String get statusRecordingNow;

  /// No description provided for @statusFilmingNow.
  ///
  /// In en, this message translates to:
  /// **'Streaming'**
  String get statusFilmingNow;

  /// No description provided for @gateDisabled.
  ///
  /// In en, this message translates to:
  /// **'Disabled'**
  String get gateDisabled;

  /// No description provided for @gateEnabledOffline.
  ///
  /// In en, this message translates to:
  /// **'Enabled · Not connected'**
  String get gateEnabledOffline;

  /// No description provided for @gateEnabledPendingCam.
  ///
  /// In en, this message translates to:
  /// **'Enabled · Waiting for the PC request'**
  String get gateEnabledPendingCam;

  /// No description provided for @gateEnabledPendingMic.
  ///
  /// In en, this message translates to:
  /// **'Enabled · Waiting for recording permission'**
  String get gateEnabledPendingMic;

  /// No description provided for @gateEnabledStandby.
  ///
  /// In en, this message translates to:
  /// **'Enabled · Standby'**
  String get gateEnabledStandby;

  /// No description provided for @gateEnabledActive.
  ///
  /// In en, this message translates to:
  /// **'Enabled · In use'**
  String get gateEnabledActive;

  /// No description provided for @gateSubDisabled.
  ///
  /// In en, this message translates to:
  /// **'This device is switched off: the session is unregistered and no hardware starts, so nothing the PC does can wake it.'**
  String get gateSubDisabled;

  /// No description provided for @gateSubOffline.
  ///
  /// In en, this message translates to:
  /// **'Enabled, but not connected to the PC yet. It goes to standby automatically once connected.'**
  String get gateSubOffline;

  /// No description provided for @gateSubPendingCam.
  ///
  /// In en, this message translates to:
  /// **'The camera hardware is OFF. When the PC presses \"Request Phone Camera\" your phone shows a confirmation banner; only after you allow it does the session register and go to standby — this privacy gate is deliberate.'**
  String get gateSubPendingCam;

  /// No description provided for @gateSubPendingMic.
  ///
  /// In en, this message translates to:
  /// **'The phone has no recording permission, so the microphone never reached standby. Open the Microphone page and tap \"Grant\"; allow the system dialog once and it stays usable.'**
  String get gateSubPendingMic;

  /// No description provided for @standbySpeaker.
  ///
  /// In en, this message translates to:
  /// **'Session ready, the PC is not pushing audio yet. Switching to \"Disabled\" stops receiving the stream at once.'**
  String get standbySpeaker;

  /// No description provided for @standbyMic.
  ///
  /// In en, this message translates to:
  /// **'Session registered, mic hardware OFF (no green dot, no battery drain). Switching to \"Disabled\" unregisters at once.'**
  String get standbyMic;

  /// No description provided for @standbyCamera.
  ///
  /// In en, this message translates to:
  /// **'Session registered, camera hardware OFF (no green dot, no battery drain). Switching to \"Disabled\" unregisters the session and closes the camera.'**
  String get standbyCamera;

  /// No description provided for @activeSpeaker.
  ///
  /// In en, this message translates to:
  /// **'The PC is pushing audio to the phone right now. Switching to \"Disabled\" stops playback and drops that channel.'**
  String get activeSpeaker;

  /// No description provided for @activeMic.
  ///
  /// In en, this message translates to:
  /// **'A PC app is recording from the phone mic right now, hardware ON. Switching to \"Disabled\" unregisters and closes the mic at once.'**
  String get activeMic;

  /// No description provided for @activeCamera.
  ///
  /// In en, this message translates to:
  /// **'A PC app holds the virtual camera right now, camera hardware ON. Switching to \"Disabled\" unregisters the session and closes the camera.'**
  String get activeCamera;

  /// No description provided for @detailDisabled.
  ///
  /// In en, this message translates to:
  /// **'Disabled · the PC cannot use it'**
  String get detailDisabled;

  /// No description provided for @detailOffline.
  ///
  /// In en, this message translates to:
  /// **'Goes to standby automatically once the PC is connected'**
  String get detailOffline;

  /// No description provided for @detailPendingCam.
  ///
  /// In en, this message translates to:
  /// **'Connected · the camera starts after the PC asks and you confirm'**
  String get detailPendingCam;

  /// No description provided for @detailPendingMic.
  ///
  /// In en, this message translates to:
  /// **'Connected · waiting for recording permission on the phone'**
  String get detailPendingMic;

  /// No description provided for @detailStandby.
  ///
  /// In en, this message translates to:
  /// **'On standby · hardware off, no battery drain'**
  String get detailStandby;

  /// No description provided for @detailActiveSpeaker.
  ///
  /// In en, this message translates to:
  /// **'Playing the audio the PC sends'**
  String get detailActiveSpeaker;

  /// No description provided for @detailActiveMic.
  ///
  /// In en, this message translates to:
  /// **'The PC is using your microphone right now'**
  String get detailActiveMic;

  /// No description provided for @detailActiveCamera.
  ///
  /// In en, this message translates to:
  /// **'The PC is using your camera right now'**
  String get detailActiveCamera;

  /// No description provided for @gateOff.
  ///
  /// In en, this message translates to:
  /// **'← Disabled'**
  String get gateOff;

  /// No description provided for @gateOffCurrent.
  ///
  /// In en, this message translates to:
  /// **'← Disabled (now)'**
  String get gateOffCurrent;

  /// No description provided for @gateOn.
  ///
  /// In en, this message translates to:
  /// **'Enabled →'**
  String get gateOn;

  /// No description provided for @gateOnCurrent.
  ///
  /// In en, this message translates to:
  /// **'Enabled (now) →'**
  String get gateOnCurrent;

  /// No description provided for @grantPermission.
  ///
  /// In en, this message translates to:
  /// **'Grant'**
  String get grantPermission;

  /// No description provided for @paramsTitle.
  ///
  /// In en, this message translates to:
  /// **'Parameters'**
  String get paramsTitle;

  /// No description provided for @micNoPermission.
  ///
  /// In en, this message translates to:
  /// **'The phone has no recording permission yet; grant it so it can act as the PC microphone'**
  String get micNoPermission;

  /// No description provided for @micStateRecording.
  ///
  /// In en, this message translates to:
  /// **'Recording: mic hardware ON'**
  String get micStateRecording;

  /// No description provided for @micStateStandby.
  ///
  /// In en, this message translates to:
  /// **'Standby: mic hardware OFF'**
  String get micStateStandby;

  /// No description provided for @micStateStarting.
  ///
  /// In en, this message translates to:
  /// **'Starting…'**
  String get micStateStarting;

  /// No description provided for @micStateOff.
  ///
  /// In en, this message translates to:
  /// **'Not enabled'**
  String get micStateOff;

  /// No description provided for @micUplinkBitrate.
  ///
  /// In en, this message translates to:
  /// **'Uplink bitrate'**
  String get micUplinkBitrate;

  /// No description provided for @micUplinkFormat.
  ///
  /// In en, this message translates to:
  /// **'{khz} kHz · Mono'**
  String micUplinkFormat(int khz);

  /// No description provided for @micUplinkSampleRate.
  ///
  /// In en, this message translates to:
  /// **'Uplink sample rate'**
  String get micUplinkSampleRate;

  /// No description provided for @micRate48.
  ///
  /// In en, this message translates to:
  /// **'48 kHz · pass-through'**
  String get micRate48;

  /// No description provided for @micRate44.
  ///
  /// In en, this message translates to:
  /// **'44.1 kHz · resampled on PC'**
  String get micRate44;

  /// No description provided for @micParamHint.
  ///
  /// In en, this message translates to:
  /// **'Changing the profile while on standby takes effect at once: the app re-sends the registration (mic_start) so the server learns the new rate. While recording, capture restarts silently with a gap of about 100 ms you barely notice.'**
  String get micParamHint;

  /// No description provided for @micHowToUse.
  ///
  /// In en, this message translates to:
  /// **'In the meeting / voice-input app on the PC, set the input device to\n\"CABLE Output (VB-Audio Virtual Cable)\"\n(once connected the phone is on standby; the mic turns ON only when a PC app uses it,\nand OFF the instant that app lets go)'**
  String get micHowToUse;

  /// No description provided for @micStatusDisabled.
  ///
  /// In en, this message translates to:
  /// **'Disabled — the PC cannot use the phone microphone'**
  String get micStatusDisabled;

  /// No description provided for @micStatusConnectedPerm.
  ///
  /// In en, this message translates to:
  /// **'Connected to the PC. Tap the button below to grant recording, then it just works.'**
  String get micStatusConnectedPerm;

  /// No description provided for @micStatusConnectedAuto.
  ///
  /// In en, this message translates to:
  /// **'Goes to standby automatically once connected to the PC — nothing to do'**
  String get micStatusConnectedAuto;

  /// No description provided for @micStatusMuted.
  ///
  /// In en, this message translates to:
  /// **'Muted — the mic stays off even when a PC app uses it'**
  String get micStatusMuted;

  /// No description provided for @micStatusStandbyLong.
  ///
  /// In en, this message translates to:
  /// **'On standby — mic closed, opens automatically when a PC app needs it'**
  String get micStatusStandbyLong;

  /// No description provided for @micStatusOpening.
  ///
  /// In en, this message translates to:
  /// **'The PC is using it, opening the microphone...'**
  String get micStatusOpening;

  /// No description provided for @micStatusLive.
  ///
  /// In en, this message translates to:
  /// **'Recording — the PC is using your microphone right now'**
  String get micStatusLive;

  /// No description provided for @micBadgeWaitingPerm.
  ///
  /// In en, this message translates to:
  /// **'Waiting for recording permission'**
  String get micBadgeWaitingPerm;

  /// No description provided for @micBadgeOff.
  ///
  /// In en, this message translates to:
  /// **'Not enabled'**
  String get micBadgeOff;

  /// No description provided for @micBadgeMuted.
  ///
  /// In en, this message translates to:
  /// **'Muted · waiting to unmute'**
  String get micBadgeMuted;

  /// No description provided for @micBadgeStandby.
  ///
  /// In en, this message translates to:
  /// **'On standby · mic hardware off'**
  String get micBadgeStandby;

  /// No description provided for @micBadgeStarting.
  ///
  /// In en, this message translates to:
  /// **'Opening…'**
  String get micBadgeStarting;

  /// No description provided for @micBadgeLive.
  ///
  /// In en, this message translates to:
  /// **'Recording · the PC is using it'**
  String get micBadgeLive;

  /// No description provided for @camNoPermission.
  ///
  /// In en, this message translates to:
  /// **'The phone has no camera permission; grant it so the PC can use the camera'**
  String get camNoPermission;

  /// No description provided for @camQuality.
  ///
  /// In en, this message translates to:
  /// **'Quality'**
  String get camQuality;

  /// No description provided for @camNoModes.
  ///
  /// In en, this message translates to:
  /// **'No usable mode for the current lens'**
  String get camNoModes;

  /// No description provided for @camProbing.
  ///
  /// In en, this message translates to:
  /// **'Probing… (reads the modes this phone supports once the PC connects)'**
  String get camProbing;

  /// No description provided for @camAutoHighest.
  ///
  /// In en, this message translates to:
  /// **'Auto (highest)'**
  String get camAutoHighest;

  /// No description provided for @camRotate.
  ///
  /// In en, this message translates to:
  /// **'Rotate {deg}°'**
  String camRotate(int deg);

  /// No description provided for @camParamHint.
  ///
  /// In en, this message translates to:
  /// **'Parameters can be changed in any state: while filming the camera restarts silently to apply them; on standby or disconnected the choice is remembered and applied when the camera opens. Only switching to \"Disabled\" locks them — otherwise the control would be lying to you.'**
  String get camParamHint;

  /// No description provided for @camFrozenLabel.
  ///
  /// In en, this message translates to:
  /// **'Frozen · tap to resume the picture'**
  String get camFrozenLabel;

  /// No description provided for @camFreezeLabel.
  ///
  /// In en, this message translates to:
  /// **'Freeze frame (session kept, picture stops)'**
  String get camFreezeLabel;

  /// No description provided for @camHowToUse.
  ///
  /// In en, this message translates to:
  /// **'In the meeting / camera / streaming app on the PC, pick the webcam\n\"Unity Video Capture\"\n(after enabling, the phone waits; the camera opens only while the PC watches,\nand turns OFF the instant it stops)'**
  String get camHowToUse;

  /// No description provided for @camIosNote.
  ///
  /// In en, this message translates to:
  /// **'iPhone note: because of iOS limits the camera can only stream while this page is open and the screen is awake (going to the background or locking stops it). Microphone and speaker are not affected.'**
  String get camIosNote;

  /// No description provided for @camRecOverlay.
  ///
  /// In en, this message translates to:
  /// **'REC · the PC is using your camera'**
  String get camRecOverlay;

  /// No description provided for @camPreviewOff.
  ///
  /// In en, this message translates to:
  /// **'Camera off · standby'**
  String get camPreviewOff;

  /// No description provided for @camTapFullscreen.
  ///
  /// In en, this message translates to:
  /// **'Tap for fullscreen'**
  String get camTapFullscreen;

  /// No description provided for @camExitFullscreen.
  ///
  /// In en, this message translates to:
  /// **'Exit fullscreen'**
  String get camExitFullscreen;

  /// No description provided for @camStamp.
  ///
  /// In en, this message translates to:
  /// **'{quality} · {facing}'**
  String camStamp(String quality, String facing);

  /// No description provided for @camRecStamp.
  ///
  /// In en, this message translates to:
  /// **'REC · {quality} · {facing}'**
  String camRecStamp(String quality, String facing);

  /// No description provided for @camStatusDisabled.
  ///
  /// In en, this message translates to:
  /// **'Disabled — the PC cannot use the phone camera'**
  String get camStatusDisabled;

  /// No description provided for @camStatusConnectedPerm.
  ///
  /// In en, this message translates to:
  /// **'Connected to the PC; grant the camera and it is ready to use'**
  String get camStatusConnectedPerm;

  /// No description provided for @camStatusStandbyAuto.
  ///
  /// In en, this message translates to:
  /// **'Standby after connecting; the PC can also request and the phone confirms'**
  String get camStatusStandbyAuto;

  /// No description provided for @camStatusFrozen.
  ///
  /// In en, this message translates to:
  /// **'Frozen — the camera stays off even while the PC watches'**
  String get camStatusFrozen;

  /// No description provided for @camStatusStandbyLong.
  ///
  /// In en, this message translates to:
  /// **'On standby — camera closed, opens automatically when the PC watches'**
  String get camStatusStandbyLong;

  /// No description provided for @camStatusOpening.
  ///
  /// In en, this message translates to:
  /// **'The PC is watching, opening the camera...'**
  String get camStatusOpening;

  /// No description provided for @camStatusLive.
  ///
  /// In en, this message translates to:
  /// **'Filming — the PC is using your camera right now'**
  String get camStatusLive;

  /// No description provided for @camBadgeWaitingPerm.
  ///
  /// In en, this message translates to:
  /// **'Waiting for camera permission'**
  String get camBadgeWaitingPerm;

  /// No description provided for @camBadgeOff.
  ///
  /// In en, this message translates to:
  /// **'Not enabled'**
  String get camBadgeOff;

  /// No description provided for @camBadgeFrozen.
  ///
  /// In en, this message translates to:
  /// **'Frozen · waiting to resume'**
  String get camBadgeFrozen;

  /// No description provided for @camBadgeStandby.
  ///
  /// In en, this message translates to:
  /// **'On standby · camera hardware off'**
  String get camBadgeStandby;

  /// No description provided for @camBadgeOpening.
  ///
  /// In en, this message translates to:
  /// **'Opening…'**
  String get camBadgeOpening;

  /// No description provided for @camBadgeLive.
  ///
  /// In en, this message translates to:
  /// **'Filming · the PC is watching'**
  String get camBadgeLive;

  /// No description provided for @camForceStopped.
  ///
  /// In en, this message translates to:
  /// **'The PC forced the camera off'**
  String get camForceStopped;

  /// No description provided for @facingBack.
  ///
  /// In en, this message translates to:
  /// **'Rear'**
  String get facingBack;

  /// No description provided for @facingFront.
  ///
  /// In en, this message translates to:
  /// **'Front'**
  String get facingFront;

  /// No description provided for @switchToFront.
  ///
  /// In en, this message translates to:
  /// **'Switch to front'**
  String get switchToFront;

  /// No description provided for @switchToBack.
  ///
  /// In en, this message translates to:
  /// **'Switch to rear'**
  String get switchToBack;

  /// No description provided for @errConnectFirst.
  ///
  /// In en, this message translates to:
  /// **'Connect to the PC on the Home page first'**
  String get errConnectFirst;

  /// No description provided for @errMicPermission.
  ///
  /// In en, this message translates to:
  /// **'Recording permission is needed to act as the PC microphone'**
  String get errMicPermission;

  /// No description provided for @errCamPermission.
  ///
  /// In en, this message translates to:
  /// **'Camera permission is needed to act as the PC webcam'**
  String get errCamPermission;

  /// No description provided for @errMicDenied.
  ///
  /// In en, this message translates to:
  /// **'Recording permission denied — allow it in System Settings'**
  String get errMicDenied;

  /// No description provided for @errMicBusy.
  ///
  /// In en, this message translates to:
  /// **'The microphone is held by another app — close it and retry'**
  String get errMicBusy;

  /// No description provided for @errMicUnsupported.
  ///
  /// In en, this message translates to:
  /// **'Unsupported sample-rate / channel combination'**
  String get errMicUnsupported;

  /// No description provided for @errMicStart.
  ///
  /// In en, this message translates to:
  /// **'Microphone failed to start: {code}'**
  String errMicStart(String code);

  /// No description provided for @errCamDenied.
  ///
  /// In en, this message translates to:
  /// **'Camera permission denied — allow it in System Settings'**
  String get errCamDenied;

  /// No description provided for @errCamNoLens.
  ///
  /// In en, this message translates to:
  /// **'This phone has no such lens'**
  String get errCamNoLens;

  /// No description provided for @errCamTimeout.
  ///
  /// In en, this message translates to:
  /// **'Opening the camera timed out — close other camera apps and retry'**
  String get errCamTimeout;

  /// No description provided for @errCamBusy.
  ///
  /// In en, this message translates to:
  /// **'The camera is held by another app — close it and retry'**
  String get errCamBusy;

  /// No description provided for @errCamStart.
  ///
  /// In en, this message translates to:
  /// **'Camera failed to start: {code}'**
  String errCamStart(String code);

  /// No description provided for @netError.
  ///
  /// In en, this message translates to:
  /// **'Connection error: {error}'**
  String netError(String error);

  /// No description provided for @netFailed.
  ///
  /// In en, this message translates to:
  /// **'Connection failed: {error}'**
  String netFailed(String error);

  /// No description provided for @spkMuteTitle.
  ///
  /// In en, this message translates to:
  /// **'Mute on this phone'**
  String get spkMuteTitle;

  /// No description provided for @spkMuteSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Keeps the connection and the PC-side state; the phone just stays quiet'**
  String get spkMuteSubtitle;

  /// No description provided for @spkSourceLabel.
  ///
  /// In en, this message translates to:
  /// **'Source'**
  String get spkSourceLabel;

  /// No description provided for @spkSourceValue.
  ///
  /// In en, this message translates to:
  /// **'PC system audio (WASAPI loopback capture)'**
  String get spkSourceValue;

  /// No description provided for @spkFormatLabel.
  ///
  /// In en, this message translates to:
  /// **'Audio format'**
  String get spkFormatLabel;

  /// No description provided for @audioMono.
  ///
  /// In en, this message translates to:
  /// **'Mono'**
  String get audioMono;

  /// No description provided for @audioStereo.
  ///
  /// In en, this message translates to:
  /// **'Stereo'**
  String get audioStereo;

  /// No description provided for @spkFormatValue.
  ///
  /// In en, this message translates to:
  /// **'{khz} kHz · {ch} · 16-bit'**
  String spkFormatValue(String khz, String ch);

  /// No description provided for @spkBitrateLabel.
  ///
  /// In en, this message translates to:
  /// **'Link rate'**
  String get spkBitrateLabel;

  /// No description provided for @spkBitrateValue.
  ///
  /// In en, this message translates to:
  /// **'about {mbps} Mbps'**
  String spkBitrateValue(String mbps);

  /// No description provided for @spkReceivedLabel.
  ///
  /// In en, this message translates to:
  /// **'Received'**
  String get spkReceivedLabel;

  /// No description provided for @spkPlayStatusLabel.
  ///
  /// In en, this message translates to:
  /// **'Playback'**
  String get spkPlayStatusLabel;

  /// No description provided for @spkPlayDisconnected.
  ///
  /// In en, this message translates to:
  /// **'Not connected'**
  String get spkPlayDisconnected;

  /// No description provided for @spkPlayMuted.
  ///
  /// In en, this message translates to:
  /// **'Receiving (muted on this phone)'**
  String get spkPlayMuted;

  /// No description provided for @spkPlayPlaying.
  ///
  /// In en, this message translates to:
  /// **'Playing'**
  String get spkPlayPlaying;

  /// No description provided for @spkPlayWaiting.
  ///
  /// In en, this message translates to:
  /// **'Connected · waiting for the PC to stream'**
  String get spkPlayWaiting;

  /// No description provided for @spkParamsLocked.
  ///
  /// In en, this message translates to:
  /// **'Phone volume and the buffer profile (low latency ↔ stability) need changes in the native player (AudioTrack volume and bufferDuration) and are not open in this build: use the phone\'s side keys for volume, and the buffer stays fixed by the server\'s lowest-latency policy.'**
  String get spkParamsLocked;

  /// No description provided for @spkHowToUse.
  ///
  /// In en, this message translates to:
  /// **'Nothing to choose on the PC: AudioServer grabs the system audio directly,\nso the phone becomes the PC\'s second speaker once connected.\nTo stop the phone making any sound at all, switch the slider above to \"Disabled\".'**
  String get spkHowToUse;

  /// No description provided for @settingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// No description provided for @languageTitle.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get languageTitle;

  /// No description provided for @langAuto.
  ///
  /// In en, this message translates to:
  /// **'Follow system'**
  String get langAuto;

  /// No description provided for @langEn.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get langEn;

  /// No description provided for @langZh.
  ///
  /// In en, this message translates to:
  /// **'简体中文'**
  String get langZh;

  /// No description provided for @langAutoCurrent.
  ///
  /// In en, this message translates to:
  /// **'System language detected: {locale}'**
  String langAutoCurrent(String locale);

  /// No description provided for @langHint.
  ///
  /// In en, this message translates to:
  /// **'Globally common words (WiFi, USB, IP, WebSocket, kHz) are not translated. Your choice is remembered on this phone.'**
  String get langHint;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
