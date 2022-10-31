#!/bin/sh

__bootstrap_webi() {

	##
	## Detect http client
	##
	set +e
	WEBI_CURL="$(command -v curl)"
	export WEBI_CURL
	WEBI_WGET="$(command -v wget)"
	export WEBI_WGET
	set -e

	## get ARCH
	get_arch() {
		ARCH=$(uname -m)
		case $ARCH in
		amd64) ARCH="amd64" ;;
		x86_64) ARCH="amd64" ;;
		i386) ARCH="386" ;;
		arm64) ARCH="arm64" ;;
		armv7*) ARCH="armv7" ;;
		aarch64) ARCH="arm64" ;;
		*)
			echo "Architecture ${ARCH} is not supported by this installation script"
			exit 1
			;;
		esac
	}

	## get OS
	get_os() {
		OS=$(uname | tr '[:upper:]' '[:lower:]')
		case "$OS" in
		darwin) OS='darwin' ;;
		linux) OS='linux' ;;
		mingw*) OS='windows' ;;
		msys*) OS='windows' ;;
		cygwin*) OS='windows' ;;
		*)
			echo "OS ${OS} is not supported by this installation script"
			exit 1
			;;
		esac
	}

	## get JSON
	get_json() {
		my_url="$2"

		if test -x "$(command -v curl)"; then
			response=$(curl -s -L -w 'HTTPSTATUS:%{http_code}' -H 'Accept: application/json' "$my_url")
			body=$(echo "$response" | sed -e 's/HTTPSTATUS\:.*//g')
			code=$(echo "$response" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
		elif test -x "$(command -v wget)"; then
			temp=$(mktemp)
			body=$(wget -q --header='Accept: application/json' -O - --server-response "$my_url" 2>"$temp")
			code=$(awk '/^  HTTP/{print $2}' <"$temp" | tail -1)
			rm "$temp"
		else
			echo "command not found: 'curl' and 'wget'."
			exit 1
		fi
		if [ "$code" != 200 ]; then
			echo "Request failed with code $code"
			exit 1
		fi

		eval "$1='$body'"
	}

	# Download File
	download() {
		my_url="$1"
		my_dl="$2"

		echo "Downloading from $my_url.."
		if test -x "$(command -v curl)"; then
			code=$(curl -s -w '%{http_code}' -L "$my_url" -o "$my_dl.part")
		elif test -x "$(command -v wget)"; then
			code=$(wget -q -O "$my_dl.part" --server-response "$my_url" 2>&1 | awk '/^  HTTP/{print $2}' | tail -1)
		else
			echo "command not found: 'curl' and 'wget'."
			exit 1
		fi

		if [ "$code" != 200 ]; then
			echo "Request failed with http code $code"
			exit 1
		fi

		if [ -s "$my_dl.part" ]; then
			mv "$my_dl.part" "$my_dl"
			if [ -e "$my_dl" ] && echo "$my_dl" | grep -v -q -e "yacd"; then
				echo "Saved as $my_dl"
			fi
		else
			rm -rf "$my_dl.part"
			return 0
		fi
	}

	# Download Config
	download_config() {
		my_url="$1"
		my_dl="$2"

		echo "Downloading from $my_url.."
		if test -x "$(command -v curl)"; then
			code=$(curl -s -w '%{http_code}' -L "$my_url" -o "$my_dl.part")
		elif test -x "$(command -v wget)"; then
			code=$(wget -q -O "$my_dl.part" --server-response "$my_url" 2>&1 | awk '/^  HTTP/{print $2}' | tail -1)
		else
			echo "command not found: 'curl' and 'wget'."
			exit 1
		fi

		set +e

		if [ "$code" != 200 ]; then
			echo "Request failed with http code $code"
			return 1
		fi

		$pkg_dst_cmd check -c $my_dl.part >/dev/null 2>&1
		if [ $? -eq 0 ]; then
			if [ "${OS}" = "linux" ]; then
				sed -i "s/\"mtu\"\: 9000/\"mtu\"\: 1500/g" "$my_dl.part"
				default_interface=$(ip route get 223.5.5.5 | awk -- '{printf $5}')
				if [ -n "${default_interface:-}" ]; then
					sed -i "s/\"auto_detect_interface\"\: true/\"default_interface\"\: \"${default_interface}\"/g" "$my_dl.part"
				fi
			fi
			mv "$my_dl.part" "$my_dl"
			echo "Saved as $my_dl"
			return 0
		else
			rm -rf "$my_dl.part"
			echo "Request failed with decode config"
			return 1
		fi

		set -e
	}

	# get the special formatted version (i.e. "go is go1.14" while node is "node v12.10.8")
	my_versioned_name=""
	_webi_canonical_name() {
		if [ -n "$my_versioned_name" ]; then
			echo "$my_versioned_name"
			return 0
		fi

		if [ -n "$(command -v pkg_format_cmd_version)" ]; then
			my_versioned_name="'$(pkg_format_cmd_version "$WEBI_VERSION")'"
		else
			my_versioned_name="'$pkg_cmd_name v$WEBI_VERSION'"
		fi

		echo "$my_versioned_name"
	}

	# update symlinks according to $HOME/.local/opt and $HOME/.local/bin install paths.
	# shellcheck disable=2120
	# webi_link may be used in the templated install script
	webi_link() {
		if [ -n "$(command -v pkg_link)" ]; then
			pkg_link
			return 0
		fi

		if [ -n "$WEBI_SINGLE" ] || [ "single" = "${1:-}" ]; then
			rm -rf "$pkg_dst_cmd"
			ln -s "$pkg_src_cmd" "$pkg_dst_cmd"
		else
			# 'pkg_dst' will default to $HOME/.local/opt/<pkg>
			# 'pkg_src' will be the installed version, such as to $HOME/.local/opt/<pkg>-<version>
			rm -rf "$pkg_dst"
			ln -s "$pkg_src" "$pkg_dst"
		fi
	}

	# detect if this program is already installed or if an installed version may cause conflict
	webi_check() {
		# Test for existing version
		set +e
		my_path="$PATH"
		PATH="$(dirname "$pkg_dst_cmd"):$PATH"
		export PATH
		my_current_cmd="$(command -v "$pkg_cmd_name")"
		set -e
		if [ -n "$my_current_cmd" ]; then
			my_canonical_name="$(_webi_canonical_name)"
			if [ "$my_current_cmd" != "$pkg_dst_cmd" ]; then
				echo >&2 "WARN: possible PATH conflict between $my_canonical_name and currently installed version"
				echo >&2 "    ${pkg_dst_cmd} (new)"
				echo >&2 "    ${my_current_cmd} (existing)"
				#my_current_version=false
			fi
			# 'readlink' can't read links in paths on macOS 🤦
			# but that's okay, 'cmp -s' is good enough for us
			if cmp -s "${pkg_src_cmd}" "${my_current_cmd}"; then
				echo "${my_canonical_name} already installed:"
				printf "    %s" "${pkg_dst}"
				if [ "${pkg_src_cmd}" != "${my_current_cmd}" ]; then
					printf " => %s" "${pkg_src}"
				fi
				echo ""
				_webi_done_message
				exit 0
			fi
			if [ -x "$pkg_src_cmd" ]; then
				# shellcheck disable=2119
				# this function takes no args
				webi_link
				echo "switched to $my_canonical_name:"
				echo "    ${pkg_dst} => ${pkg_src}"
				_webi_done_message
				exit 0
			fi
		fi
		export PATH="$my_path"
	}

	is_interactive_shell() {
		# $- shows shell flags (error,unset,interactive,etc)
		case $- in
		*i*)
			# true
			return 0
			;;
		*)
			# false
			return 1
			;;
		esac
	}

	# detect if file is downloaded, and how to download it
	webi_download() {
		# determine the url to download
		if [ -n "${1:-}" ]; then
			my_url="$1"
		else
			if [ "error" = "$WEBI_CHANNEL" ]; then
				# TODO pass back requested OS / Arch / Version
				echo >&2 "Error: no '$PKG_NAME' release for '${WEBI_OS:-}' on '$WEBI_ARCH' as one of '$WEBI_FORMATS' by the tag '${WEBI_TAG:-}'"
				echo >&2 "       '$PKG_NAME' is available for '$PKG_OSES' on '$PKG_ARCHES' as one of '$PKG_FORMATS'"
				echo >&2 "       (check that the package name and version are correct)"
				echo >&2 ""
				echo >&2 "       Double check at $(echo "$WEBI_RELEASES" | sed 's:\?.*::')"
				echo >&2 ""
				exit 1
			fi
			my_url="$WEBI_PKG_URL"
		fi

		# determine the location to download to
		if [ -n "${2:-}" ]; then
			my_dl="$2"
		else
			my_dl="${WEBI_PKG_PATH}/$WEBI_PKG_FILE"
		fi

		WEBI_PKG_DOWNLOAD="${my_dl}"
		export WEBI_PKG_DOWNLOAD

		if [ -e "$my_dl" ]; then
			echo "Found $my_dl"
			return 0
		fi

		echo "安装 $PKG_NAME 主程序..."
		echo "Downloading $PKG_NAME from $my_url"

		# It's only 2020, we can't expect to have reliable CLI tools
		# to tell us the size of a file as part of a base system...
		if [ -n "$WEBI_WGET" ]; then
			# wget has resumable downloads
			# TODO wget -c --content-disposition "$my_url"
			set +e
			my_show_progress=""
			if is_interactive_shell; then
				my_show_progress="--show-progress"
			fi
			if ! wget -q $my_show_progress --user-agent="wget $WEBI_UA" -c "$my_url" -O "$my_dl.part"; then
				echo >&2 "failed to download from $WEBI_PKG_URL"
				exit 1
			fi
			set -e
		else
			# Neither GNU nor BSD curl have sane resume download options, hence we don't bother
			# TODO curl -fsSL --remote-name --remote-header-name --write-out "$my_url"
			my_show_progress="-#"
			if is_interactive_shell; then
				my_show_progress=""
			fi
			# shellcheck disable=SC2086
			# we want the flags to be split
			curl -fSL $my_show_progress -H "User-Agent: curl $WEBI_UA" "$my_url" -o "$my_dl.part"
		fi
		mv "$my_dl.part" "$my_dl"
		echo "Saved as $my_dl"
	}

	# detect which archives can be used
	webi_extract() {
		(
			cd "$WEBI_TMP"
			if [ "tar" = "$WEBI_EXT" ]; then
				echo "Extracting ${WEBI_PKG_PATH}/$WEBI_PKG_FILE"
				tar xf "${WEBI_PKG_PATH}/$WEBI_PKG_FILE"
			elif [ "zip" = "$WEBI_EXT" ]; then
				echo "Extracting ${WEBI_PKG_PATH}/$WEBI_PKG_FILE"
				unzip "${WEBI_PKG_PATH}/$WEBI_PKG_FILE" >__unzip__.log
			elif [ "exe" = "$WEBI_EXT" ]; then
				echo "Moving ${WEBI_PKG_PATH}/$WEBI_PKG_FILE"
				mv "${WEBI_PKG_PATH}/$WEBI_PKG_FILE" .
			elif [ "xz" = "$WEBI_EXT" ]; then
				echo "Inflating ${WEBI_PKG_PATH}/$WEBI_PKG_FILE"
				unxz -c "${WEBI_PKG_PATH}/$WEBI_PKG_FILE" >"$(basename "$WEBI_PKG_FILE")"
			else
				# do nothing
				echo "Failed to extract ${WEBI_PKG_PATH}/$WEBI_PKG_FILE"
				exit 1
			fi
		)
	}

	# update path
	webi_path_add() {
		my_path="$PATH"
		export PATH="$HOME/.local/bin:$PATH"
	}

	# group common pre-install tasks as default
	webi_pre_install() {
		webi_check
		webi_download
		webi_extract
	}

	# move commands from the extracted archive directory to $HOME/.local/opt or $HOME/.local/bin
	# shellcheck disable=2120
	# webi_install may be sourced and used elsewhere
	webi_install() {
		if [ -n "$WEBI_SINGLE" ] || [ "single" = "${1:-}" ]; then
			mkdir -p "$(dirname "$pkg_src_cmd")"
			mv ./"$pkg_folder_name"/"$pkg_cmd_name"* "$pkg_src_cmd"
		else
			rm -rf "$pkg_src"
			mv ./"$pkg_folder_name"/"$pkg_cmd_name"* "$pkg_src"
		fi
	}

	# run post-install functions - just updating PATH by default
	webi_post_install() {
		webi_path_add "$(dirname "$pkg_dst_cmd")"
	}

	_webi_enable_exec() {
		if [ -n "$(command -v spctl)" ] && [ -n "$(command -v xattr)" ]; then
			# note: some packages contain files that cannot be affected by xattr
			xattr -r -d com.apple.quarantine "$pkg_src" || true
			return 0
		fi
		# TODO need to test that the above actually worked
		# (and proceed to this below if it did not)
		if [ -n "$(command -v spctl)" ]; then
			echo "Checking permission to execute '$pkg_cmd_name' on macOS 11+"
			set +e
			is_allowed="$(spctl -a "$pkg_src_cmd" 2>&1 | grep valid)"
			set -e
			if [ -z "$is_allowed" ]; then
				echo ""
				echo "##########################################"
				echo "#  IMPORTANT: Permission Grant Required  #"
				echo "##########################################"
				echo ""
				echo "Requesting permission to execute '$pkg_cmd_name' on macOS 10.14+"
				echo ""
				sleep 3
				spctl --add "$pkg_src_cmd"
			fi
		fi
	}

	# a friendly message when all is well, showing the final install path in $HOME/.local
	_webi_done_message() {
		echo "Installed $(_webi_canonical_name) as $pkg_dst_cmd"
		update_config
		pkg_start
	}

	update_config() {
		echo ""
		if [ -n "${pkg_config_url:-}" ]; then
			echo "更新节点..."
			download_config "$pkg_config_url" "$pkg_config_file"
			echo ""
		fi
	}

	get_inet4_tun() {
		if [ "${OS}" = "darwin" ]; then
			inet4_tun=$(ifconfig | grep -w "$inet4_config")
		elif [ "${OS}" = "linux" ]; then
			inet4_tun=$(ip a | grep -w "$inet4_config")
		fi
	}

	input_password() {
		if [ $(id -u) != 0 ]; then
			if [ ! -d "$HOME/.local/tmp" ]; then
				mkdir -p "$HOME/.local/tmp"
			fi
			if [ -s "$HOME/.local/tmp/.pw.txt" ]; then
				PASSWORD=$(cat "$HOME/.local/tmp/.pw.txt")
			else
				unset PASSWORD
				unset CHARCOUNT
				echo ""
				echo -n "请输入 '$(id -u -n)' 用户的开机登录密码: "
				stty -echo
				CHARCOUNT=0
				while IFS= read -p "$PROMPT" -r -s -n 1 CHAR; do
					# Enter - accept password
					if [[ $CHAR == $'\0' ]]; then
						break
					fi
					# Backspace
					if [[ $CHAR == $'\177' ]]; then
						if [ $CHARCOUNT -gt 0 ]; then
							CHARCOUNT=$((CHARCOUNT - 1))
							PROMPT=$'\b \b'
							PASSWORD="${PASSWORD%?}"
						else
							PROMPT=''
						fi
					else
						CHARCOUNT=$((CHARCOUNT + 1))
						PROMPT='*'
						PASSWORD+="$CHAR"
					fi
				done
				stty echo
				if [ -z "$PASSWORD" ]; then
					echo ""
					echo "密码不能为空"
					input_password
				else
					echo ""
					echo "$PASSWORD" >"$HOME/.local/tmp/.pw.txt"
				fi
			fi
		fi
	}
	pkg_start() {
		if ! pgrep -x "$PKG_NAME" >/dev/null; then

			$pkg_dst_cmd check -c $pkg_config_file >/dev/null 2>&1
			if [ $? -eq 0 ]; then
				inet4_config=$(cat $pkg_config_file | grep inet4_address | cut -d'"' -f4 | cut -d':' -f2 | cut -d'/' -f1)
			else
				printf "\e[31m配置文件 $pkg_config_file 格式错误.\e[0m\n"
				exit 1
			fi

			printf "正在启动 sing-box,请稍后...\n"
			if [ $(id -u) = 0 ]; then
				nohup "$pkg_dst_cmd" run -D "$pkg_config_path" &
			else
				echo "$PASSWORD" | nohup sudo -S "$pkg_dst_cmd" run -D "$pkg_config_path" &
			fi

			sleep 5
			get_inet4_tun
			if [ -n "$inet4_tun" ]; then
				printf "\e[32msing-box 已启动.\e[0m\n\n"
				echo ""
				echo ""
				printf "\e[33m如何更换节点？\e[0m\n在浏览器中打开 yacd 控制面板 \e[36mhttp://127.0.0.1:9090/ui/#/proxies\e[0m 测速完成后选择\e[36m有延迟\e[0m的节点.\e[0m\n\n"
				printf "\e[33m如何退出 sing-box 进程？\e[0m\n在\e[36m终端\e[0m窗口中按\e[36m上方向键\e[0m直到显示\e[36m一键运行命令\e[0m,按\e[36m回车键\e[0m再次执行'一键运行命令'可退出 sing-box 进程.\n\n"
				echo ""
				echo ""
				#				if [ "${OS}" = "darwin" ]; then
				#					open http://127.0.0.1:9090/ui/#/proxies
				#					exit 0
				#				fi
			else
				printf "\e[31msing-box 启动失败,请重试.\e[0m\n\n"
				rm -rf "$HOME/.local/tmp/.pw.txt"
				exit 1
			fi
		fi
	}

	pkg_stop() {
		if pgrep -x "sing-box" >/dev/null; then
			if [ $(id -u) = 0 ]; then
				pkill -9 sing-box && printf "\n\e[32msing-box 已退出.\e[0m\e[36m(当 sing-box 运行时，执行'一键运行命令'将退出 sing-box.)\e[0m\n\n" || printf "\n\e[31m退出 sing-box 失败.\e[0m\n\n"
			else
				echo "$PASSWORD" | sudo -S pkill -9 sing-box && printf "\n\e[32msing-box 已退出.\e[0m\e[36m(当 sing-box 运行时，执行'一键运行命令'将退出 sing-box.)\e[0m\n\n" || printf "\n\e[31m退出 sing-box 失败.\e[0m\n\n"
			fi
			rm -rf "$HOME/nohup.out"
			exit 0
		fi
	}

	##
	##
	## BEGIN custom override functions from <package>/install.sh
	##
	##

	#	if [ -z "${WEBI_WELCOME:-}" ]; then
	#		echo ""
	#		printf "Thanks for using webi to install '\e[32m%s\e[0m' on '\e[31m%s/%s\e[0m'.\n" "${WEBI_PKG:-}" "$(uname -s)" "$(uname -m)"
	#		echo "Have a problem? Experience a bug? Please let us know:"
	#		echo "        https://github.com/webinstall/webi-installers/issues"
	#		echo ""
	#		printf "\e[31mLovin'\e[0m it? Say thanks with a \e[34mStar on GitHub\e[0m:\n"
	#		printf "        \e[32mhttps://github.com/webinstall/webi-installers\e[0m\n"
	#		echo ""
	#	fi
	input_password
	pkg_stop

	get_arch
	get_os

	set -e
	set -u

	WEBI_SINGLE=true
	WEBI_PKG='sing-box'
	PKG_NAME='sing-box'
	WEBI_HOST='https://ghproxy.com'
	WEBI_RELEASES='https://github.com/SagerNet/sing-box/releases'

	if [ -n "${2:-}" ]; then
		VERSION="$2"
	else
		get_json LATEST_RELEASE "$WEBI_HOST/$WEBI_RELEASES/latest"
		VERSION=$(echo "${LATEST_RELEASE}" | tr -s '\n' ' ' | sed 's/.*"tag_name":"v//' | sed 's/".*//')
	fi

	WEBI_OS="${OS}"
	WEBI_ARCH="${ARCH}"
	WEBI_VERSION="${VERSION}"
	WEBI_TAG="v${VERSION}"
	WEBI_PKG_FILE="${PKG_NAME}-${WEBI_VERSION}-${WEBI_OS}-${WEBI_ARCH}.tar.gz"
	WEBI_PKG_URL="$WEBI_HOST/$WEBI_RELEASES/download/$WEBI_TAG/$WEBI_PKG_FILE"

	WEBI_CHANNEL=stable
	WEBI_EXT=tar
	WEBI_FORMATS='tar,exe,zip,git,dmg,pkg'
	PKG_OSES='linux,macos,windows'
	PKG_ARCHES='amd64,arm64,armv7,386'
	PKG_FORMATS='tar'
	WEBI_UA="$(uname -a)"
	WEBI_PKG_DOWNLOAD=""
	WEBI_PKG_PATH="${HOME}/.local/tmp/${PKG_NAME:-error}"
	pkg_config_path="${HOME}/.local/share/${PKG_NAME:-error}"
	pkg_config_file="${HOME}/.local/share/${PKG_NAME:-error}/config.json"
	pkg_folder_name="${PKG_NAME}-${WEBI_VERSION}-${WEBI_OS}-${WEBI_ARCH}"

	if echo "${1:-}" | grep -q -E '^https\:\/\/api.*'; then
		export pkg_config_url="$1"
	fi

	##
	## Set up tmp, download, and install directories
	##

	WEBI_TMP=${WEBI_TMP:-"$(mktemp -d -t webinstall-"${WEBI_PKG:-}".XXXXXXXX)"}
	export _webi_tmp="${_webi_tmp:-"$HOME/.local/opt/webi-tmp.d"}"

	mkdir -p "${pkg_config_path}"
	mkdir -p "${WEBI_PKG_PATH}"
	mkdir -p "$HOME/.local/bin"
	mkdir -p "$HOME/.local/opt"
	mkdir -p "$HOME/.local/tmp"

	echo ""

	# Delete GEOIP and GEOSITE than 30 days
	if [ -f "${pkg_config_path}/*.db" ]; then
		echo "删除 7 天前的 geoip 和 geosite 数据库..."
		find "${pkg_config_path}" -name '*.db' -ctime +7 -ls -exec rm -f {} \;
		echo ""
	fi

	# Download GEOIP
	if [ ! -f "${pkg_config_path}/geoip.db" ]; then
		echo "下载 geoip 数据库..."
		download "https://ghproxy.com/https://github.com/yuumimi/sing-geoip/releases/latest/download/geoip.db" "${pkg_config_path}/geoip.db"
		echo ""
	fi

	# Download GEOSITE
	if [ ! -f "${pkg_config_path}/geosite.db" ]; then
		echo "下载 geosite 数据库..."
		download "https://ghproxy.com/https://github.com/yuumimi/sing-geosite/releases/latest/download/geosite.db" "${pkg_config_path}/geosite.db"
		echo ""
	fi

	# Download YACD
	if [ ! -f "${pkg_config_path}/yacd/index.html" ]; then
		echo "安装 yacd 控制面板..."
		if [ -n "$(command -v tar)" ]; then
			download "https://ghproxy.com/https://github.com/yuumimi/yacd/releases/latest/download/yacd.tar.gz" "$WEBI_TMP/yacd.tar.gz"
			(cd "$WEBI_TMP" && tar xf "yacd.tar.gz" >__extract__.log && cp -f -r "public/" "${pkg_config_path}/yacd/")
			echo "Installed to ${pkg_config_path}/yacd"
			echo ""
		elif [ -n "$(command -v unzip)" ]; then
			download "https://ghproxy.com/https://github.com/yuumimi/yacd/archive/refs/heads/gh-pages.zip" "$WEBI_TMP/yacd-gh-pages.zip"
			(cd "$WEBI_TMP" && unzip "yacd-gh-pages.zip" >__extract__.log && cp -f -r "yacd-gh-pages/" "${pkg_config_path}/yacd/")
			echo "Installed to ${pkg_config_path}/yacd"
			echo ""
		else
			echo "command not found: 'tar' and 'unzip'."
			exit 1
		fi
	fi

	__init_installer() {

		# do nothing - to satisfy parser prior to templating
		printf ""
		#!/bin/sh

		# Note: 'webi' is a special case. It's actually just a helper utility that comes with every installer.
		#       See https://github.com/webinstall/packages/blob/master/_webi/bootstrap.sh for the source.

		#		__faux_webi() {
		#
		#			if [ -f "$HOME/.local/bin/webi" ]; then
		#				set +e
		#				cur_webi="$(command -v webi)"
		#				set -e
		#				if [ -z "$cur_webi" ]; then
		#					webi_path_add "$HOME/.local/bin"
		#				fi
		#			else
		#				# for when this file is run on its own, not from webinstall.dev
		#				echo "Install any other package via https://webinstall.dev and webi will be installed as part of the bootstrap process"
		#			fi
		#
		#			echo ""
		#			echo "'webi' installed to ~/.local/bin/webi"
		#			echo ""
		#			echo "Usage:"
		#			echo "    webi <package-name>[@version] ..."
		#			echo ""
		#			echo "Example:"
		#			echo "    webi node@lts prettier vim-essentials"
		#			echo ""
		#		}
		#
		#		__faux_webi

	}

	__init_installer

	##
	##
	## END custom override functions
	##
	##

	# run everything with defaults or overrides as needed
	if command -v pkg_install >/dev/null ||
		command -v pkg_link >/dev/null ||
		command -v pkg_post_install >/dev/null ||
		command -v pkg_done_message >/dev/null ||
		command -v pkg_format_cmd_version >/dev/null ||
		[ -n "${WEBI_SINGLE:-}" ] ||
		[ -n "${pkg_cmd_name:-}" ] ||
		[ -n "${pkg_dst_cmd:-}" ] ||
		[ -n "${pkg_dst_dir:-}" ] ||
		[ -n "${pkg_dst:-}" ] ||
		[ -n "${pkg_src_cmd:-}" ] ||
		[ -n "${pkg_src_dir:-}" ] ||
		[ -n "${pkg_src:-}" ]; then

		pkg_cmd_name="${pkg_cmd_name:-$PKG_NAME}"

		if [ -n "$WEBI_SINGLE" ]; then
			pkg_dst_cmd="${pkg_dst_cmd:-$HOME/.local/bin/$pkg_cmd_name}"
			pkg_dst="$pkg_dst_cmd" # "$(dirname "$(dirname $pkg_dst_cmd)")"

			#pkg_src_cmd="${pkg_src_cmd:-$HOME/.local/opt/$pkg_cmd_name-v$WEBI_VERSION/bin/$pkg_cmd_name-v$WEBI_VERSION}"
			pkg_src_cmd="${pkg_src_cmd:-$HOME/.local/opt/$pkg_cmd_name-v$WEBI_VERSION/bin/$pkg_cmd_name}"
			pkg_src="$pkg_src_cmd" # "$(dirname "$(dirname $pkg_src_cmd)")"
		else
			pkg_dst="${pkg_dst:-$HOME/.local/opt/$pkg_cmd_name}"
			pkg_dst_cmd="${pkg_dst_cmd:-$pkg_dst/bin/$pkg_cmd_name}"

			pkg_src="${pkg_src:-$HOME/.local/opt/$pkg_cmd_name-v$WEBI_VERSION}"
			pkg_src_cmd="${pkg_src_cmd:-$pkg_src/bin/$pkg_cmd_name}"
		fi
		# this script is templated and these are used elsewhere
		# shellcheck disable=SC2034
		pkg_src_bin="$(dirname "$pkg_src_cmd")"
		# shellcheck disable=SC2034
		pkg_dst_bin="$(dirname "$pkg_dst_cmd")"

		if [ -n "$(command -v pkg_pre_install)" ]; then pkg_pre_install; else webi_pre_install; fi

		(
			cd "$WEBI_TMP"
			echo "Installing to $pkg_src_cmd"
			if [ -n "$(command -v pkg_install)" ]; then pkg_install; else webi_install; fi
			chmod a+x "$pkg_src"
			chmod a+x "$pkg_src_cmd"
		)

		webi_link

		_webi_enable_exec

		(
			cd "$WEBI_TMP"
			if [ -n "$(command -v pkg_post_install)" ]; then pkg_post_install; else webi_post_install; fi
		)

		(
			cd "$WEBI_TMP"
			if [ -n "$(command -v pkg_done_message)" ]; then pkg_done_message; else _webi_done_message; fi
		)
	fi

	webi_path_add "$HOME/.local/bin"
	if [ -z "${_WEBI_CHILD:-}" ] && [ -f "$_webi_tmp/.PATH.env" ]; then
		if [ -n "$(cat "$_webi_tmp/.PATH.env")" ]; then
			printf 'PATH.env updated with:\n'
			sort -u "$_webi_tmp/.PATH.env"
			printf "\n"

			rm -f "$_webi_tmp/.PATH.env"

			printf "\e[31mTO FINISH\e[0m: copy, paste & run the following command:\n"
			printf "\n"
			printf "        \e[34msource ~/.config/envman/PATH.env\e[0m\n"
			printf "        (newly opened terminal windows will update automatically)\n"
		fi
	fi

	# cleanup the temp directory
	rm -rf "$WEBI_TMP"

	# See? No magic. Just downloading and moving files.
}

__bootstrap_webi "$@"
