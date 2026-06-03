# ============================================================================
#  Alpha Wave — data pipeline
#  Author: built by 赫哥 (Hermes) for 老大 (Elvis)
#  Purpose: 每天美股收盤後，從 Tiingo 抓 K 線、從 FMP 抓基本面，產出 JSON
#           推到 GitHub Pages，前端直接 fetch 顯示
#  Run:     Rscript R/update_data.R
# ============================================================================

suppressPackageStartupMessages({
  library(riingo)
  library(fmpcloudr)
  library(jsonlite)
  library(tidyverse)
  library(lubridate)
  library(dotenv)
})

# ─── 1. 讀 .env 金鑰 ───────────────────────────────────────────────────────
load_dot_env(".env")
TIINGO_TOKEN <- Sys.getenv("TIINGO_TOKEN")
FMP_API_KEY  <- Sys.getenv("FMP_API_KEY")
riingo_set_token(TIINGO_TOKEN)
fmpcloudr::fmpc_set_api_key(FMP_API_KEY)

if (nzchar(TIINGO_TOKEN) == FALSE || nzchar(FMP_API_KEY) == FALSE) {
  stop("❌ API key 沒設定！請編輯 .env 填入 TIINGO_TOKEN / FMP_API_KEY")
}
cat("✅ API keys 載入成功\n")

# ─── 2. 設定七大巨頭 ─────────────────────────────────────────────────────────
MAGNIFICENT_7 <- c("AAPL", "MSFT", "NVDA", "AMZN", "GOOGL", "META", "TSLA")
INDEX_TICKERS <- c(
  "SPY"  = "S&P 500 ETF",
  "QQQ"  = "Nasdaq 100 ETF",
  "DIA"  = "Dow Jones ETF",
  "VIX"  = "Volatility Index"
)
HISTORY_DAYS <- 180    # 抓 6 個月日線
LOOKBACK_DAYS <- 30     # 計算近 30 天漲跌用

cat(sprintf("📊 追蹤清單: %s\n", paste(MAGNIFICENT_7, collapse = ", ")))

# ─── 3. 工具函式 ───────────────────────────────────────────────────────────
to_json_safe <- function(x) {
  # 把 date/tibble 轉成前端友善的純 list
  x <- x %>% mutate(across(where(is.Date), as.character))
  jsonlite::toJSON(x, auto_unbox = TRUE, pretty = FALSE, na = "null", digits = 4)
}

write_json <- function(obj, path) {
  dir.create(dirname(path), showWarnings = FALSE, recursive = TRUE)
  jsonlite::write_json(
    obj, path,
    auto_unbox  = TRUE,
    pretty      = FALSE,
    na          = "null",
    digits      = 4
  )
  cat(sprintf("  💾 %s (%d bytes)\n", path, file.info(path)$size))
}

safe_call <- function(expr, label) {
  tryCatch(
    expr,
    error = function(e) {
      cat(sprintf("  ⚠️  %s 失敗: %s\n", label, conditionMessage(e)))
      NULL
    }
  )
}

# ─── 4. 抓個股 (riingo) ───────────────────────────────────────────────────
fetch_ticker_ohlc <- function(symbol, days = HISTORY_DAYS) {
  cat(sprintf("  → %s (riingo)\n", symbol))
  end_date   <- Sys.Date()
  start_date <- end_date - days(days)

  df <- riingo_prices(
    symbol,
    start_date = start_date,
    end_date   = end_date,
    resample_frequency = "daily"
  ) %>%
    rename(
      date   = date,
      open   = open,
      high   = high,
      low    = low,
      close  = close,
      volume = volume
    ) %>%
    mutate(date = as.character(date)) %>%
    select(date, open, high, low, close, volume)

  df
}

# ─── 5. 抓基本面 (FMP) ────────────────────────────────────────────────────
fetch_fundamentals <- function(symbol) {
  cat(sprintf("  → %s (fmpcloudr profile)\n", symbol))
  prof <- safe_call(fmpcloudr::fmpc_profile(symbol), "profile")
  if (is.null(prof) || nrow(prof) == 0) {
    return(list(
      symbol = symbol, companyName = symbol, sector = "N/A",
      industry = "N/A", marketCap = NA, pe = NA, eps = NA, beta = NA
    ))
  }
  list(
    symbol      = symbol,
    companyName = prof$companyName %||% symbol,
    sector      = prof$sector      %||% "N/A",
    industry    = prof$industry    %||% "N/A",
    marketCap   = prof$mktCap      %||% NA_real_,
    pe          = prof$pe          %||% NA_real_,
    eps         = prof$eps         %||% NA_real_,
    beta        = prof$beta        %||% NA_real_,
    description = prof$description  %||% ""
  )
}

# `%||%` for missing values
`%||%` <- function(a, b) if (is.null(a) || is.na(a) || a == "") b else a

# ─── 6. 抓大盤指數 ────────────────────────────────────────────────────────
fetch_market_overview <- function() {
  cat("  → 大盤指數\n")
  result <- list()
  for (sym in names(INDEX_TICKERS)) {
    df <- safe_call(fetch_ticker_ohlc(sym, days = LOOKBACK_DAYS),
                    paste0("index ", sym))
    if (is.null(df) || nrow(df) == 0) next

    latest   <- df %>% slice_tail(n = 1)
    prev     <- df %>% slice_tail(n = 2) %>% slice(1)
    change   <- latest$close - prev$close
    change_p <- if (prev$close != 0) change / prev$close * 100 else 0

    result[[sym]] <- list(
      name      = INDEX_TICKERS[[sym]],
      last      = round(latest$close, 2),
      prevClose = round(prev$close, 2),
      change    = round(change, 2),
      changePct = round(change_p, 2),
      date      = latest$date
    )
  }
  result
}

# ─── 7. 組裝單一個股的 JSON ───────────────────────────────────────────────
build_ticker_payload <- function(symbol) {
  cat(sprintf("\n[%s] 開始處理\n", symbol))
  ohlc <- fetch_ticker_ohlc(symbol)
  if (is.null(ohlc) || nrow(ohlc) == 0) {
    cat(sprintf("  ❌ %s OHLC 抓不到，略過\n", symbol))
    return(invisible(NULL))
  }

  fund <- fetch_fundamentals(symbol)
  if (is.null(fund)) fund <- list(symbol = symbol, companyName = symbol)

  # 衍生指標
  latest   <- ohlc %>% slice_tail(n = 1)
  prev     <- ohlc %>% slice_tail(n = 2) %>% slice(1)
  change   <- latest$close - prev$close
  change_p <- if (prev$close != 0) change / prev$close * 100 else 0
  high_52w <- max(ohlc$high, na.rm = TRUE)
  low_52w  <- min(ohlc$low,  na.rm = TRUE)

  payload <- list(
    meta = list(
      symbol      = symbol,
      companyName = fund$companyName,
      generatedAt = format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z"),
      historyDays = nrow(ohlc)
    ),
    quote = list(
      date      = latest$date,
      open      = round(latest$open, 4),
      high      = round(latest$high, 4),
      low       = round(latest$low, 4),
      close     = round(latest$close, 4),
      volume    = latest$volume,
      prevClose = round(prev$close, 4),
      change    = round(change, 4),
      changePct = round(change_p, 2)
    ),
    range = list(
      high52w = round(high_52w, 2),
      low52w  = round(low_52w, 2)
    ),
    fundamentals = list(
      sector    = fund$sector,
      industry  = fund$industry,
      marketCap = fund$marketCap,
      pe        = fund$pe,
      eps       = fund$eps,
      beta      = fund$beta
    ),
    ohlc = ohlc %>% mutate(across(everything(), as.character))
  )

  write_json(payload, file.path("data", "tickers", paste0(symbol, ".json")))
}

# ─── 8. 主程式 ────────────────────────────────────────────────────────────
cat("\n══════════════════════════════════════════════════════════\n")
cat("  🌊 Alpha Wave — data pipeline\n")
cat("  開始時間:", format(Sys.time(), "%Y-%m-%d %H:%M:%S"), "\n")
cat("══════════════════════════════════════════════════════════\n\n")

# 8.1 大盤
cat("[1/3] 大盤指數\n")
overview <- fetch_market_overview()
write_json(overview, "data/market_snapshot.json")

# 8.2 七大巨頭
cat("\n[2/3] 個股 OHLC + 基本面\n")
for (sym in MAGNIFICENT_7) {
  build_ticker_payload(sym)
  Sys.sleep(0.3)  # 禮貌性 delay，避免打爆免費 API
}

# 8.3 寫入最後更新時間 + 索引
cat("\n[3/3] 寫入 index 檔\n")
index <- list(
  generatedAt = format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z"),
  tickers     = MAGNIFICENT_7,
  market      = names(INDEX_TICKERS)
)
write_json(index, "data/index.json")

cat("\n══════════════════════════════════════════════════════════\n")
cat("  ✅ 全部完成！\n")
cat("  結束時間:", format(Sys.time(), "%Y-%m-%d %H:%M:%S"), "\n")
cat("══════════════════════════════════════════════════════════\n")
