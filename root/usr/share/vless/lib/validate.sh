# shellcheck shell=sh disable=SC2154
# vless / validate.sh — проверка адресов, CIDR и доменов.
# Подключается из /usr/bin/vless (общие переменные и функции живут там и в других модулях); отдельно не запускается.

valid_ip() { # четыре числа 0–255
	printf '%s' "$1" | awk -F. 'NF == 4 { for (i = 1; i <= 4; i++) if ($i !~ /^[0-9]+$/ || $i + 0 > 255) exit 1; exit 0 } { exit 1 }'
}
valid_cidr() { # IP или IP/маска (0–32)
	case "$1" in
		*/*)
			local mask="${1#*/}"
			case "$mask" in *'/'*) return 1 ;; esac
			case "$mask" in
				''|*[!0-9]*) return 1 ;;
			esac
			[ "$mask" -le 32 ] 2>/dev/null || return 1
			;;
	esac
	valid_ip "${1%%/*}"
}

valid_ipv6() { # IPv6-адрес или адрес/префикс
	local addr="$1" prefix="${1#*/}" embedded
	case "$1" in
		*/*)
			case "$prefix" in ''|*[!0-9]*|*/*) return 1 ;; esac
			[ "$prefix" -le 128 ] 2>/dev/null || return 1
			addr="${1%%/*}"
			;;
	esac
	case "$addr" in *:*) ;; *) return 1 ;; esac
	case "$addr" in
		*.*)
			embedded="${addr##*:}"
			[ "$embedded" != "$addr" ] && valid_ip "$embedded" || return 1
			addr="${addr%:*}:ffff:ffff"
			;;
	esac
	awk -v ip="$addr" '
		BEGIN {
			if (index(ip, ":::")) exit 1
			copy = ip
			compressed = sub(/::/, "", copy)
			if (index(copy, "::")) exit 1
			n = split(ip, groups, ":")
			count = 0
			for (i = 1; i <= n; i++) {
				if (groups[i] == "") {
					if (!compressed) exit 1
					continue
				}
				if (length(groups[i]) > 4 || groups[i] !~ /^[[:xdigit:]]+$/) exit 1
				count++
			}
			if (compressed ? count >= 8 : count != 8) exit 1
		}'
}

valid_domain() {
	local domain="$1"
	case "$domain" in
		\*.*) domain="${domain#*.}" ;;
		*'*'*) return 1 ;;
	esac
	[ -n "$domain" ] && [ "${#domain}" -le 253 ] || return 1
	printf '%s\n' "$domain" | awk -F. '
		length($0) > 253 || NF == 0 { exit 1 }
		{
			for (i = 1; i <= NF; i++) {
				if (length($i) == 0 || length($i) > 63 ||
					$i !~ /^[A-Za-z0-9-]+$/ || $i ~ /^-/ || $i ~ /-$/) exit 1
			}
		}'
}

valid_route_target() {
	case "$1" in
		*/*)
			case "$1" in *:*) valid_ipv6 "$1" ;; *) valid_cidr "$1" ;; esac ;;
		*:*) valid_ipv6 "$1" ;;
		*[!0-9.]* ) valid_domain "$1" ;;
		*) valid_ip "$1" ;;
	esac
}
