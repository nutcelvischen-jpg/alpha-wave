#!/bin/bash
# ============================================================================
#  Alpha Wave — cron wrapper
#  給 launchd 每天台灣時間 05:00 (美東 16:00, 收盤後 30 分鐘) 呼叫
#  流程: 跑 R/update_data.R → 比對有變化就 git commit + git push
#  Log 寫到 /Users/elvis/projects/alpha-wave/logs/cron.log
# ============================================================================
set -e

PROJECT_DIR="/Users/elvis/projects/alpha-wave"
R_SCRIPT="/usr/local/bin/Rscript"
LOG_DIR="${PROJECT_DIR}/logs"
LOG_FILE="${LOG_DIR}/cron.log"

# 建 log 目錄
mkdir -p "$LOG_DIR"

# 開始 log
{
  echo ""
  echo "════════════════════════════════════════════════════════════"
  echo "  🌊 Alpha Wave cron run"
  echo "  Time: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "════════════════════════════════════════════════════════════"
} >> "$LOG_FILE"

# 切到專案目錄
cd "$PROJECT_DIR" || { echo "❌ 找不到 $PROJECT_DIR" >> "$LOG_FILE"; exit 1; }

# 1. 跑 R 抓資料
echo "" >> "$LOG_FILE"
echo "▶ [1/3] 跑 R/update_data.R" >> "$LOG_FILE"
if "$R_SCRIPT" R/update_data.R >> "$LOG_FILE" 2>&1; then
  echo "  ✅ R script 成功" >> "$LOG_FILE"
else
  echo "  ❌ R script 失敗（看上面 log）" >> "$LOG_FILE"
  exit 2
fi

# 2. 看 data/ 有沒有變更
echo "" >> "$LOG_FILE"
echo "▶ [2/3] 檢查 git 變更" >> "$LOG_FILE"
git add data/ 2>>"$LOG_FILE"

if git diff --cached --quiet; then
  echo "  ℹ️  沒有資料變更，不 push" >> "$LOG_FILE"
  echo "" >> "$LOG_FILE"
  echo "🏁 cron run 完成（無變更）" >> "$LOG_FILE"
  exit 0
fi

# 3. commit + push
echo "  📝 有變更，commit + push" >> "$LOG_FILE"
COMMIT_MSG="data: cron update $(date '+%Y-%m-%d %H:%M %Z')"
git commit -m "$COMMIT_MSG" >> "$LOG_FILE" 2>&1

if git push origin main >> "$LOG_FILE" 2>&1; then
  echo "  ✅ push 成功" >> "$LOG_FILE"
  # 顯示 pushed 內容
  git log --oneline -1 >> "$LOG_FILE"
else
  echo "  ❌ push 失敗（看上面 log，可能是 token 過期或 429）" >> "$LOG_FILE"
  exit 3
fi

echo "" >> "$LOG_FILE"
echo "🏁 cron run 完成" >> "$LOG_FILE"
