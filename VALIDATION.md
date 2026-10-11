# Validation — updated 2026-10-11

## Jev 保留选词习惯（2026-10-11）

- 复现原因：本机开启 Jev。隔离的真实 Rime 会话输入 `youxiang`，首次「邮箱」排第一，选择「又想」后再次输入即为「又想」第一；原 Jev 排序随后只比较语境分数，覆盖了学习结果。「用词统计」原本仅计数，不参与排序。
- 增加独立、跨输入客户端共享的本地选词记录：精确拼音、完整中文上屏词条、次数和最近使用时间。相同拼音下，完整匹配先按个人次数、最近使用时间排列，其余候选保留原 Jev 顺序；显示的 Jev 分数不改写。部分覆盖不会超过完整覆盖，已有中文前缀时不把整段记录套到剩余片段。
- 记录不依赖「用词统计」，不发送到 Jev；只接受完整中文提交，取消、原始英文和未完成的分段选择不记录。文件权限 0600；最多 2048 个拼音、每拼音 8 个词，后台延迟约 0.5 秒合并写入，失活和正常退出时刷新。原有 Rime 学习库保持不变，新增记录从本版开始积累。
- 新增 `CandidateLearningTests`：真实 Rime 选词与学习、第二个进程读取持久记录、相反的模拟云端评分仍保留习惯、词频/最近使用排序、原始分数、跨页索引、拼音隔离、部分候选、取消/Shift、存储上限及权限通过。测试只使用临时目录和模拟评分，没有发送真实输入或调用付费 API。
- 构建和所有功能回归通过。沙箱内完整测试在最后的证书信任检查处无法读取系统钥匙串；在允许钥匙串访问的环境中单独重跑严格签名验证、权限声明和安装回归，全部通过。未修复既有 `WordStatsView.swift` 的 Combine 导入警告。
- 已安装并重载输入法，恢复原输入源；安装包二进制与构建产物一致。旧版备份：`~/Library/Application Support/LocalInput/Backups/20261011-173731-yDb199/LocalInput.zip`。日志在 `build/candidate-learning-{build,tests,install}.log`。
- 未做真实目标应用中的键盘/鼠标端到端验收；回归通过 Rime API 及实际持久化进程验证。设置说明已更新；离屏渲染仅能检查文本，原生 GroupBox/SecureField 受 ImageRenderer 支持限制。

## 猜你想说 — text recognition on the CPU (2026-09-24)

- User report: 「猜你想说暂不可用 · TextRecognition.CRImageReaderError error 1」. The helper's log showed `E5RT Error: e5rt_execution_stream_operation_create_precompiled_compute_operation_with_options call failed (Code: 13)` on every request. Its compiled Neural Engine model cache, `~/Library/Caches/org.localinput.Voice/com.apple.e5rt.e5bundlecache`, still had its folders but 0 bytes of content (emptied 2026-09-24 16:04, presumably a system cache purge); the runtime failed instead of recompiling. A fresh process, which uses its own cache, recognized the same screenshot fine.
- Text recognition now runs on the CPU for every compute stage (`setComputeDevice`). On this M4, for the 1970 × 1696 WeChat screenshot: CPU 0.25 s vs 1.32 s on the default path in a fresh process, same 55 lines. The stale cache was left in place (unused).
- Added a diagnostic `LocalInputVoice --recognize-text <image>` mode (like `--transcribe`). In the helper's own context, with the broken cache still present: 55 lines in 0.39–0.44 s (built and installed copies), and no E5RT errors in the log. Build, tests and install passed; certificate requirement unchanged.

## 猜你想说 — inline preview so ↑↓ stay in the panel (2026-09-24)

- User retest: ↑↓ still scrolled WeChat (by then arrows were deliberately passed to the app), and the user wants them to choose a suggestion. While pinyin is being composed, WeChat leaves keys to the input method because marked text exists. The highlighted suggestion is now previewed in the input box as marked text through the existing `VoiceComposition`; ↑↓ re-mark it in place, Return / keypad Enter / Tab commit the highlighted row, 1–3 commit that row, Esc or Backspace take it back (restoring any selected text), other keys, clicks, focus changes, voice and a host-initiated `commitComposition` take it back before continuing. Validity while previewing uses the composition's own marked-range check. If a host does not keep the preview as marked text, the guess is cancelled.
- Tests: key map (`ContextGuessTests`) and a guess-shaped preview scenario on a real `NSTextView` (`LiveVoiceTests`: re-mark in place, still marked, cancel leaves the field unchanged). Build, full tests and install passed; certificate requirement unchanged. **Not verified in WeChat** — whether WeChat now keeps ↑↓ away from the chat view needs the user's check. Known risk shared with voice preview: an app that finalizes marked text by itself (e.g. on some focus changes) could keep the previewed suggestion.

## 猜你想说 — number keys instead of arrows (2026-09-24)

- User report: in WeChat, ↑↓ moved WeChat's chat view. WeChat draws its own UI (`owl.framework` on ANGLE, no Qt); like Qt and Chromium text engines, it still acts on a key the input method consumed unless the key inserted or marked text. Enter worked because accepting inserts text; a highlight move changes no text, so the arrow also reached WeChat. The panel now takes only keys that insert a suggestion — 1–3 (and keypad 1–3) for that row, Return / keypad Enter / Tab for the first — plus Esc; arrows close the panel and stay with the app. Rows are numbered again. Unit-tested key map; panel rendered (`build/guess-numbered-panel.png`); build, tests and install passed. Not exercised in WeChat itself.

## 猜你想说 — Enter accepts (2026-09-24)

- User report: Enter on a suggestion did nothing. Only Tab accepted; Enter counted as "any other key", closed the panel and went to WeChat (nothing to send). The panel's keys are now `ContextGuess.panelKey`: Return, keypad Enter and Tab insert the highlighted suggestion (insert only, never send), ↑↓ choose, Esc closes; other keys close the panel and reach the app. Unit-tested; build, tests and install passed. Key delivery in WeChat itself was not automated.

## 猜你想说 — source label (2026-09-24)

- The helper's `ready` reply carries `source` (界面文字 / 截图识别, or 光标前文字 when only the typed text was available); the input method shows 「来源：…」 in the panel footnote, so automatic fallback to the screenshot is visible. The field is optional, and a reply from an older helper still decodes (tested). Panel rendered (`build/guess-source-panel.png`); build, tests and install passed with the unchanged certificate requirement.

## 猜你想说 — reading the input box's column (2026-09-24)

- User report from WeChat: the suggestions were chat names from the left chat list (e.g. 「亚马逊社招求职内」). WeChat exposes no accessibility text (5 elements, no focused element), so OCR was the source; it read the whole window and interleaved chat-list and conversation lines by row. In the replayed screenshot about 70 % of the 536 characters sent to the model were chat-list text, and the model copied them.
- `ContextGuess.arrange` now lays out both accessibility and OCR text by position: only the column the field is in (its left edge extends through text reaching the field without a gap, so bubbles that start left of the input box stay and a chat list does not), header text as the title, text level with the field left out, text outside the window dropped, lines without letters dropped, and each line marked ← / → / · by its side. `dropSmallText` drops OCR text under 65 % of the median line height (thumbnails, pasted screenshots). The input method sends the caret line from its first character (`firstRect(forCharacterRange:)`), so the column is right even with text already typed. The prompt explains the marks and forbids copying names/UI; `accept` also drops suggestions sharing a run of ≥ max(4, 60 %) characters with any screen line.
- Replaying the user's screenshot through the real `arrange`, `LocalCorrector.guess` and `accept`: the context became the conversation only (title 「…（5）」; `→ 这个想法很有意思`, `← Yiyi`, `← 不错`), and suggestions changed from chat names to 「我觉得可以试试」「这个想法我也有同感」「一起做吧」 (0.7 s warm). The local `gpt-oss:20b` could not be compared: Ollama 0.34.2 rejects its blob (`unsupported tensor … size overflows`).
- `Tests/ContextGuessTests.swift`: synthetic chat layout (sidebar, header, sides, field row, text below), no-caret order, empty column, bubbles left of the input box, off-window text, small text, copied chat names. Build and tests passed (`build/guess-layout-*.log`); installed build keeps the same certificate-based designated requirement.

## Stable local code signing (2026-09-24)

- Root cause of permissions “turned on but not working”: the ad-hoc designated requirement is `cdhash H"…"`, so every rebuild invalidated the TCC grant. tccd logged `Failed to match existing code requirement for subject org.localinput.inputmethod.LocalInput and service kTCCServiceMicrophone` against seven different build hashes on 2026-09-23 — the helper's microphone requests are attributed to the outer bundle, and voice input was affected too.
- `Scripts/local-signing.sh` creates (once) a self-signed code-signing certificate, “Qingyan Local Signing”, in a private keychain file under `~/Library/Application Support/LocalInput/Signing` (0700; random keychain password in a 0600 file; partition list lets `codesign` use it without prompts). It is not added to the keychain search list or the login keychain. `build.sh` signs every dylib, the helper and the outer app with it by default; `QINGYAN_SIGN_IDENTITY` still overrides it and `-` forces ad-hoc.
- Verified in a throwaway keychain that two different binaries get the identical requirement `identifier … and certificate leaf = H"…"`. The installed outer app and helper now report `identifier "org.localinput.inputmethod.LocalInput"` / `"org.localinput.Voice" and certificate leaf = H"817991881c502d14f829ec4b1eb443cc428255ba"`; strict verification, build and tests passed (`build/stable-signing-*.log`). The keychain search list still contains only the login keychain.
- Existing grants still carry old cdhash requirements. They have to be reset once (`tccutil reset All` for both bundle IDs) and granted again. That is a user action; it was not done here.

## 猜你想说 — manual trigger (2026-09-24)

- At the user's request, guessing no longer starts on focus. It starts only on the guess shortcut (default ⌃⌥G, configurable in the 猜你想说 tab; key chords or function keys only, never the voice shortcut) or the input-menu item. The shortcut is consumed only while the feature is on; key repeat is swallowed without restarting. Pending Rime input is committed first. The panel shows 「正在猜你想说…」 at once, then suggestions or a reason (no context, focus moved, model gave nothing, error, 15 s timeout); Esc closes it.
- `ShortcutRecorder` gained label, modifier-key, conflict and saved-message parameters; the voice recorder rejects the guess key and vice versa. Settings migration keeps other preferences when a stored guess key is invalid or a held modifier.
- `Tests/ContextGuessTests.swift` covers the default key, round trip, invalid-key fallback and exact-chord matching. Full build and tests passed (`build/guess-shortcut-build.log`, `build/guess-shortcut-tests.log`); rendered the tab (`build/guess-shortcut-settings.png`). Real key delivery in external apps is not automated here.

## Context permissions: stale grants and backup identity (2026-09-23)

- Reproduced in the installed app on macOS 27.0 (26A428): 「轻言语音」 is enabled in System Settings → Device Control and Data Access, but the helper reports accessibility unavailable. Screen & System Audio Recording still shows the disabled date-named entry `20260918-225614`; quitting/reopening System Settings does not refresh that name. The LaunchServices cleanup and localized names below did **not** repair the existing permission entries.
- Both installed bundles use ad-hoc signatures with `designated => cdhash ...`. TCC logs explicitly report a stored/current code-requirement mismatch for the outer application's microphone grant after earlier builds; its microphone grant was subsequently renewed. The inaccessible system TCC database was not modified, and this investigation does not claim a logged signature mismatch for Accessibility or ScreenCapture. There are no valid code-signing identities on this Mac. [Apple TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements) explains why ad-hoc identity cannot retain grants reliably across builds.
- `install.sh` now delegates bundle updates to `update-app.sh`: verifies source identity/signature, archives the existing version as a ZIP, preserves outer and helper bundle directories during replacement, removes obsolete files, and verifies the installed signature. This avoids moving the installed `.app` to a date-named backup that macOS can continue to track. The build copy and legacy `.app` backups are unregistered before the installed copy is registered.
- `QINGYAN_SIGN_IDENTITY` can select a stable certificate for all signed components; the default remains ad-hoc with an explicit build notice. No certificate/keychain or system permissions were changed. The settings tab now distinguishes the helper's accessibility entry from the outer app's screen entry, reveals the corresponding bundle, allows a manual refresh/exit, and explains how to replace stale grants. Permission errors now match the selected context source.
- Passed the full build, `Scripts/test.sh`, strict nested signature verification, and signed-fixture installation regressions. The latter cover first installation, preservation of outer/helper directory inodes, same-size/same-mtime updates, obsolete-file removal, symlinks, restoration of a signed ZIP backup, and rejection of invalid signatures, same-source destinations and unrelated apps. Logs: `build/context-permissions-build.log`, `build/context-permissions-tests.log`.
- The existing `--render-context` export omitted composited SwiftUI content and inherited the launching process's permissions, so it is **not** evidence of correct layout or real helper authorization. Live installation, replacement of the stale grants and an end-to-end context read still await user approval; the running installed version is unchanged.

## Bundle display names in privacy settings (2026-09-23)

- System Settings listed the screen-recording entry as 「20260918-225614」: macOS shows a bundle's file name, and LaunchServices had resolved the shared bundle ID to one of 27 registered backup copies. Base `CFBundleDisplayName` now equals the file names (`LocalInput`, `LocalInput Voice`) with `LSHasLocalizedDisplayName`, and `en`/`zh-Hans` `InfoPlist.strings` supply 「轻言输入法」/「轻言语音」. `install.sh` unregisters every backup (tolerating never-registered copies) and re-registers the installed app and helper.
- Verified under the en-US system language: `FileManager.displayName` returns 「轻言输入法」 and 「轻言语音」 for the installed bundles; `input-source status` still reports 「轻言输入法」; LaunchServices now lists only the installed and `build/` copies. Two stale copies outside this repo (`~/Desktop/Qingyan-0.1.15`, `~/Documents/New project/LocalInput/build`) were unregistered once by hand. Build, tests and strict signature passed.

## 猜你想说 — context guess (2026-09-23)

- Opt-in (missing key = off). On `activateServer` the input method waits 0.4 s, then writes a private IPC request (frontmost PID, up to 128 UTF-16 characters before the caret, caret rect). The voice helper reads the focused window — accessibility text walked outward from the focused element, or a ScreenCaptureKit window capture with Vision `accurate` zh-Hans/en-US OCR split at the caret — and asks the shared local Qwen3 4B (same `num_ctx`, so no reload) for exactly three suggestions under a JSON schema. Tab inserts, ↑↓ select, Esc/typing/click/voice/focus change cancel; results are shown only if client, PID, selection and preceding text are unchanged.
- `Tests/ContextGuessTests.swift`: settings migration, IPC round trip, excerpt budget/marker/whitespace/duplicates, suggestion cleanup (numbering, quotes, newlines, typed-prefix overlap, copied screen messages, length, count). Full `Scripts/build.sh` and `Scripts/test.sh` passed (`build/context-guess-build.log`, `build/context-guess-tests.log`).
- End to end with a scratch fixture window (fake chat + focused field) through the real `ContextReader` and model: accessibility read 0.03 s, total 1.4 s; screenshot + OCR read 0.35 s, total 1.5 s. The first Chinese OCR on this Mac took 14 s (one-time system model compile); the helper now warms Vision at launch when the feature is on. The first OCR run showed the model echoing on-screen messages; the prompt and a filter now drop them.
- Prompt checked against local Qwen on chat, email continuation, search box, English Slack, long context (1,140 tokens: 3.1 s) and an injected instruction in screen text (ignored).
- Found a stale Ollama server from 2026-09-17 on port 11435 that answered `/api/version` but could not initialize Metal, so every generate call returned HTTP 500; stopped it. The companion starts a fresh one on demand.
- Rendered the new settings tab (`--render-context`, `build/context-settings.png`) and the suggestion panel (`build/guess-panel-preview.png`); the normal candidate panel renders pixel-identical to the previous build.
- Installed to `~/Library/Input Methods/LocalInput.app` (hashes match the build; strict signature verified) and restarted the idle LocalInput processes. **Not verified:** real IMK focus events in external apps, granting permissions to the installed helper, and panel placement/Tab acceptance in WeChat, browsers or Terminal.

## Word statistics (2026-09-23)

- Added opt-in per-word counts for committed text: Rime commits and Shift raw-letter commits count as typed; finalized voice commits count as voice. Stored in `word-stats.json` (0600) as per-word typed/voice totals, last-use date and daily totals only. Writes are batched about 2 s after a commit and done off the main thread; each flush re-reads the file so clearing from settings is not undone by in-memory state.
- Segmentation: picked candidates of 1–3 Han characters stay whole (NaturalLanguage splits 显眼包 into 显眼/包); longer commits and voice use `NLTokenizer`, with 常用词 rejoined. Numbers, emoji and punctuation are dropped. Characters typed directly in English mode never reach the input method and are not counted.
- `Tests/WordStatsTests.swift`: segmentation, picked words, vocabulary merge, per-source/daily counts, batched writes, file permissions, clear-then-record and settings migration (missing key = off). Full `Scripts/build.sh` and `Scripts/test.sh` passed. Logs: `build/word-stats-build.log`, `build/word-stats-tests.log`.
- Rendered the new tab with sample data under a scratch `CFFIXED_USER_HOME` (`--render-word-stats`) and inspected it. Recording from real typing in external apps was not automated here.

## 0.1.16 — 轻言输入法 rebrand (2026-09-18)

- Reviewed the pending name and two-character icon changes. Standardized the input-source bundle name, settings heading/window title, setup instructions, microphone guidance, installer output and README on 「轻言输入法」. The voice helper now uses 「轻言语音」 for both bundle names. Internal bundle IDs, executable names and data paths remain stable for existing settings and permissions; short 「轻言设置」 labels and the Qingyan romanization remain intentional.
- The template badge contains transparent 「轻言」 lettering at 30 × 16 points, with 30 × 16 and 60 × 32 pixel TIFF representations. Assigned the distinct resource URL `InputIcon-Qingyan.tiff` to avoid the previous single-character icon cache. Inspected `build/icon-preview-0.1.16.png` and checked the installed TIFF's dimensions, monochrome mask and transparent interior (`build/rebrand-icon-0.1.16.log`).
- `bash Scripts/build.sh` and `bash Scripts/test.sh` passed, including pinned dependency checksums, Ice/Rime vocabulary and grammar, custom phrases, native composition, shortcut/state guards, correction rules, bundle permission declarations, plist validation and strict signing. Logs: `build/rebrand-build-0.1.16.log`, `build/rebrand-tests-0.1.16.log`. The restricted build initially blocked Xcode's SwiftUI macro process; the normal local build succeeded. Sandboxed native tests emitted input-service connection warnings but all assertions passed.
- Installed version **0.1.16 (17)** at `~/Library/Input Methods/LocalInput.app` using `Scripts/install.sh`; the previous bundle is backed up at `~/Library/Application Support/LocalInput/Backups/20260918-225614.app`. Installed outer/helper plists, executables and icon match the built files by SHA-256; installed deep/strict signature verification passed. Log: `build/rebrand-install-0.1.16.log`.
- **Verified in macOS UI:** System Settings → Keyboard → Text Input → Edit visibly lists 「轻言输入法」 with the two-character 「轻言」 badge. The live Carbon/TIS registry reports `enabled=1`, `selected=1`, localized name 「轻言输入法」, and an icon URL resolving to the installed `Contents/Resources/InputIcon-Qingyan.tiff`. The same source was already selected before installation; installation preserved that selection. Log: `build/rebrand-input-source-0.1.16.log`. `input-source status` now includes the registered name and icon URL for future checks.
- Rendered and inspected the rebuilt settings view (`build/settings-0.1.16.png`): the full heading and onboarding name fit without clipping, and the existing left-Option shortcut is retained. The sandboxed render could not launch AppKit; the normal local render completed.
- This acceptance covers the rebrand and installed input-source presentation. Microphone-to-target acceptance and the broader external-app compatibility matrix remain untested here; historical limitations below still apply.

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

## Jev 候选评分排序（2026-09-22）

- 改用 Score：一次请求为当前候选池每项单独评分，最多 20 项，统一五级语境适配标准；0–4 换算为 0–100 分，按原始精度降序，同分保留 Rime 顺序。
- 本地验证：每项均生成 Score 问题、全量排序、同分稳定性、四页候选无遗漏/重复、键盘和鼠标的原始 Rime 索引映射、短末页、缺分/异常分数及 HTTP 错误回退通过。原有词库、语音、设置、纠错测试通过。
- 真实 API 联调：使用本机已配置 Key 和公开示例，对 Rime 实际返回的 20 个 `youxiang` 候选逐项评分。一次联调中「汽车」首位油箱 88.2 分（1.04 秒）、「我现在」首位又想 65.8 分（0.44 秒）、「请发到我的」首位邮箱 99.2 分（0.36 秒）。这些是当次观察，不是固定分数或普遍延迟保证。
- 修复实测发现的精度问题：API 的 score 和各档 probabilities 分别四舍五入，重建均值可能差 0.03。校验允许五档概率及 score 的两位小数舍入误差；排序始终使用 API 返回的 score。增加原始返回数据回归用例。
- 原生候选面板已渲染检查，所有展示候选带 Jev 分数。评分范围仍为前 20 项；超出该范围后使用原生 Rime 候选。界面不会等待网络后才响应输入。

## 拼音覆盖范围分组（2026-09-22）

- 从固定版本 librime 1.17.0 的公开 C API 获取候选高亮后的提交预览：已选中文前缀 + 候选 + 未转换的原始拼音。用未转换后缀取得真实结束位置，查询后恢复原高亮；不试选、不提交，不按字数或词典读音推测覆盖。
- 原生 Rime 测试覆盖：`youxiang` 的完整范围 8 字节、`游戏／有戏／右席` 5 字节、「有」3 字节；已选中文前缀、显式拼音分隔符、非首页原高亮恢复、重复读取稳定性均通过。中间光标编辑保守回退，不修改会话。
- 排序测试：完整匹配即使分数更低，也先于部分匹配；部分匹配按覆盖长度递减；相同范围才按分数递减，同组同分保留原顺序。跨页映射与「部分」标记通过。
- 真实 Jev 联调：三个公开例句各 20 项，全程校验覆盖范围顺序以及组内分数顺序。「汽车」油箱首位、「我现在」又想首位、「请发到我的」邮箱首位。较高分的「游戏」「有」仍排在完整匹配之后。此次覆盖元数据读取约 0.001 秒，非性能保证。
- 新界面已渲染检查：部分匹配显示「（部分）」，候选栏明确提示完整匹配优先；设置页解释分组与组内排序。

## 语音识别改用 SenseVoice（2026-09-23）

- 识别引擎由 whisper.cpp 1.7.5 + Whisper Small Q5_1 换成 sherpa-onnx 1.13.8 + SenseVoice Small INT8（2024-07-17，开启 ITN，带标点、数字写成阿拉伯数字）。未选 2025-09-09 版：该版为粤语微调，不输出标点。
- SenseVoice 是非自回归模型，实时预览与定稿走同一次整段解码。Whisper 专用的预览上下文裁剪、1 秒以下补静音、无语音概率过滤全部移除；RMS 静音门槛与“繁转简”保留。
- 常用词不再送入识别：SenseVoice 没有提示词接口，sherpa-onnx 的热词只支持 transducer 模型。常用词仍用于本地纠错与 Rime 自定义短语。
- 旧设置里指向 `.bin` 的自定义模型路径自动回退到内置模型；自定义模型须为 `.onnx`，同目录需有 `tokens.txt`。
- 同一批合成样本（`build/audio-tests`，未提供常用词）：
  - 中文 5.41 秒：「你好，欢迎使用轻言输入法。今天下午3点开会。」Whisper 未加提示时为「青年输入法」。定稿解码 0.07 秒，进程内首次解码含加载 0.36 秒；Whisper 分别约 0.36 秒与 11 秒。
  - 英文 4.28 秒：「Hello, welcomecom to local In. Please send the report tomorrow morning.」比 Whisper 差，产品名识别失败。
  - 中英混合（中文音色合成英文）：自动检测只输出「明天下午3点开会。」，英文段丢失；设为中文时为「明天下午3点开会，plus.」。Whisper 同样未通过。
  - 模型自带真人样本：普通话、英文、粤语均正确（英文 gold 误为 code）。
- 修复实测发现的退出崩溃：模型仍在后台加载时调用 `exit()`，ONNX Runtime 静态对象先被销毁导致 SIGSEGV（`--render-settings` 必现）。退出与渲染路径现在先等待识别线程空闲。
- 单次转写峰值内存约 600 MB。语音辅助应用的运行库 30 MB、模型 228 MB。
- `bash Scripts/build.sh`、`bash Scripts/test.sh`、`bash Scripts/test-live-speech.sh` 通过。
- **未做**：真实麦克风的全流程验收，未运行 `Scripts/install.sh`。
