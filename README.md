# Pixel Agency Run

The run workflow of a [Media Engine Specification (MES)](https://github.com/xocialize/media-engine-spec) client, as a
Swift package: find an engine, choose an operation, set its controls from the engine's own descriptor, give inputs,
run, and keep or save the results. Everything goes through the open MES SDKs. It runs the Image profile's operations
and, from v0.2.0, the Audio profile's (MES Audio 0.1): speech streamed as it's made, voices from the engine, audio
inputs and results, and data results shown as text. From v0.3.0 it runs the Video profile's (MES Video 0.1): clips in
and out with their facts, stills while a clip is made, and the acceptance some licences ask of each user.

It was [Pixel Agency Lite](https://github.com/xocialize/pixel-agency-lite)'s (LITE-16, Lite v0.4.2). It moved here so
that the apps built on it link a package rather than an app repo (Gaea decision G-20, AB-D-0182; work order
AB-T-0360):

| App | How it uses the workflow |
|---|---|
| [Pixel Agency Desktop](https://github.com/xocialize/pixel-agency-desktop) | Embeds the views in its own window, adds its built-in engine in process, and runs each run as a durable ticket. |
| Gaea Lab | The MES reference client (Gaea G-14), built on it: images, audio with streamed speech (G2), and video (G3). |
| Pixel Agency Lite | Where it started. Lite is deprecated once Gaea Lab has what is worth keeping. |

## Install

```swift
.package(url: "https://github.com/xocialize/pixel-agency-run.git", from: "0.3.0"),
// target dependencies:
.product(name: "PixelAgencyRun", package: "pixel-agency-run"),
.product(name: "PixelAgencyRunUI", package: "pixel-agency-run"),
```

macOS 26. It depends on media-engine-spec from 0.9.0 (MESClientKit, MESCore, MESFormsUI) and DesignScaffold. No MLX.

## Contents

| Product | What it is |
|---|---|
| `PixelAgencyRun` | **The model.** Engines: discovery over Bonjour (`_mes-engine._tcp`), pairing, credentials in the keychain (`EngineDirectory`, `KeychainCredentialStore`). A run: inputs, controls from the descriptor, progress, results and what happened (`RunWorkflow`, `RunSession`). The session list, the working folder (`WorkingFolder`) and masks. |
| `PixelAgencyRunUI` | **The views**, on MESFormsUI and DesignScaffold. Engines, operations and this session's runs; the canvas (input, progress and previews, results with Save, Share, Use as Input); the controls from the descriptor, media slots and the mask brush with "select subject"; what happened; working-folder onboarding. |
| `pa-run` | The same workflow without a window, for the MES client conformance suite. |

## Audio (MES Audio 0.1)

| | What the workflow does |
|---|---|
| **Audio inputs** | `MediaItem` reads an audio file's duration, rate and channels (no image probing); a result used as input brings its own facts. The inspector's audio slots are MESFormsUI's `AudioInputWell` (drop or choose, play). "Use as Input" sends an audio result to the next operation's audio slot. |
| **Voices** | Every run's form gets `VoiceSource(engine:)`, so the `voice` parameter is MESFormsUI's picker over the chosen model's voice list (Base §6.5), with samples. |
| **Streaming** | Where an output can stream and the model that will run streams (`supports.stream`), streaming is on by default (`RunSession.streamByDefault()`, called again when the model changes; the form's "Stream as it's made" toggle turns it off). The request asks for `pcm_s16le`. While the job runs, its chunks come in order through MESClientKit's `ChunkReader`: `RunSession.streamed` says how much has come and how soon the first chunk did, `chunks()` gives them to a view (those already received first), and `onChunk` to code. The final file is still collected. An executor forwards chunks with `report(chunk:)`. |
| **Barge-in** | `cancel()` stops passing chunks on at once and releases the job, which the engine stops within a chunk (Base §11). |
| **Results** | Audio results play in the canvas (`AudioPlayerView`) with their duration, rate and channels from the output's facts; a streamed run plays as it arrives (`PCMStreamPlayer`), with Stop releasing the job. Data and text results (edit_speech's `transcript`, compose's `timestamps` and `score`) are kept as results and shown as text (`RunResult.text`). Audio results get waveform thumbnails. |

`pa-run --stream audio` streams that output: the chunks go to `<out>/audio-stream.wav` as they arrive, the final file is
saved as usual, and the first chunk's latency is printed:

```bash
pa-run --engine http://127.0.0.1:17600/mes/v0 --operation audio.speak --model mock-clone --text 'text=Hello there.' --file voice_ref=clip.wav --stream audio --out out
```

## Video (MES Video 0.1)

| | What the workflow does |
|---|---|
| **Video inputs** | A clip (`video/mp4`, `video/quicktime`) is a `MediaItem` of kind `.video`, never probed as an image. `MediaItem.reading(_:)` reads a file's size, rate, frames, duration and sound with AVFoundation (`VideoFacts.read`); a result used as input brings the engine's facts (`VideoFacts(output:)`). `videoFacts` gives them as MESFormsUI's `VideoFacts`. The inspector's video slots are `VideoInputWell` (drop or choose, play, thumbnails). "Use as Input" and carry-over fill a slot of the item's kind, so a generated clip becomes extend's, retake's, upscale's or interpolate's `video`. Generate's keyframes are images, several in one slot, with the `keyframe_times` parameter. |
| **Previews** | `job.preview` events with `at_s` (Video §1.14) go into `RunSession.framePreviews` (MESFormsUI's `FramePreviews`) as well as `preview`. The canvas shows the newest large and all of them in a `FramePreviewStrip` while the job runs. An executor forwards events with `apply(_:)`. |
| **Users' acceptance** | An offer whose licence says `user_accept_required` (Base §10.2 rule 4) runs once its user accepts the terms. `RunWorkflow.acceptances` (`LicenseAcceptances`, in the user's defaults by default) is every run's, and the form sends each accepted licence of the operation's offers in `policy.accepted`. `RunSession.needsAcceptance` lists what to show before a run; the inspector shows `LicenseAcceptanceView` above Run, and the accepted licences with Revoke. A run refused 422 `policy_unmet` with reason `terms_not_accepted` keeps the licences in `refusedTerms` and the canvas asks for acceptance instead of showing an error; an executor reports one with `report(failure:)`. |
| **Results** | Video results play in the canvas (`VideoPlayerView`) with their facts, with the clip's frames (`FrameThumbnails`) under them, and get a still as their thumbnail in the session list. Warnings (`duration_snapped`, `size_snapped`, `keyframe_moved`, `span_snapped`, `soundtrack_fitted`, …) show in What happened, as every profile's do. |

`pa-run` takes clips with `--file name=path`, sends `--accept <spdx>` (repeatable) in `policy.accepted`, writes the stills
the engine sends to `<out>/previews/` with `--previews`, and prints a video result's facts. Refused for want of
acceptance, it says which `--accept` to add:

```bash
pa-run --engine http://127.0.0.1:17600/mes/v0 --operation video.generate --model mock-ltx-standard --text 'prompt=a lighthouse at dusk' --file first_frame=still.png --accept LicenseRef-Mock-Video-Community --previews --out out
```

## Embedding the run workflow

Four hooks let an app embed the workflow without forking it:

- **An engine inside the app.** `EngineDirectory.addLocal(_:)` lists an in-process engine (MESInProcess) first, and
  connects to it without the network. Desktop's built-in engine is one.
- **Runs executed elsewhere.** Set `RunWorkflow.executor` to a `RunExecutor` and each run it starts is handed to the
  executor, which reports progress and results back through the session's `report` methods. The views show the run
  as they show any other. Desktop's executor turns each run into a durable ticket that stores results in its library
  before confirming them.
- **The views in pieces.** `RunEngineList`, `RunOperationList`, `RunSessionList`, `RunWorkflowCanvas`,
  `RunWorkflowInspector` and `runWorkflowPairing(_:)` let an app compose the workflow into its own window.
  `RunWorkflowView` is one arrangement of them (Lite's window).
- **An allow-list.** `EngineDirectory.admits` decides which engines the app may use. A refused engine leaves
  `entries` for `refused`, and `connect` and pairing refuse it. The engine list says how many are hidden.

`RunWorkflow.profiles` limits the operations offered to some MES profiles (nil offers all), and
`RunWorkflow.useAsInput(_:)` also takes a plain `MediaItem`, so an app can put its own files into a run.

Every exchange the workflow has with an engine, in order, with the code and the spec section for each, is in Lite's
[HOW-LITE-TALKS-TO-ENGINES.md](https://github.com/xocialize/pixel-agency-lite/blob/main/docs/HOW-LITE-TALKS-TO-ENGINES.md).

## Tests

```bash
swift build --product pa-run
```

```bash
swift test
```

The tests run every Image operation end to end against the MES mock engine, with controls entirely from descriptors,
and the client conformance suite through `pa-run`. Against the mock's audio engine: a streamed speak with a cloned
voice (and the preset voice list), barge-in, an edit with an audio input and its transcript, generate with count 2,
compose with timestamps, an audio result as the next input, and `pa-run --stream`. Against the mock's video engine:
generate with a first frame and keyframes (facts, previews, the grid's warning), users' acceptance (held back by the
form, refused by the engine and shown as needing acceptance, run with it, kept, revoked), a generated clip extended
and the extended clip upscaled through "Use as Input", and `pa-run --accept --previews` with a clip as a `--file`.

## Licence

Apache-2.0 ([LICENSE](LICENSE)).
