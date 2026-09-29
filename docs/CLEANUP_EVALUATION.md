# Evaluating transcript cleanup

Cleanup and recognition are separate measurements. Lower word error rate (WER)
is better, but grammatical edits can increase WER against verbatim speech.
Compare raw ASR to a human verbatim reference for recognition, and final output
to a human edited reference for cleanup. Neither metric proves meaning preservation.

## Installed-model evaluation

The opt-in `CleanupModelEvaluationTests` exercises Preserve output at Light,
Medium, Grammar, and High. It records the raw input, the actual model candidate,
the final merged output, latency, normalized edited-reference WER, and explicitly
annotated phrases that must survive. It verifies the installed model's SHA-256.
The built-in corpus is synthetic text, not an audio recognition benchmark.

```sh
VOCAMAC_CLEANUP_EVALUATION_MODEL=qwen25_1_5b_q4_k_m \
VOCAMAC_CLEANUP_EVALUATION_REPORT=/tmp/cleanup-evaluation.json \
swift test --filter CleanupModelEvaluationTests
```

An optional `VOCAMAC_CLEANUP_EVALUATION_CORPUS` path selects a UTF-8 JSONL corpus:

```json
{"id":"agreement","raw":"she go to office every day","editedReference":"She goes to the office every day.","language":"en","mustPreserve":["she","office","every day"]}
```

For audio-derived examples, also provide `verbatimReference`. The harness then
reports recognition WER separately. Include engine/model metadata in the corpus
ID or accompanying report notes. Obtain permission before using private recordings.
Keep corpora and reports outside the repository when they contain personal text.

Read candidate/final pairs, including unchanged and rejected outputs. Review
negation, uncertainty, tense, who did what, dates, names, numbers, intentional
repetition, literal filler words, commands, and mixed-language speech. The phrase
checks are regression annotations, not a semantic equivalence classifier. Report
quality and p50/p95 latency per language, level, model, and recording length;
do not promote a model on one aggregate score or synthetic probes alone.

## Supported behavior and limits

- Grammar is a separate opt-in English level. It supports bounded subject–verb
  agreement and article insertion in recognized constructions. It does not
  paraphrase, change tense, or guess between valid but potentially misheard words.
  Ambiguous or unsupported grammar stays as spoken.
- Related grammar edits are applied together. If the candidate contains another
  unsafe edit, the merger retains only the ordinary cleanup edits.
- Local cleanup uses actual model token counts with reserved template/output
  space. Long input can split at sentence boundaries, up to eight chunks and
  64,000 characters, under one overall deadline. It never splits an oversized
  sentence or a Command Mode selection. Such inputs fall back unchanged.
- A stronger model can improve proposals, but the merger still enforces the same
  policy. Validate repeated calls, memory, latency, and semantic errors before
  changing the recommended model.
