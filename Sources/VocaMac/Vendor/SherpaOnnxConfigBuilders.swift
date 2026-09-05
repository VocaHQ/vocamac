// SherpaOnnxConfigBuilders.swift
// VocaMac (vendored)
//
// Trimmed copy of swift-api-examples/SherpaOnnx.swift from the sherpa-onnx
// project (https://github.com/k2-fsa/sherpa-onnx), release
// v1.13.7, Copyright (c) 2023 Xiaomi
// Corporation, Apache License 2.0.
//
// The upstream file lives in the package's example target and declares
// everything internal, so none of it is importable — hence this copy. Only
// the offline-recognizer config builders are kept: SherpaService drives
// recognizer creation and decoding through the C API directly, so a bad
// model throws instead of hitting the upstream wrapper's fatalError.
//
// When upgrading sherpa-onnx, re-sync these builders from the matching
// revision's swift-api-examples/SherpaOnnx.swift.

import Foundation  // For NSString
import SherpaOnnxC

func toCPointer(_ s: String) -> UnsafePointer<Int8>! {
  let cs = (s as NSString).utf8String
  return UnsafePointer<Int8>(cs)
}

func sherpaOnnxFeatureConfig(
  sampleRate: Int = 16000,
  featureDim: Int = 80
) -> SherpaOnnxFeatureConfig {
  return SherpaOnnxFeatureConfig(
    sample_rate: Int32(sampleRate),
    feature_dim: Int32(featureDim))
}

func sherpaOnnxOnlineCtcFstDecoderConfig(
  graph: String = "",
  maxActive: Int = 3000
) -> SherpaOnnxOnlineCtcFstDecoderConfig {
  return SherpaOnnxOnlineCtcFstDecoderConfig(
    graph: toCPointer(graph),
    max_active: Int32(maxActive))
}

func sherpaOnnxHomophoneReplacerConfig(
  dictDir: String = "",
  lexicon: String = "",
  ruleFsts: String = ""
) -> SherpaOnnxHomophoneReplacerConfig {
  return SherpaOnnxHomophoneReplacerConfig(
    dict_dir: toCPointer(dictDir),
    lexicon: toCPointer(lexicon),
    rule_fsts: toCPointer(ruleFsts))
}

func sherpaOnnxOfflineTransducerModelConfig(
  encoder: String = "",
  decoder: String = "",
  joiner: String = ""
) -> SherpaOnnxOfflineTransducerModelConfig {
  return SherpaOnnxOfflineTransducerModelConfig(
    encoder: toCPointer(encoder),
    decoder: toCPointer(decoder),
    joiner: toCPointer(joiner)
  )
}

func sherpaOnnxOfflineParaformerModelConfig(
  model: String = ""
) -> SherpaOnnxOfflineParaformerModelConfig {
  return SherpaOnnxOfflineParaformerModelConfig(
    model: toCPointer(model)
  )
}

func sherpaOnnxOfflineZipformerCtcModelConfig(
  model: String = ""
) -> SherpaOnnxOfflineZipformerCtcModelConfig {
  return SherpaOnnxOfflineZipformerCtcModelConfig(
    model: toCPointer(model)
  )
}

func sherpaOnnxOfflineWenetCtcModelConfig(
  model: String = ""
) -> SherpaOnnxOfflineWenetCtcModelConfig {
  return SherpaOnnxOfflineWenetCtcModelConfig(
    model: toCPointer(model)
  )
}

func sherpaOnnxOfflineOmnilingualAsrCtcModelConfig(
  model: String = ""
) -> SherpaOnnxOfflineOmnilingualAsrCtcModelConfig {
  return SherpaOnnxOfflineOmnilingualAsrCtcModelConfig(
    model: toCPointer(model)
  )
}

func sherpaOnnxOfflineMedAsrCtcModelConfig(
  model: String = ""
) -> SherpaOnnxOfflineMedAsrCtcModelConfig {
  return SherpaOnnxOfflineMedAsrCtcModelConfig(
    model: toCPointer(model)
  )
}

func sherpaOnnxOfflineFireRedAsrCtcModelConfig(
  model: String = ""
) -> SherpaOnnxOfflineFireRedAsrCtcModelConfig {
  return SherpaOnnxOfflineFireRedAsrCtcModelConfig(
    model: toCPointer(model)
  )
}

func sherpaOnnxOfflineNemoEncDecCtcModelConfig(
  model: String = ""
) -> SherpaOnnxOfflineNemoEncDecCtcModelConfig {
  return SherpaOnnxOfflineNemoEncDecCtcModelConfig(
    model: toCPointer(model)
  )
}

func sherpaOnnxOfflineDolphinModelConfig(
  model: String = ""
) -> SherpaOnnxOfflineDolphinModelConfig {
  return SherpaOnnxOfflineDolphinModelConfig(
    model: toCPointer(model)
  )
}

func sherpaOnnxOfflineWhisperModelConfig(
  encoder: String = "",
  decoder: String = "",
  language: String = "",
  task: String = "transcribe",
  tailPaddings: Int = -1,
  enableTokenTimestamps: Bool = false,
  enableSegmentTimestamps: Bool = false
) -> SherpaOnnxOfflineWhisperModelConfig {
  return SherpaOnnxOfflineWhisperModelConfig(
    encoder: toCPointer(encoder),
    decoder: toCPointer(decoder),
    language: toCPointer(language),
    task: toCPointer(task),
    tail_paddings: Int32(tailPaddings),
    enable_token_timestamps: enableTokenTimestamps ? 1 : 0,
    enable_segment_timestamps: enableSegmentTimestamps ? 1 : 0
  )
}

func sherpaOnnxOfflineCanaryModelConfig(
  encoder: String = "",
  decoder: String = "",
  srcLang: String = "en",
  tgtLang: String = "en",
  usePnc: Bool = true
) -> SherpaOnnxOfflineCanaryModelConfig {
  return SherpaOnnxOfflineCanaryModelConfig(
    encoder: toCPointer(encoder),
    decoder: toCPointer(decoder),
    src_lang: toCPointer(srcLang),
    tgt_lang: toCPointer(tgtLang),
    use_pnc: usePnc ? 1 : 0
  )
}

func sherpaOnnxOfflineCohereTranscribeModelConfig(
  encoder: String = "",
  decoder: String = "",
  language: String = "",
  usePunct: Bool = true,
  useInverseTextNormalization: Bool = true
) -> SherpaOnnxOfflineCohereTranscribeModelConfig {
  return SherpaOnnxOfflineCohereTranscribeModelConfig(
    encoder: toCPointer(encoder),
    decoder: toCPointer(decoder),
    language: toCPointer(language),
    use_punct: usePunct ? 1 : 0,
    use_itn: useInverseTextNormalization ? 1 : 0
  )
}

func sherpaOnnxOfflineFireRedAsrModelConfig(
  encoder: String = "",
  decoder: String = ""
) -> SherpaOnnxOfflineFireRedAsrModelConfig {
  return SherpaOnnxOfflineFireRedAsrModelConfig(
    encoder: toCPointer(encoder),
    decoder: toCPointer(decoder)
  )
}

// there are two versions of Moonshine
// For v1, you need four models: preprocessor, encoder, uncachedDecoder, cachedDecoder
// For v2, you need two models: encoder, mergedDecoder
func sherpaOnnxOfflineMoonshineModelConfig(
  preprocessor: String = "",
  encoder: String = "",
  uncachedDecoder: String = "",
  cachedDecoder: String = "",
  mergedDecoder: String = ""
) -> SherpaOnnxOfflineMoonshineModelConfig {
  return SherpaOnnxOfflineMoonshineModelConfig(
    preprocessor: toCPointer(preprocessor),
    encoder: toCPointer(encoder),
    uncached_decoder: toCPointer(uncachedDecoder),
    cached_decoder: toCPointer(cachedDecoder),
    merged_decoder: toCPointer(mergedDecoder)
  )
}

func sherpaOnnxOfflineQwen3ASRModelConfig(
  convFrontend: String = "",
  encoder: String = "",
  decoder: String = "",
  tokenizer: String = "",
  maxTotalLen: Int = 512,
  maxNewTokens: Int = 128,
  temperature: Float = 1e-6,
  topP: Float = 0.8,
  seed: Int = 42,
  hotwords: String = ""
) -> SherpaOnnxOfflineQwen3ASRModelConfig {
  return SherpaOnnxOfflineQwen3ASRModelConfig(
    conv_frontend: toCPointer(convFrontend),
    encoder: toCPointer(encoder),
    decoder: toCPointer(decoder),
    tokenizer: toCPointer(tokenizer),
    max_total_len: Int32(maxTotalLen),
    max_new_tokens: Int32(maxNewTokens),
    temperature: temperature,
    top_p: topP,
    seed: Int32(seed),
    hotwords: toCPointer(hotwords)
  )
}

func sherpaOnnxOfflineTdnnModelConfig(
  model: String = ""
) -> SherpaOnnxOfflineTdnnModelConfig {
  return SherpaOnnxOfflineTdnnModelConfig(
    model: toCPointer(model)
  )
}

func sherpaOnnxOfflineSenseVoiceModelConfig(
  model: String = "",
  language: String = "",
  useInverseTextNormalization: Bool = false
) -> SherpaOnnxOfflineSenseVoiceModelConfig {
  return SherpaOnnxOfflineSenseVoiceModelConfig(
    model: toCPointer(model),
    language: toCPointer(language),
    use_itn: useInverseTextNormalization ? 1 : 0
  )
}

func sherpaOnnxOfflineLMConfig(
  model: String = "",
  scale: Float = 1.0
) -> SherpaOnnxOfflineLMConfig {
  return SherpaOnnxOfflineLMConfig(
    model: toCPointer(model),
    scale: scale
  )
}

func sherpaOnnxOfflineFunASRNanoModelConfig(
  encoderAdaptor: String = "",
  llm: String = "",
  embedding: String = "",
  tokenizer: String = "",
  systemPrompt: String = "You are a helpful assistant.",
  userPrompt: String = "语音转写：",
  maxNewTokens: Int = 512,
  temperature: Float = 1e-6,
  topP: Float = 0.8,
  seed: Int = 42,
  language: String = "",
  itn: Bool = true,
  hotwords: String = ""
) -> SherpaOnnxOfflineFunASRNanoModelConfig {
  return SherpaOnnxOfflineFunASRNanoModelConfig(
    encoder_adaptor: toCPointer(encoderAdaptor),
    llm: toCPointer(llm),
    embedding: toCPointer(embedding),
    tokenizer: toCPointer(tokenizer),
    system_prompt: toCPointer(systemPrompt),
    user_prompt: toCPointer(userPrompt),
    max_new_tokens: Int32(maxNewTokens),
    temperature: temperature,
    top_p: topP,
    seed: Int32(seed),
    language: toCPointer(language),
    itn: itn ? 1 : 0,
    hotwords: toCPointer(hotwords)
  )
}

func sherpaOnnxOfflineModelConfig(
  tokens: String,
  transducer: SherpaOnnxOfflineTransducerModelConfig = sherpaOnnxOfflineTransducerModelConfig(),
  paraformer: SherpaOnnxOfflineParaformerModelConfig = sherpaOnnxOfflineParaformerModelConfig(),
  nemoCtc: SherpaOnnxOfflineNemoEncDecCtcModelConfig = sherpaOnnxOfflineNemoEncDecCtcModelConfig(),
  whisper: SherpaOnnxOfflineWhisperModelConfig = sherpaOnnxOfflineWhisperModelConfig(),
  tdnn: SherpaOnnxOfflineTdnnModelConfig = sherpaOnnxOfflineTdnnModelConfig(),
  numThreads: Int = 1,
  provider: String = "cpu",
  debug: Int = 0,
  modelType: String = "",
  modelingUnit: String = "cjkchar",
  bpeVocab: String = "",
  teleSpeechCtc: String = "",
  senseVoice: SherpaOnnxOfflineSenseVoiceModelConfig = sherpaOnnxOfflineSenseVoiceModelConfig(),
  moonshine: SherpaOnnxOfflineMoonshineModelConfig = sherpaOnnxOfflineMoonshineModelConfig(),
  fireRedAsr: SherpaOnnxOfflineFireRedAsrModelConfig = sherpaOnnxOfflineFireRedAsrModelConfig(),
  dolphin: SherpaOnnxOfflineDolphinModelConfig = sherpaOnnxOfflineDolphinModelConfig(),
  zipformerCtc: SherpaOnnxOfflineZipformerCtcModelConfig =
    sherpaOnnxOfflineZipformerCtcModelConfig(),
  canary: SherpaOnnxOfflineCanaryModelConfig = sherpaOnnxOfflineCanaryModelConfig(),
  wenetCtc: SherpaOnnxOfflineWenetCtcModelConfig =
    sherpaOnnxOfflineWenetCtcModelConfig(),
  omnilingual: SherpaOnnxOfflineOmnilingualAsrCtcModelConfig =
    sherpaOnnxOfflineOmnilingualAsrCtcModelConfig(),
  medasr: SherpaOnnxOfflineMedAsrCtcModelConfig =
    sherpaOnnxOfflineMedAsrCtcModelConfig(),
  funasrNano: SherpaOnnxOfflineFunASRNanoModelConfig =
    sherpaOnnxOfflineFunASRNanoModelConfig(),
  fireRedAsrCtc: SherpaOnnxOfflineFireRedAsrCtcModelConfig =
    sherpaOnnxOfflineFireRedAsrCtcModelConfig(),
  qwen3Asr: SherpaOnnxOfflineQwen3ASRModelConfig =
    sherpaOnnxOfflineQwen3ASRModelConfig(),
  cohereTranscribe: SherpaOnnxOfflineCohereTranscribeModelConfig =
    sherpaOnnxOfflineCohereTranscribeModelConfig()
) -> SherpaOnnxOfflineModelConfig {
  return SherpaOnnxOfflineModelConfig(
    transducer: transducer,
    paraformer: paraformer,
    nemo_ctc: nemoCtc,
    whisper: whisper,
    tdnn: tdnn,
    tokens: toCPointer(tokens),
    num_threads: Int32(numThreads),
    debug: Int32(debug),
    provider: toCPointer(provider),
    model_type: toCPointer(modelType),
    modeling_unit: toCPointer(modelingUnit),
    bpe_vocab: toCPointer(bpeVocab),
    telespeech_ctc: toCPointer(teleSpeechCtc),
    sense_voice: senseVoice,
    moonshine: moonshine,
    fire_red_asr: fireRedAsr,
    dolphin: dolphin,
    zipformer_ctc: zipformerCtc,
    canary: canary,
    wenet_ctc: wenetCtc,
    omnilingual: omnilingual,
    medasr: medasr,
    funasr_nano: funasrNano,
    fire_red_asr_ctc: fireRedAsrCtc,
    qwen3_asr: qwen3Asr,
    cohere_transcribe: cohereTranscribe
  )
}

func sherpaOnnxOfflineRecognizerConfig(
  featConfig: SherpaOnnxFeatureConfig,
  modelConfig: SherpaOnnxOfflineModelConfig,
  lmConfig: SherpaOnnxOfflineLMConfig = sherpaOnnxOfflineLMConfig(),
  decodingMethod: String = "greedy_search",
  maxActivePaths: Int = 4,
  hotwordsFile: String = "",
  hotwordsScore: Float = 1.5,
  ruleFsts: String = "",
  ruleFars: String = "",
  blankPenalty: Float = 0.0,
  hr: SherpaOnnxHomophoneReplacerConfig = sherpaOnnxHomophoneReplacerConfig()
) -> SherpaOnnxOfflineRecognizerConfig {
  return SherpaOnnxOfflineRecognizerConfig(
    feat_config: featConfig,
    model_config: modelConfig,
    lm_config: lmConfig,
    decoding_method: toCPointer(decodingMethod),
    max_active_paths: Int32(maxActivePaths),
    hotwords_file: toCPointer(hotwordsFile),
    hotwords_score: hotwordsScore,
    rule_fsts: toCPointer(ruleFsts),
    rule_fars: toCPointer(ruleFars),
    blank_penalty: blankPenalty,
    hr: hr
  )
}
