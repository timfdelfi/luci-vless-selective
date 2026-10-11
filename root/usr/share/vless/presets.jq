# presets.jq — готовые наборы сервисов для режима «Только выбранные сервисы».
# Подключается из build.jq (include "presets") и из /usr/bin/vless (selective-lists).
# Ключи должны совпадать с PRESET_KEYS в /usr/bin/vless и списком в интерфейсе.

def presets: {
  telegram: {
    domains: ["telegram.org", "t.me", "telegram.me", "telegram-cdn.org", "cdn-telegram.org",
              "tdesktop.com", "telesco.pe", "telegra.ph", "tg.dev"],
    # Telegram ходит по IP-адресам напрямую (звонки, MTProto, загрузка медиа),
    # одних доменов мало. 91.108.4–20 — основные DC, 91.108.56 — DC5,
    # 91.105.192 и 149.154.160 — запасные диапазоны, 185.76.151 — статика,
    # 95.161.64 — отдельный диапазон MTProxy/загрузки файлов.
    cidrs: ["91.108.4.0/22", "91.108.8.0/22", "91.108.12.0/22", "91.108.16.0/22", "91.108.20.0/22",
            "91.108.56.0/22", "91.105.192.0/23", "149.154.160.0/20", "185.76.151.0/24",
            "95.161.64.0/20"]
  },
  youtube: {
    domains: ["youtube.com", "youtu.be", "youtube-nocookie.com", "youtubekids.com",
              "googlevideo.com", "ytimg.com", "ggpht.com", "youtubei.googleapis.com",
              "jnn-pa.googleapis.com"]
  },
  discord: {
    domains: ["discord.com", "discord.gg", "discordapp.com", "discordapp.net", "discord.media",
              "discordcdn.com", "discord.gift", "discord.new", "discordstatus.com"],
    # голосовой сервер Discord (Google Cloud), наблюдался в UDP-потоке; в DNS не попадает
    cidrs: ["35.217.0.0/16"]
  },
  meta: {
    domains: ["facebook.com", "fb.com", "fb.me", "fbcdn.net", "fbsbx.com", "facebook.net", "messenger.com",
              "instagram.com", "cdninstagram.com", "instagr.am", "whatsapp.com", "whatsapp.net", "wa.me",
              "threads.net", "meta.com"]
  },
  x: {
    domains: ["twitter.com", "x.com", "t.co", "twimg.com", "twttr.com"]
  },
  ai: {
    domains: ["openai.com", "chatgpt.com", "oaistatic.com", "oaiusercontent.com", "anthropic.com",
              "claude.ai", "claude.com", "gemini.google.com", "perplexity.ai", "grok.com", "x.ai",
              "copilot.microsoft.com"]
  },
  adult: {
    domains: ["pornhub.com", "phncdn.com", "xvideos.com", "xvideos-cdn.com", "xnxx.com", "xhamster.com",
              "xhcdn.com", "redtube.com", "youporn.com", "spankbang.com", "eporner.com", "onlyfans.com",
              "chaturbate.com", "stripchat.com"]
  }
};
