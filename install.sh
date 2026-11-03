#!/bin/sh
# Установка VPN (luci-vless-selective) на роутер OpenWrt.
# Запускать на роутере:  sh install.sh
cd "$(dirname "$0")" || exit 1

say()  { printf '\n\033[1;35m▶ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m! %s\033[0m\n' "$*"; }

# sha256_check ФАЙЛ ОЖИДАЕМЫЙ_ХЭШ — 0, если хэш файла совпал.
sha256_check() {
	local have
	have="$(sha256sum "$1" 2>/dev/null | awk '{print $1}')"
	[ -n "$have" ] && [ "$have" = "$2" ]
}

# Если install.sh запущен через curl ... | sh без локального репозитория:
if [ ! -d "root" ] || [ ! -d "htdocs" ]; then
	say "Загрузка luci-vless-selective..."
	TMP_DIR="/tmp/vless-install-$$"
	rm -rf "$TMP_DIR" && mkdir -p "$TMP_DIR"
	# Версию можно закрепить: VLESS_VERSION=1.3.8 sh install.sh (тег v1.3.8)
	if [ -n "$VLESS_VERSION" ]; then
		DL_BASE="https://github.com/timfdelfi/luci-vless-selective/releases/download/v${VLESS_VERSION%%-*}"
	else
		DL_BASE="https://github.com/timfdelfi/luci-vless-selective/releases/latest/download"
	fi
	if ! curl -fsSL -m 60 "$DL_BASE/vless-vpn.tar.gz" -o "$TMP_DIR/vless-vpn.tar.gz" 2>/dev/null \
		|| ! curl -fsSL -m 30 "$DL_BASE/SHA256SUMS" -o "$TMP_DIR/SHA256SUMS" 2>/dev/null; then
		echo "Не удалось скачать архив luci-vless-selective или его контрольные суммы."
		rm -rf "$TMP_DIR"
		exit 1
	fi
	want="$(awk '$2=="*vless-vpn.tar.gz" || $2=="vless-vpn.tar.gz" {print $1}' "$TMP_DIR/SHA256SUMS")"
	if [ -z "$want" ] || ! sha256_check "$TMP_DIR/vless-vpn.tar.gz" "$want"; then
		echo "Контрольная сумма архива не совпала — установка остановлена."
		rm -rf "$TMP_DIR"
		exit 1
	fi
	tar -xzf "$TMP_DIR/vless-vpn.tar.gz" -C "$TMP_DIR" || {
		echo "Не удалось распаковать архив."
		rm -rf "$TMP_DIR"
		exit 1
	}
	cd "$TMP_DIR/vless-vpn" 2>/dev/null || cd "$TMP_DIR" || exit 1
	sh install.sh "$@"
	rc=$?
	rm -rf "$TMP_DIR"
	exit $rc
fi

# Запущен ли наш экземпляр sing-box (а не чужой, например Podkop).
is_running_vless() {
	[ -f /var/run/vless.pid ] && kill -0 "$(cat /var/run/vless.pid 2>/dev/null)" 2>/dev/null
}

fetch_singbox() {
	say "Загрузка официального sing-box с GitHub Releases"
	local a o archs tag ver found="" want name api_url w c url bin_dir="/usr/bin"
	# Архив лежит на диске, а не в потоке (нужна проверка суммы): при нехватке RAM в /tmp берём /overlay.
	w="/tmp/sb-install-$$"
	[ "$(df -k /tmp 2>/dev/null | awk 'NR==2{print $4}')" -lt 45000 ] 2>/dev/null && [ -w /overlay ] && w="/overlay/.sb-install-$$"
	a="$(. /etc/openwrt_release 2>/dev/null; echo "$DISTRIB_ARCH")"
	[ -n "$a" ] || a="$(uname -m 2>/dev/null)"
	o="$(opkg print-architecture 2>/dev/null | awk '{print $2}' | grep -v '^all$' | tr '\n' ' ' 2>/dev/null)"
	case "$a $o" in
		*x86_64*|*amd64*)
			archs="linux-amd64" ;;
		*i386*|*i686*|*x86*)
			archs="linux-386" ;;
		*aarch64*|*arm64*)
			archs="linux-arm64" ;;
		*arm_cortex*|*armv7*|*armv8l*|*arm_arm1176*)
			archs="linux-armv7 linux-armv6 linux-armv5" ;;
		*armv6*)
			archs="linux-armv6 linux-armv5" ;;
		*arm*)
			archs="linux-armv7 linux-armv6 linux-armv5" ;;
		*mipsel_24kc*|*mipsel_74kc*|*mips32r2*el*|*mipsel*)
			archs="linux-mipsle-softfloat linux-mipsle-hardfloat" ;;
		*mips64el*)
			archs="linux-mips64le" ;;
		*mips64*)
			archs="linux-mips64" ;;
		*mips_24kc*|*mips_74kc*|*mips*)
			archs="linux-mips-softfloat linux-mips-hardfloat" ;;
		*riscv64*)
			archs="linux-riscv64" ;;
		*)
			archs="" ;;
	esac
	[ -n "$archs" ] || { warn "Не удалось определить архитектуру роутера ($a)"; return 1; }

	local free_flash
	free_flash="$(df -k /overlay 2>/dev/null | awk 'NR==2{print $4}')"
	[ -n "$free_flash" ] || free_flash="$(df -k /usr/bin 2>/dev/null | awk 'NR==2{print $4}')"
	[ -n "$free_flash" ] || free_flash="$(df -k / 2>/dev/null | awk 'NR==2{print $4}')"
	if [ -n "$free_flash" ] && [ "$free_flash" -lt 25000 ]; then
		warn "Недостаточно места во flash для официального sing-box (${free_flash} КБ свободно, требуется ~30 МБ)"
		return 1
	fi

	mkdir -p "$w"
	# Релиз и контрольные суммы берём из GitHub API: sing-box ставится под root,
	# поэтому непроверенный архив не устанавливаем. Тег можно закрепить:
	# VLESS_SINGBOX_TAG=v1.12.0 sh install.sh
	api_url="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
	[ -n "$VLESS_SINGBOX_TAG" ] && api_url="https://api.github.com/repos/SagerNet/sing-box/releases/tags/$VLESS_SINGBOX_TAG"
	curl -fsSL -m 15 "$api_url" -o "$w/release.json" 2>/dev/null || {
		warn "Не удалось получить данные релиза sing-box (лимит GitHub API или нет сети). Установите sing-box через пакетный менеджер или повторите позже."
		rm -rf "$w"
		return 1
	}
	tag="$(jq -r '.tag_name // empty' "$w/release.json" 2>/dev/null)"
	[ -n "$tag" ] || { warn "В ответе GitHub нет версии sing-box"; rm -rf "$w"; return 1; }
	ver="${tag#v}"

	for c in $archs; do
		name="sing-box-${ver}-${c}.tar.gz"
		want="$(jq -r --arg n "$name" '.assets[]? | select(.name==$n) | .digest // empty' "$w/release.json" 2>/dev/null)"
		want="${want#sha256:}"
		[ -n "$want" ] || continue
		rm -rf "$w/extract" "$w/sb.tar.gz"
		mkdir -p "$w/extract"
		url="https://github.com/SagerNet/sing-box/releases/download/${tag}/${name}"
		curl -fsSL -m 120 --connect-timeout 10 "$url" -o "$w/sb.tar.gz" 2>/dev/null || continue
		if ! sha256_check "$w/sb.tar.gz" "$want"; then
			warn "Контрольная сумма $name не совпала — архив отброшен"
			continue
		fi
		tar -xzf "$w/sb.tar.gz" -C "$w/extract" 2>/dev/null || continue
		rm -f "$w/sb.tar.gz"
		found="$(find "$w/extract" -name sing-box -type f 2>/dev/null | head -n1)"
		[ -n "$found" ] || continue
		chmod 755 "$found"
		if "$found" version >/dev/null 2>&1; then
			break
		else
			found=""
		fi
	done

	if [ -z "$found" ]; then
		rm -rf "$w"
		return 1
	fi

	[ -d "$bin_dir" ] || bin_dir="/bin"
	cp "$found" "$bin_dir/sing-box.new" && chmod 755 "$bin_dir/sing-box.new" && mv "$bin_dir/sing-box.new" "$bin_dir/sing-box" || {
		rm -rf "$w"
		return 1
	}
	rm -rf "$w"
	say "Установлен sing-box $("$bin_dir/sing-box" version 2>/dev/null | head -n1 | awk '{print $3}')"
	return 0
}

[ -f /etc/openwrt_release ] || { echo "Это не OpenWrt — установка остановлена."; exit 1; }
[ "$(id -u)" = "0" ] || { echo "Запустите от root."; exit 1; }

if command -v apk >/dev/null 2>&1; then PM=apk
elif command -v opkg >/dev/null 2>&1; then PM=opkg
else echo "Не найден менеджер пакетов (opkg/apk)."; exit 1; fi

free_kb="$(df -k /overlay 2>/dev/null | awk 'NR==2{print $4}')"
[ -n "$free_kb" ] || free_kb="$(df -k /usr/bin 2>/dev/null | awk 'NR==2{print $4}')"
[ -n "$free_kb" ] || free_kb="$(df -k / 2>/dev/null | awk 'NR==2{print $4}')"
[ -n "$free_kb" ] && [ "$free_kb" -lt 30000 ] && warn "Свободного места мало (${free_kb} КБ). sing-box занимает около 20–35 МБ."

say "Устанавливаю зависимости ($PM)"
DEPS="sing-box kmod-tun curl jq ca-bundle ip-full nftables kmod-nft-queue kmod-nfnetlink-queue"
if [ "$PM" = apk ]; then
	apk update >/dev/null 2>&1
	for p in $DEPS; do apk info -e "$p" >/dev/null 2>&1 || apk add "$p" || warn "Не удалось установить $p"; done
else
	opkg update >/dev/null 2>&1
	for p in $DEPS; do opkg list-installed "$p" 2>/dev/null | grep -q "^$p " || opkg install "$p" || warn "Не удалось установить $p"; done
fi

need_fetch=0
if ! command -v sing-box >/dev/null 2>&1; then
	need_fetch=1
else
	ver="$(sing-box version 2>/dev/null | head -n1 | awk '{print $3}')"
	major="${ver%%.*}"; minor="${ver#*.}"; minor="${minor%%.*}"
	if [ "${major:-0}" -lt 1 ] || { [ "${major:-0}" -eq 1 ] && [ "${minor:-0}" -lt 12 ]; }; then
		warn "В $PM устаревший sing-box ($ver), требуется 1.12+"
		need_fetch=1
	fi
fi

if [ "$need_fetch" = 1 ]; then
	fetch_singbox || {
		command -v sing-box >/dev/null 2>&1 || {
			echo "sing-box не установлен — без него VPN не заработает. Освободите место и повторите."
			exit 1
		}
	}
fi

say "Копирую файлы"
[ -f /etc/config/vless ] && cp /etc/config/vless /tmp/vless.config.keep

# Копию прежней установки держим до конца: если копирование оборвётся, вернём её,
# а не оставим человека без работающего приложения.
BK=/tmp/vless.prev.tar.gz
rm -f "$BK"
old_files=""
# Списки файлов пакета читаем из временных файлов (без раскрытия $(...) в цикле).
(cd root && find . -type f) | sed 's#^\./##' > /tmp/vless.files.root
(cd htdocs && find . -type f) | sed 's#^\./##' > /tmp/vless.files.www
while IFS= read -r f; do
	[ -n "$f" ] && [ -e "/$f" ] && old_files="$old_files $f"
done < /tmp/vless.files.root
while IFS= read -r f; do
	[ -n "$f" ] && [ -e "/www/$f" ] && old_files="$old_files www/$f"
done < /tmp/vless.files.www
rm -f /tmp/vless.files.root /tmp/vless.files.www
if [ -n "$old_files" ]; then
	# shellcheck disable=SC2086
	tar czf "$BK" -C / $old_files 2>/dev/null || rm -f "$BK"
fi

# Старый процесс держит /usr/bin/vless: без остановки копирование может пройти,
# а запущенный экземпляр останется старой версии до перезагрузки.
was_running=0
is_running_vless && { was_running=1; /etc/init.d/vless stop >/dev/null 2>&1; }

cp -a root/. /
cp -a htdocs/. /www/
[ -f /tmp/vless.config.keep ] && cp /tmp/vless.config.keep /etc/config/vless
chmod 0755 /usr/bin/vless /usr/bin/vless-discord /usr/libexec/rpcd/vless /etc/init.d/vless /etc/init.d/vless-discord /etc/uci-defaults/90-vless

# Копирование может оборваться на середине (нет места, обрыв ssh). Тогда пакет
# считался бы установленным, а VPN был бы сломан. Проверяем главное и откатываемся.
missing=""
for f in /usr/bin/vless /usr/bin/vless-discord /usr/libexec/rpcd/vless /etc/init.d/vless /etc/init.d/vless-discord \
	/usr/share/vless/discord-strategies.conf \
	/usr/share/vless/parse.jq /usr/share/vless/build.jq /usr/share/vless/presets.jq \
	/usr/share/vless/lib/util.sh /usr/share/vless/lib/validate.sh /usr/share/vless/lib/settings.sh /usr/share/vless/lib/discord.sh /usr/share/vless/lib/cron.sh /usr/share/vless/lib/subscriptions.sh \
	/usr/share/vless/lib/lifecycle.sh /usr/share/vless/lib/net.sh /usr/share/vless/lib/selective.sh /usr/share/vless/lib/probe.sh /usr/share/vless/lib/status.sh \
	/usr/share/rpcd/acl.d/luci-vless-selective.json; do
	[ -s "$f" ] || missing="$missing $f"
done
if [ -n "$missing" ]; then
	echo "Копирование файлов не завершилось, отсутствуют:$missing"
	if [ -s "$BK" ] && tar xzf "$BK" -C / 2>/dev/null; then
		echo "Прежняя версия восстановлена."
		[ "$was_running" = 1 ] && /etc/init.d/vless start >/dev/null 2>&1
	else
		# Свежая установка: оставлять половину файлов нельзя.
		sh uninstall.sh >/dev/null 2>&1
		[ -f /tmp/vless.config.keep ] && { mkdir -p /etc/config; cp /tmp/vless.config.keep /etc/config/vless; }
	fi
	echo "Установка прервана. Проверьте свободное место и повторите."
	exit 1
fi
rm -f "$BK" /tmp/vless.config.keep

[ -x /usr/bin/vless ] || { echo "Скрипт не исполняемый — проверка прав не пройдена."; exit 1; }

say "Применяю настройки"
[ -x /etc/uci-defaults/90-vless ] && { sh /etc/uci-defaults/90-vless; rm -f /etc/uci-defaults/90-vless; }
/etc/init.d/rpcd restart >/dev/null 2>&1
/etc/init.d/firewall reload >/dev/null 2>&1
rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache 2>/dev/null

pgrep -x sing-box >/dev/null 2>&1 && warn "Уже запущен другой sing-box (возможно, Podkop). Перед подключением остановите его — два VPN одновременно мешают друг другу."

# Выборочная маршрутизация работает только с dnsmasq, собранным с nftset (dnsmasq-full).
if command -v dnsmasq >/dev/null 2>&1; then
	dnsmasq --version 2>/dev/null | tr ' \t' '\n\n' | grep -qx 'nftset' \
		|| warn "dnsmasq собран без nftset: режим «только выбранные сервисы» работать не будет. Установите dnsmasq-full."
fi

# Обновление остановило работающий VPN — возвращаем его, а не оставляем выключенным.
[ "$was_running" = 1 ] && { say "Запускаю VPN снова"; /etc/init.d/vless start >/dev/null 2>&1; }

say "Самопроверка"
/usr/bin/vless selftest

say "Готово!"
echo "Откройте веб-интерфейс роутера → Службы → VPN"
echo "(если пункта нет — обновите страницу через Ctrl+F5 или перелогиньтесь)."
