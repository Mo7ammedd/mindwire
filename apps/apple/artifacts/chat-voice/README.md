# Voice messages — October 7, 2026

## Native harness voice update

Voice now checks the connected harness's native capability before offering Start. Codex uses its native conversation audio connection while retaining the selected coding model. Claude's current SDK only supports voice dictation with a microphone local to its CLI, so the mobile UI explains that limit and keeps an explicit recorded-file option. A file attachment is never presented as native listening.

The real installed Codex app-server passed a loopback microphone/speaker protocol check with both native and custom coding-provider authentication, including a coding model with no audio modality. Focused lifecycle/race checks, SDK checks, and the Codex/Claude presentation test passed. The presentation test ran in the iPhone simulator; the physical build passed but UI Automation timed out. No live voice account entitlement or production inference was tested. Native voice requires the updated app and companion daemon.

## Earlier recorded-file checks

Recording stays as audio by default. The sheet provides a waveform, elapsed time, playback, an optional caption, and Add to message. Sending and queuing use the existing attachment pipeline. Codex receives native audio only when its selected model advertises audio input; otherwise the unchanged recording is sent as a file, including for Claude. Optional transcription runs on the device and is never required for recording.

These captures use the production views on a physical iPhone 12 running iOS 26.5.2. Explicit test fixtures generate an AAC sample and an editable Arabic caption; they do not record the microphone, contact a live model, or edit personal projects.

| Screen | Capture |
| --- | --- |
| Recording and waveform | [iPhone](iphone-recording.png) |
| Playback and audio review | [iPhone](iphone-review.png) |
| Original audio queued during a turn | [iPhone](iphone-queued-audio.png) |
| Optional Arabic caption, audio retained | [iPhone](iphone-optional-arabic.png) |

Validation completed:

- 22 iOS voice, attachment, and queue unit tests passed.
- Physical iPhone UI checks passed for recording/playback/queue/Stop/restore, cancel/background, denied permission recovery, and optional editable Arabic captions. The review height was adjusted after the initial small-phone check exposed a covered secondary action.
- The iPad recording/playback/queue/Stop/restore UI check passed.
- The physical iPhone uploaded an image, original AAC recording, and a multi-chunk file over its saved SSH pairing to an isolated Mac daemon. Real Codex received the image and native audio and read the file with its command tool. A fresh transport restored all three attachments with identical audio/file bytes, and Stop → Send passed.
- Go race tests passed for the agent, Codex adapter, HTTP API, and artifact packages. Go vet and SDK TypeScript checking passed.
- Real Codex CLI WAV and M4A fresh/resumed turns passed against a private local model endpoint, both with and without an audio input capability.
- Real native HTTP queue checks passed for Codex native audio, Codex file fallback, and Claude file fallback. Each accepted input appeared once; attachments survived history, forking, and deleting the source chat.

The physical transfer check uses an isolated daemon and a private local model endpoint with an explicit audio-capable test catalog. It verifies the native transport without live model inference or modifying production model capabilities. The installed CLI can carry audio, but the selected real model still needs to advertise audio input to interpret it natively.

Relevant result bundles are `/tmp/MindwireVoiceUnits-20261007.xcresult`, `/tmp/MindwireVoiceDeviceReady-20261007.xcresult` (cancel/background and permission), `/tmp/MindwireVoiceDeviceQueue-20261007.xcresult`, `/tmp/MindwireVoiceDeviceRetry-20261007.xcresult` (Arabic review), `/tmp/MindwireVoiceAndNavigationDeviceFinal-20261007.xcresult` (physical SSH upload), and `/tmp/MindwireFolderVoiceIPad-20261007.xcresult` (voice case). The last bundle also contains an unrelated folder-drag failure, tracked with the project navigation fixes.
