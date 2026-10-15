# Voice

The composer microphone opens the selected harness's voice sheet. Voice capability comes from `capabilities.voice` and the on-demand `GET /voice` status, independently of the coding model's audio-file modalities. The microphone remains at the right of the composer.

Codex exposes an experimental native realtime conversation interface. **Start voice** opens that interface in the current idle chat, sends live PCM through the existing workspace connection, plays native replies, and displays the native transcript with a waveform. The selected coding model, native permissions, tools, and authentication remain unchanged. In particular, an Azure coding deployment does not itself supply access to Codex's voice backend; the sheet reports missing native voice access rather than treating an uploaded file as voice.

Claude Code currently exposes local microphone dictation, not a remote microphone API in its Agent SDK. Its capability reports `mode: dictation, support: native, remote: false`. The sheet explains that limitation and offers the separate recording option. Mindwire does not silently replace it with a transcription service.

**End voice**, dismissing the sheet, backgrounding, microphone interruptions, and network loss release local media. A coding task already started by native voice continues in the daemon; ordinary Stop still cancels it. One client owns each voice stream. Startup has a deadline, audio batches are ordered and acknowledged, and ambiguous audio delivery is never replayed automatically. The daemon keeps a bounded ephemeral media channel with a short lease, separate from durable chat replay. No voice worker, polling, or media buffers run when voice is unused.

## Recorded attachments

**Record an audio file** in the voice sheet and **Attach → Record an audio file** open the recording sheet. It shows a live waveform and elapsed time, then playback, an optional caption, and **Add to message**. Recording stays as audio by default. Stopping never transcribes or sends it automatically. The original M4A uses the existing file attachment upload, send, queue, retry, and history paths.

The microphone remains beside Send when the draft already contains photos, files, text, or another recording. **Add to message** appends the recording while preserving those existing items, so one send includes the entire draft. Canceling a recording leaves the draft unchanged. Stop remains independently available while the agent works.

Recordings use AAC at 24 kHz, mono, 64 kbit/s, with a ten-minute limit. Metering runs only during capture. One audio-session lease prevents two windows from recording or playing over each other and restores the app's previous audio settings. Permission callbacks, cancellation, and repeated taps are guarded by an operation ID. Backgrounding, losing the microphone route, or an interruption stops capture and retains the recording for review; returning never restarts the microphone automatically. Cancel removes the private temporary file. Adding copies its bytes into the existing draft before the sheet cleans up.

The daemon selects the transport from the installed harness and chosen model. Codex exposes `audioInput`, and its existing app-server connection checks `model/list` only when audio first arrives. A model advertising the `audio` input modality receives `localAudio`, including queued steering. Text-only models and Claude receive the unchanged recording as a readable file. This preserves the recording but does not give a text-only model audio understanding: that model needs an audio tool to interpret it. Mindwire never changes the model, invents an audio capability, or silently transcribes a recording.

Audio and other files retain their original order in one reference block when native audio is unavailable. Native history and recorded history merge into one user message, retaining durable attachment references across reconnects and forks. Temporary native input files remain available until their turn finishes. There is no audio-specific background poller or new transfer connection.

**Add transcription** is optional. iOS 26 SpeechAnalyzer uses SpeechTranscriber where supported, with DictationTranscriber for older iPhones. It runs on the device and reports language-asset download progress. Cancellation, timeout, unsupported languages, and speech failure leave the original recording available. Users can edit the caption, including Arabic, or explicitly turn off the audio attachment. No transcription service is required for recording or sending.

## Checks

- `TestNativeVoiceLocalProtocol` runs the installed Codex CLI against a loopback voice backend with private native configuration. It checks exact microphone and speaker PCM with both native and custom coding-provider auth modes; the coding model advertises no audio modality. Adapter lifecycle checks cover stopping before startup, continuing coding after End voice, voice surviving coding completion, duplicate batch receipts, and native transcript history. These checks do not verify a paid account's voice entitlement or rollout.
- The focused `testHarnessVoiceIsSeparateFromRecordedAttachments` checks Codex/Claude capability presentation and the recording-to-attachment transition using isolated UI fixtures. It passed on the iPhone simulator; the physical-device build passed, but Xcode timed out enabling device automation. It does not open a production voice account or the user's microphone.
- `ChatVoiceTests` covers permissions, idempotent capture, cancellation, original bytes, opt-in transcription, backgrounding, interruption, recording limits, and waveform reduction.
- `ChatVoiceInteractionTests` exercises waveform recording, AAC playback, queuing while running, Stop and restore, backgrounding, denied permission recovery, and optional editable Arabic captions. Its explicit fixtures generate AAC locally without opening the user's microphone.
- `ChatAttachmentLiveTests` uses the phone's saved SSH pairing to an isolated daemon and the real Codex CLI. It uploads an image, generated M4A, and a multi-chunk file, then verifies native inputs, a real file-tool read, restored attachment bytes, and Stop → Send. The model endpoint and model catalog are private fixtures; no live account inference or personal conversation is used.
- Companion Go tests exercise real native Codex fresh/resumed WAV and M4A inputs, both native-audio and file-only model capabilities, native steering receipts, multi-file history merging, Claude file fallback, and fork attachment retention. Production model capabilities remain unchanged.

The app and companion daemon both need this update for native voice. Workspaces running an older service show an update message and retain the existing recorded-file option. Reviewed recording screenshots and earlier checks are in `apps/apple/artifacts/chat-voice`.

Native interfaces: [Codex app-server](https://developers.openai.com/codex/app-server/) and [Claude Code voice dictation](https://code.claude.com/docs/en/voice-dictation).
