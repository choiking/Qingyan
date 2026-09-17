# Validation — 2026-09-12

## 0.1.10 — black badge

- Changed only the badge fill to fixed black at the user's request. The rounded shape, centered transparent “言” cutout, and 1x/2x sizes are retained.
- Rendered and inspected the asset preview; build, bundle permission declarations and strict signing checks passed. Installed 0.1.10 with a backup and refreshed the input-menu process.
- Uses `InputIcon-BlackBadge.tiff` to refresh the icon resource URL.

## 0.1.9 — blue badge with transparent lettering

- Changed the input-source icon to a blue rounded-square badge with a centered “言” glyph cut out of its alpha channel. The glyph is transparent, so it reveals the actual background instead of using white paint.
- Preserved explicit 16-point 1x/2x representations. Rendered actual-size and enlarged previews on white, black and dark slate backgrounds and visually inspected them: `build/icon-preview-0.1.9.png`.
- Verified fully transparent pixels within the letter at both densities. Build, bundle-permission checks and strict signatures passed; 0.1.9 was installed with a backup, and the input-menu agent was refreshed.
- Uses a new `InputIcon-Badge.tiff` asset URL to distinguish it from both earlier icons.

## 0.1.8 — centered blue input-source icon

- Replaced the black baseline-positioned glyph on a 32-point canvas with a 16-point blue icon. The visible CoreText outline bounds determine both horizontal and vertical centering, with transparent padding.
- Bundled explicit 1x and 2x representations (16 and 32 pixels, both 16 points), preserving color rather than using a template image. A distinct asset filename avoids reusing the old icon URL.
- Alpha-bound inspection confirmed symmetric visible bounds: 1–14 in the 16-pixel representation and 2–29 in the 32-pixel representation. Production build, bundle permissions and strict code-signature checks passed; 0.1.8 was installed with a backup of the prior version.
- Rendered and visually checked actual-size and enlarged previews on white, black and dark slate backgrounds: `build/icon-preview-0.1.8.png`. This verifies the asset; the system menu's cached rendering may need an input-source switch to refresh.

## 0.1.7 — faster initial and incremental preview

- Reduced the first-attempt threshold from 1.5 s to 0.8 s and the update interval from 1.5 s to 0.35 s. Retained the single-job gate, minimum-new-audio check, and stale-result/session protections. The helper scheduler ticks at 100 ms; completed replies send a session-ID-only notification so inline updates need not wait for the 150 ms fallback poll.
- Verified the pinned whisper.cpp 1.7.5 implementation skips audio shorter than 1 s. Short provisional input is padded to 1.1 s with silence after the original-input RMS check. Final audio is unchanged. Source: https://raw.githubusercontent.com/ggml-org/whisper.cpp/v1.7.5/src/whisper.cpp (whisper_full_with_state).
- Provisional decoding uses an audio context scaled to the available audio, with a conservative minimum of 512 frames, rather than always using the default 1500 frames. Short drafts have a token cap; recordings over 8 s are uncapped, and recordings over 30 s retain multi-segment decoding. Final decoding retains its original parameters and has a separate decoder state so automatic language detection does not inherit the provisional context size. Model weights are shared.
- Synthetic auto-language fixture results: English first output at 0.8 s audio took 0.45 s decoding; subsequent short partials took 0.15–0.17 s. Chinese 0.8 s was too ambiguous and produced no accepted text; 1.2 s audio produced “你好 欢迎” in 0.17 s, followed by 0.17–0.21 s updates. These are isolated offline measurements; they exclude microphone startup and UI delivery and are not end-to-end latency guarantees. Existing Chinese name/homophone errors remain.
- Production 0.1.7 build, native composition/state/dictionary regressions, microphone bundle declarations and strict code-signature verification passed. Installed with the prior version backed up and user preferences preserved. Actual microphone-to-target latency remains to be checked by the user.
- Experiments with 128-frame contexts caused English repetition and were rejected. The final 512-frame configuration passed short-preview output-length checks, silence rejection, and Chinese/English final transcription checks. Logs: `build/latency-chinese-0.1.7.log`, `build/latency-english-0.1.7.log`.

## 0.1.6 — live inline transcription

- Microphone capture supports non-destructive audio snapshots. After 1.5 seconds, the serial Whisper worker decodes growing audio snapshots at a bounded cadence with at most one partial job in flight. Finalization cancels/invalidates partial work and runs a full decode; stale callbacks cannot overwrite a final result or another session.
- Partial replies retain the recording phase and carry text to IMK. A dedicated composition owner updates one native marked range, tracks the resulting caret movement, and replaces that range exactly once on finalization. Cancellation restores the original selected text only while the same composition is still owned. Hosts without reliable selection access show partial text in the candidate panel instead.
- Switching to the input method starts the helper without activation; the helper warms the model on its serial worker without microphone access. This overlaps model preparation with the time before the first shortcut press.
- Native `NSTextView` regression passed: text is present before finalization, Unicode and emoji revisions replace rather than append, final replacement occurs once, duplicate/reentrant/late callbacks are rejected, selected text is restored on cancel, and changed caret positions block future writes. These are tests of an actual local AppKit text view, not external application automation.
- Synthetic audio regression passed using the actual local Whisper engine: English partials at 1.5 s and 3 s, then full 4.28 s audio; Chinese partials at 1.5 s and 3 s, then full 5.41 s audio. Warm decodes took 0.39–0.50 s; the first English partial including cold setup took 11.75 s. These are individual sample timings, not latency guarantees. The Chinese homophone error remains. Logs: `build/live-speech-english.log`, `build/live-speech-chinese.log`.
- The initial sandboxed audio test could not allocate Metal buffers; the rerun with GPU access passed.
- Final 0.1.6 production build, native/state/dictionary tests and strict bundle-signature checks passed. Repeated English fixture decodes took 0.52 s / 0.31 s / 0.32 s for the two partials and final. The settings view was rendered and visually inspected (`build/settings-0.1.6.png`). Installed to the existing user input-method location, with the old build backed up and Control+Z preserved.
- The scheduling tests cover cadence, one in-flight job, cancellation and old-job callbacks. Full physical keyboard/microphone/target-app acceptance remains a separate manual check.

## 0.1.5 — false release detection

- User reported “key released” while continuing to hold Control+Z. The 0.1.4 code incorrectly treated a false global `CGEventSource` key-state snapshot as release in both processes, including startup admission. No live trace established why that snapshot was false on this machine.
- Removed global keyboard polling. IMK key-up and relevant modifier-release events are now authoritative. An unrelated flags event cannot imply release of a required modifier.
- The input controller renews a separate per-session hold lease while its event state remains held. The helper uses this solely for process liveness; missing/stale (>= 3 s) leases discard recording with a connection-error message, never a “released” message or automatic insertion. Stop/cancel commands take precedence and cannot be overwritten by a lease update.
- Regression coverage: a 30-second hold with no intervening events, unrelated key-up/flags events, lease renewal/expiry/session mismatch, startup stop/cancel precedence, real release and JSON file separation. Existing shortcut migration, dictionary and bundle-permission checks are retained.
- Production build, regression tests and strict bundle-signature checks passed for 0.1.5. Installed to the existing user input-method location; prior build backed up.
- Physical keyboard/microphone/insertion acceptance still requires a real user trial. These regressions exercise production state and IPC policies, not actual macOS event delivery.

## 0.1.4 — push-to-talk and automatic insertion

- All saved shortcut keys now start recording on press and stop on release. Legacy modifier tap/hold settings keep their physical key; the old timing selector is removed.
- Key repeat cannot toggle recording. Releasing a required chord modifier also stops; using a dedicated modifier with another key cancels. Esc, mouse/focus changes and typing while transcribing cancel pending insertion.
- IMK handles key-up events. Both processes check physical key state every 150 ms as a fallback, and the helper rejects delayed requests whose shortcut has already been released or whose stop/cancel command arrived first.
- Ready results insert through InputMethodKit automatically, without changing the clipboard. Session, active controller, foreground PID and selection are checked; state is invalidated before calling insertText to avoid reentrant duplicate insertion.
- Passed production build, dictionary tests, shortcut press/release/repeat tests, left/right distinction, chord release/cancellation, delayed-start rejection, migration, focus/session guards, both-bundle microphone declarations and strict signature verification.
- Rendered and inspected the native settings view (`build/settings-0.1.4.png`); the existing Control+Z binding is preserved and the new hold/release instructions fit.
- Real physical-key delivery, microphone capture and insertion into external apps still require manual acceptance; state tests and offscreen rendering do not certify this end-to-end path.

## 0.1.3 — microphone permission crash

- Observed actual `LocalInputVoice` crash reports at 13:00:25 and 13:00:34, with TCC termination stating `NSMicrophoneUsageDescription` was missing.
- The 13:00:37 TCC attribution log resolves the nested helper executable to the outer `LocalInput.app` and uses `org.localinput.inputmethod.LocalInput` as the microphone permission subject. The helper already had the key; the outer app did not.
- Added the microphone purpose string to the outer bundle. A regression test now checks both source plists and both packaged plists, and also runs during every build.
- Permission UI distinguishes not-determined, authorized, denied and restricted states. “测试语音” requests permission if needed, then starts only if granted. No TCC database edits or permission bypasses.
- Removed authorization polling every 150 ms; refreshes now happen on activation, permission callbacks and recording attempts.
- Build, signing and regression tests passed. Real user authorization and microphone capture must still be checked in the normally launched app; CLI rendering can inherit the terminal's permission identity and is not evidence of authorization.

## 0.1.2 — single function keys and modifier gestures

- F1–F20 may be bound without Control / Option / Command. Text-entry keys retain the typing-preserving modifier requirement.
- Supports modifier-only bindings with left/right identity, tap (<0.5 seconds) and hold (>=0.5 seconds), firing on release. Settings offer direct presets and a trigger-mode picker.
- Passed state tests for bare F5, exact modifiers, old 0.1.1 shortcut migration, gesture serialization, tap/hold boundary, duplicate-release rejection, left/right distinction, simultaneous opposite-side keys, ordinary-key/mouse cancellation, modifier chords, focus reset and changes of binding mid-gesture.
- Production builds and the native settings view are checked separately. Actual Fn / Globe / media-key delivery remains dependent on keyboard and macOS settings; these tests do not certify physical-key routing or suppress system shortcuts.

## 0.1.1 — configurable dictation shortcut

- Added a local shortcut recorder in Settings, Escape / outside-click / focus-loss cancellation, and restore-default control.
- Verified legacy settings migrate without losing language, font, Shift preference or model path.
- Verified custom shortcut serialization, displayed label, exact key/modifier matching, old-shortcut rejection after a change, and harmless Caps Lock / hardware flags.
- Verified invalid shortcuts fall back without resetting unrelated preferences; plain typing, Shift-only letters, Escape, and common system input/search shortcuts are rejected.
- The input controller reads saved settings for each new invocation and pins the shortcut for an active recording. Menu / recording hints use the configured label.
- Automated state tests and production compilation passed. Native recorder interaction in a real desktop session still needs a manual check; view rendering does not certify physical shortcut delivery by macOS.

## Original 0.1.0 checks

Environment: macOS 26.6.2, Apple Silicon, Xcode 26.5. Local development build, not a production compatibility certification.

| Check | Result |
|---|---|
| Swift / Objective-C build | Passed; deployment target macOS 14, arm64 |
| Locked archive / model SHA-256 verification | Passed |
| Prebuilt Rime schema loaded without deployment in runtime test | Passed |
| `nihao` → `你好`, Space commits | Passed |
| `zhongwen` → `中文`, `hanyu` includes simplified `汉语` | Passed |
| Candidate index selection; page up / down; Backspace; Escape | Passed |
| Independent client composition buffers | Passed |
| Shift tap vs letter / modifier chords / long hold | Passed |
| Stale voice request / focus-generation rejection | Passed |
| Unicode IPC JSON round trip | Passed |
| Three-second silence | Rejected, no transcript, nonzero CLI exit |
| Chinese audio file → local transcript | Passed pipeline, contains name error described below |
| English audio file → local transcript | Passed sample |
| Chinese / English mixed audio | Significant errors in English segment; not accepted as accurate |
| Settings view rasterization | Rendered actual native view offscreen; inspected layout |
| Candidate panel rasterization | Rendered production panel with fixture candidates; inspected labels and layout |
| Application plists and nested code signatures | Passed |
| Per-user installation and TIS registration / enablement | Passed; existing input source remains selected |
| Installed input-method process startup | Remained running for three seconds without errors; test process then terminated |
| Live microphone permissions and capture | Not tested in normal launched app |
| Real TextEdit / browser / WeChat / VS Code / Terminal input | Not tested; computer-use service timed out |

## Audio samples

Generated locally with macOS `say`, written only under `build/audio-tests`. These are synthetic test clips, not microphone recordings or a representative benchmark.

Chinese reference:

> 你好，欢迎使用轻言输入法。今天下午三点开会。

Observed after simplified-character normalization:

> 你好,欢迎使用青年输入法。今天下午三点开会。

The homophone `轻言` → `青年` is a real recognition error, not corrected by a test-specific replacement.

English reference:

> Hello, welcome to Local Input. Please send the report tomorrow morning.

Observed:

> Hello, welcome to LocalInput. Please send the report tomorrow morning.

Mixed reference (Chinese voice synthesizing both languages):

> 明天下午三点开会，please bring your laptop.

Observed:

> 明天下午三点开会,不论要Supreme your laptop,

Mixed-language support is exposed by the model, but this sample fails the accuracy expectation. A real bilingual microphone corpus and model comparison are still needed.

In the initial runs, a 5.41-second Chinese clip took 11.09 seconds including model / Metal initialization; a 4.28-second English clip took 0.45 seconds in a later process. These isolated measurements are affected by system caches and do not establish steady-state latency.

## Manual acceptance checklist

- Select 轻言 in the input menu, then type `nihao` + Space in a new TextEdit document.
- Select the second candidate with a digit and with the mouse; verify the caret-relative panel position.
- Switch to English with a Shift tap. Check `Shift+A`, Cmd+C/V, selection, and arrow keys.
- In the launched voice app, grant microphone permission and use “测试语音”. Check stop / cancel, device disconnect and silence.
- In TextEdit, hold the configured shortcut (default Control+Option+Space), speak after the listening indicator and confirm words appear in the input field while the key remains held. Continue speaking and check revisions do not duplicate text. Release and confirm recording stops and the final result replaces the draft without Enter or an extra newline. Repeat with F5 and a single modifier; release a chord modifier before the main key; briefly tap before the helper launches.
- During transcription, switch applications or move the caret. Confirm no automatic insertion into the new target.
- Repeat basic typing in browser inputs, WeChat, VS Code and Terminal. Do not use sensitive documents for initial testing.
- Verify behavior on password / secure input fields and full-screen / multiple-display windows.


## 0.1.11 — vocabulary and optional local correction (2026-09-12)

- Built with Swift 5 / macOS 14 target; existing Rime, settings/shortcut, IPC and native NSTextView tests pass. New tests cover old settings/reply compatibility, vocabulary bounds, correction policy, signed/English/Chinese numbers, negation, known-name preservation and restoring only the unchanged owned text range. Native NSTextView can report a zero-length marked range at a real location when no text is marked; undo accepts this as well as NSNotFound.
- Downloaded Qwen3 4B Instruct Q4_K_M (approximately 2.5 GB) to the existing Ollama model cache. An isolated service uses 127.0.0.1:11435 and OLLAMA_NO_CLOUD=1. Tested automatic service startup, model loading, inference, cancellation of an active request and shutdown using the production LocalCorrector class. Default Ollama service settings and existing models were not changed.
- Seven synthetic correction fixtures completed locally in approximately 0.5–1.3 seconds per short sentence after loading. “欢迎使用青年输入法，今天下午三点开会。” became “欢迎使用轻言输入法，今天下午三点开会。” Numeric/negated text, English text, personal names and instruction-like dictated text stayed unchanged. “请把这个文见发给我。” also stayed unchanged: this conservative model does not catch every typo. These samples are not an accuracy benchmark.
- With Whisper vocabulary prompt “轻言、LocalInput”, the existing 5.41-second Chinese synthetic clip now returned “你好,欢迎使用轻言输入法。今天下午三点开会。” Warm partial decodes took approximately 0.09–0.12 seconds; final decode took 0.36 seconds. The first decode in a new test process took 11.33 seconds including initialization. The application prepares the speech model before microphone use, but cold-start cost is not eliminated.
- The English synthetic clip still produced English partial/final results with the same vocabulary prompt. Warm partials were approximately 0.09–0.10 seconds and final decoding 0.32 seconds. Product capitalization was not preserved by Whisper in that sample (“local input”); vocabulary is a hint, not forced substitution.
- Layout exported using the production SwiftUI correction view. Its AppKit text editor and toggle are represented by their current values for ImageRenderer; this verifies text/layout, not interactive control behavior. NSView cacheDisplay produced incomplete/transparent output on this system. The computer-use app lookup timed out, so live UI clicking and physical microphone → arbitrary external input field acceptance remain unverified.
- Finalization has an absolute eight-second correction deadline. Errors, overly long input and rejected edits keep the ASR original. Typing during the correction stage accepts raw speech and invalidates the asynchronous input session. Esc after corrected commit restores only if text, caret, focus and the owned range are unchanged; original text remains available in Settings for up to ten minutes. Existing generation and composition guards reject late replies.

Reproduce policy and native tests with `bash Scripts/test.sh`; run local model integration with `bash Scripts/test-local-correction.sh`. Audio regressions: `bash Scripts/test-live-speech.sh build/audio-tests/chinese.aiff zh '轻言、LocalInput'` and the equivalent English fixture with `en`. Metal/model tests need normal local execution outside the restricted command sandbox.

## 0.1.14 — Shift commits the typed spelling (2026-09-15)

Switching from Chinese to English now consumes Rime's raw input, clears its composition, and replaces the owned preedit with the exact typed spelling before continuing in English. The input menu's mode switch uses the same behavior. Confirmed text is not rewritten; the existing Shift tap versus chord/uppercase detection remains in place.

Bundled Rime tests passed for hello/nihao/xian, backspace-edited spelling, no Chinese commit, cleared candidates, repeated switching without duplicate text, and subsequent normal Chinese conversion. Existing native composition, Shift/shortcut state, correction, bundle and signature tests also passed. Installed 0.1.14 and restarted idle LocalInput processes with settings preserved. Physical keyboard acceptance in external applications was not automated.

## 0.1.15 — 八股文语法模型与常用词上屏 (2026-09-16)

启用了 librime 官方构建里一直存在但从未装配的 octagram 插件，并把「常用词」列表接到 Rime 自定义短语表。两件事都没有改动词库本身。

### 语法模型

- `luna_pinyin.schema.yaml` 本来就带可选补丁 `grammar:/hant?`，缺文件时静默跳过。补上 `grammar.yaml` 与 `zh-hant-t-essay-bgw.gram`（41 MB）后该补丁生效；编译后的 `build/luna_pinyin_simp.schema.yaml` 含 `grammar/language: zh-hant-t-essay-bgw` 与 `translator/contextual_suggestions: true`，对照组该项为 `grammar: 0`。
- 选 `hant` 而非 `hans`：词组来自 `essay.txt`，其条目是传承字（有 `中國` 无 `中国`），简体是输出阶段的 OpenCC 过滤结果。语法模型看到的是传承字。
- 插件按 librime 的 `plugins` 模块从 librime 同级的 `rime-plugins` 目录 dlopen，因此 traits 显式加载 `{"default", "plugins"}`。插件自带一份未初始化的 glog，会无视 traits 把 INFO 写到 stderr，故在初始化前设 `GLOG_minloglevel`；部署一次的 stderr 已实测为 0 字节。
- A/B 对照（`build/grammar-ab-0.1.15.log`，两组都用全新用户目录，互不含学习数据）：
  - 50 条整句首选：44 条相同，6 条不同。明确变好 2 条（`wozhuzainali` 握住在哪里 → 我住在那里；`wodemingzijiaolixiaoming` 我的名字角力小明 → 我的名字叫李小名），明确变差 1 条（`qingbangwochayixiahangban` 航班 → 行板），另 3 条两组都不对。
  - 上文重排（先上屏一段再输入下一段）11 组：7 组候选顺序不同，其中 1 组首选被纠正（`我住在` + `nali` 由「哪里」变为「那里」）；其余多为次选顺序变化，例如 `我们` + `de` 由「的 得 地」变为「的 地 得」。
- 结论：收益真实但有限，主要体现在候选排序而非整句首选，且不是单向改善。它不能替代把词加进「常用词」。

### 常用词上屏

- 库存 luna_pinyin 方案已经在译器链里带了 `table_translator@custom_phrase`（`initial_quality: 1`，`db_class: stabledb`），所以只需生成 `<用户目录>/custom_phrase.txt`，不涉及词库重建。
- 拼音按单字读音推导：词库单字行的第三列是多音字占比（`行 xing 91.78%` / `行 hang 8.22%`），据此排序，低于 5% 的读音丢弃，每字最多 3 个读音，每词最多 4 种拼法。含字母、数字、表情的词条不生成拼法，超过 12 字的词条跳过；任一字查不到读音时整词跳过，不写残缺编码。
- 生效路径：切回输入框时比对一个 stamp 文件，仅在列表真的变化时才扫描 2 MB 词库并重写。Rime 在会话建立时读该文件，且只要还有会话在用同一方案就保持打开，而本进程每个输入客户端各持一个会话，因此重写后调用 `cleanup_all_sessions()`，各控制器在下次激活时重建会话。实测：只销毁单个会话不足以生效。
- 已测：`nansheng` 首选「南生」、`qingyan` 首选「轻言」，均排在「男生」「青烟」之前；改写词表后未失效的会话仍用旧表，`invalidateSessions` 后立即改用新表。多音字排序、拼法上限、跳过规则、stamp 复用、表文件 0600 权限均有单元测试。
- 生成的词表是个人数据，与 stamp 一并写为 0600，放在已有的 0700 目录内。手工编辑会在列表变化时被覆盖。

### 其他

- `Scripts/test.sh` 与 `Scripts/build.sh` 的 clang 调用改为显式 `-isysroot "$(xcrun --sdk macosx --show-sdk-path)"`。此前裸 `xcrun --show-sdk-path` 解析到 Command Line Tools 的 MacOSX27.0 beta SDK，其 `.tbd` 存根包含 Xcode 链接器无法解析的 `arm64e.x1`，测试链接因此失败。这是既有环境问题，不是本次改动引起。
- 诊断开关：设 `LOCALINPUT_RIME_LOG_LEVEL=0`（可配合 `LOCALINPUT_RIME_LOG_DIR`）可看到 librime 与插件的加载日志，用于确认语法模型是否真的装载；默认两者都不设，不写任何日志。
- `build/module-cache` 保留着项目旧路径（`~/Documents/New project/LocalInput`）的模块记录，移动目录后需清空一次。
- 构建体积由约 212 MB 增至 254 MB，全部来自语法模型。
- 完整 `bash Scripts/test.sh` 通过：词库 / 语法模型 / 自定义短语端到端、原生合成、状态、纠错、常用词转换、plist、严格签名与权限声明。
- **未做**：真实麦克风到目标输入框的全流程验收，以及 TextEdit、浏览器、微信、VS Code、终端的手动兼容性检查仍未完成。本次也未运行 `Scripts/install.sh`，系统里安装的仍是 0.1.14。
- **发行前须知**：octagram 插件为 GPL-3.0，语法模型数据为 LGPL-3.0，现在都随应用分发。详见 `THIRD_PARTY.md`。
