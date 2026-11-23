#!/bin/zsh
# #19 量測矩陣：模型 × 定稿所需片段數，依序跑（同時跑會互搶 ANE/GPU，時序就不像真的了）。
#
#   BENCH_DIR=<資料夾> WHISPER_MODELS=<whisperkit-coreml 模型資料夾的上層> ./run_matrix.sh
#
# 可選：MODELS（模型資料夾名稱，空白分隔）、REQS（定稿所需片段數，空白分隔）、
#       MANIFEST（語料清單，預設 manifest.json）、OUTSUFFIX（輸出資料夾名稱後綴）。
# 先 `swift build --build-tests`；結果在 $BENCH_DIR/out/<模型>-r<片段數><後綴>/。
# 重播給正式引擎：SAYMEND_BENCH19_REPLAY=<輸出資料夾,…> swift test --skip-build --filter StreamBoundaryReplay
# 再用 compare_replay.py 比較重播前後。
: ${BENCH_DIR:?} ${WHISPER_MODELS:?}
REPO=${0:A:h}/../../..
cd $REPO
for model in ${=MODELS:-openai_whisper-tiny openai_whisper-small openai_whisper-large-v3_turbo}; do
  for req in ${=REQS:-1 2}; do
    out=$BENCH_DIR/out/$model-r$req${OUTSUFFIX:-}
    echo "== $(date +%T) $model required=$req"
    SAYMEND_BENCH19_MODEL=$WHISPER_MODELS/$model SAYMEND_BENCH19_MANIFEST=$BENCH_DIR/${MANIFEST:-manifest.json} \
    SAYMEND_BENCH19_OUT=$out SAYMEND_BENCH19_REQUIRED=$req \
      swift test --skip-build --filter StreamBoundaryBench 2>&1 | grep -E "bench19|passed after|failed|error:"
  done
done
echo "== $(date +%T) done"
