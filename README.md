# 🌊 Alpha Wave

> **Magnificent 7 stock dashboard** — powered by R data pipeline + GitHub Pages front-end.

A clean, newspaper-style dashboard tracking **Apple · Microsoft · NVIDIA · Amazon · Alphabet · Meta · Tesla** with daily OHLC, fundamentals, and market context. Updated automatically every US market close.

🔗 **Live site**: https://nutcelvischen-jpg.github.io/alpha-wave/

---

## ✨ Features

- 📰 **Newspaper-style layout** — WSJ / 經濟學人 inspired typography
- 📈 **6-month interactive K-line charts** (Chart.js + canvas)
- 💼 **Fundamental panel** — PE, EPS, market cap, sector, beta
- 🌡️ **Market context** — S&P 500, NASDAQ, Dow, VIX
- 🕐 **Auto-updated** by macOS `launchd` after US market close (TW 05:00)
- 🔐 **Zero API key leakage** — keys live only on the data-collector machine

## 🏗️ Architecture

```
Local Mac (R)                 GitHub Pages (static)
┌─────────────────┐           ┌──────────────────────┐
│ R/update_data.R │  ──push─→ │ index.html           │
│ • riingo (OHLC) │           │ • Tailwind CSS       │
│ • fmpcloudr     │           │ • Chart.js (K-line)  │
│ • cron @ 05:00  │           │ • Vanilla JS         │
└─────────────────┘           └──────────────────────┘
       ↑                                ↑
   API keys here                  No secrets here
```

## 🚀 Quick start (for re-deployment on another machine)

```bash
# 1. Clone
git clone https://github.com/nutcelvischen-jpg/alpha-wave.git
cd alpha-wave

# 2. Install R packages
Rscript -e 'install.packages(c("riingo", "fmpcloudr", "jsonlite", "tidyverse", "dotenv"))'

# 3. Fill in your API keys
cp .env.example .env
$EDITOR .env

# 4. Run the data pipeline
Rscript R/update_data.R

# 5. Push to GitHub
git add data/
git commit -m "data: update market snapshot"
git push
```

## 📦 Data sources

| Source | Used for | Free tier |
|---|---|---|
| [Tiingo](https://www.tiingo.com) | Daily OHLC, IEX real-time, fundamentals | 50K symbols/month |
| [Financial Modeling Prep](https://site.financialmodelingprep.com) | Company profile, PE, EPS, sector | 250 req/day |

## 📁 Project layout

```
alpha-wave/
├── R/
│   └── update_data.R        # main data pipeline
├── data/
│   ├── market_snapshot.json # SPX/NDX/DJI/VIX snapshot
│   ├── tickers/             # one JSON per ticker
│   │   ├── AAPL.json
│   │   ├── MSFT.json
│   │   └── ...
│   └── last_update.txt
├── index.html               # the dashboard
├── .env                     # local secrets (gitignored)
├── .env.example             # template
└── README.md
```

## 📜 License

MIT — do whatever you want, just don't blame me when your portfolio tanks.

## ⚠️ Disclaimer

This is a personal learning project. **Not financial advice.** Past performance ≠ future results. If you lose money trading Magnificent 7 calls, that's between you and your broker.
