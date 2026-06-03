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
# dotenv 會把 .env 內容讀進 Sys.getenv()，這樣底層 API (riingo/fmpcloudr) 也能直接吃
load_dot_env(".env")
TIINGO_TOKEN <- Sys.getenv("TIINGO_TOKEN")
FMP_API_KEY  <- Sys.getenv("FMP_API_KEY")

# riingo 內部直接吃 Sys.getenv("RIINGO_TOKEN")
# fmpcloudr 要顯式呼叫 fmpc_set_token()（新版不直接吃 Sys.getenv）
# 把我們從 .env 讀到的 key 也映射到 API 套件期待的環境變數名
Sys.setenv(RIINGO_TOKEN = TIINGO_TOKEN)
fmpcloudr::fmpc_set_token(FMP_API_KEY)

if (!nzchar(TIINGO_TOKEN) || !nzchar(FMP_API_KEY)) {
  stop("❌ API key 沒設定！請編輯 .env 填入 TIINGO_TOKEN / FMP_API_KEY")
}
cat("✅ API keys 載入成功 (TIINGO=", nchar(TIINGO_TOKEN), "字元, FMP=", nchar(FMP_API_KEY), "字元)\n", sep = "")

# ─── 2. 設定七大巨頭 ─────────────────────────────────────────────────────────
MAGNIFICENT_7 <- c("AAPL", "MSFT", "NVDA", "AMZN", "GOOGL", "META", "TSLA")
# Tiingo 不支援 ^VIX 這種 Yahoo-style，用 VXX (VIX 期貨 ETF) 替代
INDEX_TICKERS <- c(
  "SPY"  = "S&P 500 ETF",
  "QQQ"  = "Nasdaq 100 ETF",
  "DIA"  = "Dow Jones ETF",
  "VXX"  = "VIX Futures (proxy)"
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
# 額度保護：如果遇到 429 立刻放棄整輪，不浪費剩餘 hourly quota
fetch_ticker_ohlc <- function(symbol, days = HISTORY_DAYS, max_retry = 2) {
  cat(sprintf("  → %s (riingo)\n", symbol))
  end_date   <- Sys.Date()
  start_date <- end_date - days(days)

  for (attempt in seq_len(max_retry)) {
    res <- tryCatch(
      riingo_prices(
        symbol,
        start_date = start_date,
        end_date   = end_date,
        resample_frequency = "daily"
      ),
      error = function(e) e
    )
    if (!inherits(res, "error")) {
      return(
        res %>%
          rename(date = date) %>%
          mutate(date = as.character(date)) %>%
          select(date, open, high, low, close, volume)
      )
    }
    msg <- conditionMessage(res)
    # 429 立刻跳過，不重試 — riingo 內部 retry 完會丟這個訊息
    if (grepl("429|allocation|run over|all tickers failed", msg, ignore.case = TRUE)) {
      cat(sprintf("    🛑 額度爆了 (riingo): %s\n", msg))
      stop("RATE_LIMITED_429")
    }
    cat(sprintf("    ⚠️  attempt %d 失敗: %s\n", attempt, msg))
    if (attempt < max_retry) Sys.sleep(2 ^ attempt)
  }
  NULL
}
# ─── 5. 抓基本面 (FMP) ────────────────────────────────────────────────────
# 注意：fmpcloudr 0.1.7 內建的 fmpc_security_profile() 在 FMP 2025/8/31 改版後
# 已停用 (legacy endpoint)，所以這裡直接 call FMP 新的 stable v3 endpoint。
# 合併兩個 endpoint 拿齊 sector/industry + marketCap/yearHigh/yearLow。
fetch_fundamentals <- function(symbol) {
  cat(sprintf("  → %s (FMP /stable/profile + /stable/quote)\n", symbol))
  base <- "https://financialmodelingprep.com/stable"
  prof_url <- sprintf("%s/profile?symbol=%s&apikey=%s", base, symbol, FMP_API_KEY)
  quot_url <- sprintf("%s/quote?symbol=%s&apikey=%s",   base, symbol, FMP_API_KEY)

  prof <- safe_call(jsonlite::fromJSON(prof_url, simplifyVector = FALSE), "FMP profile")
  quot <- safe_call(jsonlite::fromJSON(quot_url, simplifyVector = FALSE), "FMP quote")

  p <- if (length(prof) > 0) prof[[1]] else list()
  q <- if (length(quot) > 0) quot[[1]] else list()

  list(
    symbol      = symbol,
    companyName = p$companyName %||% q$name %||% symbol,
    sector      = p$sector      %||% "N/A",
    industry    = p$industry    %||% "N/A",
    marketCap   = as.numeric(q$marketCap) %||% as.numeric(p$mktCap) %||% NA_real_,
    pe          = as.numeric(q$pe)         %||% as.numeric(p$pe)     %||% NA_real_,
    eps         = as.numeric(p$eps)                                    %||% NA_real_,
    beta        = as.numeric(p$beta)                                  %||% NA_real_,
    yearHigh    = as.numeric(q$yearHigh)                              %||% NA_real_,
    yearLow     = as.numeric(q$yearLow)                               %||% NA_real_,
    priceAvg50  = as.numeric(q$priceAvg50)                            %||% NA_real_,
    priceAvg200 = as.numeric(q$priceAvg200)                           %||% NA_real_,
    exchange    = q$exchange %||% "N/A",
    description = p$description %||% ""
  )
}

# `%||%` for missing values — 用 vapply + 簡化版避免 length>1 的 NA 問題
`%||%` <- function(a, b) {
  if (is.null(a)) return(b)
  if (length(a) == 0) return(b)
  if (is.atomic(a) && length(a) == 1 && is.na(a)) return(b)
  if (is.character(a) && a == "") return(b)
  a
}

# ─── 6. 抓大盤指數 ────────────────────────────────────────────────────────
fetch_market_overview <- function() {
  cat("  → 大盤指數\n")
  result <- list()
  for (sym in names(INDEX_TICKERS)) {
    cat(sprintf("    · %s\n", sym))
    df <- tryCatch(
      fetch_ticker_ohlc(sym, days = LOOKBACK_DAYS),
      error = function(e) {
        cat(sprintf("      ⚠️  %s\n", e$message))
        if (grepl("RATE_LIMITED_429", e$message)) stop(e)
        NULL
      }
    )
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
  cat(sprintf("  📊 成功 %d / %d 個指數\n", length(result), length(INDEX_TICKERS)))
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
      sector      = fund$sector,
      industry    = fund$industry,
      exchange    = fund$exchange,
      marketCap   = fund$marketCap,
      pe          = fund$pe,
      eps         = fund$eps,
      beta        = fund$beta,
      yearHigh    = fund$yearHigh,
      yearLow     = fund$yearLow,
      priceAvg50  = fund$priceAvg50,
      priceAvg200 = fund$priceAvg200
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
overview <- tryCatch(
  fetch_market_overview(),
  error = function(e) {
    if (grepl("RATE_LIMITED_429", e$message)) {
      cat("\n🛑 偵測到 Tiingo 額度限制 (429)，中止整輪抓取，明日 cron 再跑\n")
      quit(status = 0)  # 正常 exit，不算失敗
    }
    NULL
  }
)
if (is.null(overview) || length(overview) == 0) {
  cat("⚠️  大盤指數抓不到，明天 cron 再試\n")
} else {
  write_json(overview, "data/market_snapshot.json")
}

# 8.2 七大巨頭
cat("\n[2/3] 個股 OHLC + 基本面\n")
for (sym in MAGNIFICENT_7) {
  result <- tryCatch(
    build_ticker_payload(sym),
    error = function(e) {
      if (grepl("RATE_LIMITED_429", e$message)) {
        cat("  🛑 額度爆了，明日 cron 再跑\n")
        return("STOP")
      }
      NULL
    }
  )
  if (identical(result, "STOP")) break
  Sys.sleep(0.8)  # 禮貌性 delay，避免打爆免費 API (Tiingo 500 req/hr)
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
