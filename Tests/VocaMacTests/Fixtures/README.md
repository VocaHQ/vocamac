Short English speech fixtures generated locally with macOS `say`, Samantha,
220 words per minute, mono signed 16-bit PCM at 16 kHz. Leading/trailing
samples below amplitude 150 were trimmed, preserving 10 ms on either side.

- `short-yes.wav`: "Yes", 0.369875 seconds. Before padding, Moonshine Tiny
  v2 with sherpa-onnx 1.13.4 returned "Yes, yes, yes".
- `short-stop.wav`: "Stop", 0.3684375 seconds. Before padding, the same
  configuration returned "Star".

These are synthetic voices, not user recordings. Integration tests skip
models which are not installed; audio preparation tests always run in CI.
