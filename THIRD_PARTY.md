# Third-party components

- librime 1.17.0 (33e7814), BSD-3-Clause: https://github.com/rime/librime
- whisper.cpp 1.7.5, MIT: https://github.com/ggml-org/whisper.cpp
- Whisper small multilingual Q5_1 weights, MIT: https://huggingface.co/ggerganov/whisper.cpp
- Rime luna-pinyin / prelude / essay: https://github.com/rime (individual license files included in the application).
- librime-octagram (ec52e48 / dfcc151 build), **GPL-3.0**: https://github.com/lotem/librime-octagram — shipped as `Contents/Frameworks/rime-plugins/librime-octagram.dylib` and loaded at runtime.
- rime-octagram-data grammar model `zh-hant-t-essay-bgw.gram`, **LGPL-3.0**: https://github.com/lotem/rime-octagram-data — shipped as data in `Contents/Resources/Rime`.
- The Rime official binary includes Boost, glog, LevelDB, marisa, OpenCC, yaml-cpp and the upstream Lua / octagram / predict plugins. Their upstream notices, Lua's license, and the model license are included in `Contents/Resources/Licenses`.

Exact dictionary revisions and downloaded archive hashes are recorded in `dependencies.lock.json`.
The application is an independent frontend using librime; it does not incorporate Squirrel frontend code.

## Licensing note before distributing

librime itself is BSD-3-Clause, but the octagram grammar plugin is GPL-3.0 and is now bundled and
dynamically loaded. Distributing the application as one package therefore requires terms compatible
with GPL-3.0. This is a decision about release, not about local use: the grammar feature is two files
(`Contents/Frameworks/rime-plugins/librime-octagram.dylib` and `Contents/Resources/Rime/*.gram`, plus
`grammar.yaml`). Removing them from `Scripts/build.sh` drops the optional `grammar:/hant?` patch in
`luna_pinyin.schema.yaml` back to a no-op, leaving the rest of the input method unchanged, so they can
also be offered as a separate user-installed add-on instead.

Optional local correction runtime (not bundled): Ollama, MIT, https://github.com/ollama/ollama .
Downloaded correction weights: Qwen3 4B Instruct (Q4_K_M), Apache-2.0, https://ollama.com/library/qwen3:4b-instruct . Stored in the user's Ollama model cache, separate from the application.
