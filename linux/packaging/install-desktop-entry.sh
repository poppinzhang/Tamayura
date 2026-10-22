#!/bin/sh
# Adds this extracted Tamayura folder to the current user's application menu,
# or removes the entry with --remove. Run it again after moving the folder.
# Nothing outside the user's own data folder is changed.
set -eu

app_id=dev.tamayura.app
bundle=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
data_home=${XDG_DATA_HOME:-$HOME/.local/share}
entry="$data_home/applications/$app_id.desktop"
sizes="16 22 24 32 48 64 128 256 512"

# Messages follow the system language, as the app's native text does.
case "${LANGUAGE:-${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}}" in
  zh*) language=zh ;;
  ja*) language=ja ;;
  *) language=en ;;
esac

message() {
  case "$language:$1" in
    zh:added) printf '已将玉响添加到应用菜单：%s\n' "$2" ;;
    ja:added) printf 'Tamayura をアプリケーションメニューに追加しました: %s\n' "$2" ;;
    *:added) printf 'Added Tamayura to the application menu: %s\n' "$2" ;;
    zh:removed) printf '已从应用菜单移除玉响。\n' ;;
    ja:removed) printf 'Tamayura をアプリケーションメニューから削除しました。\n' ;;
    *:removed) printf 'Removed Tamayura from the application menu.\n' ;;
    zh:missing) printf '请在解压后的玉响文件夹中运行此脚本。\n' ;;
    ja:missing) printf '展開した Tamayura フォルダー内でこのスクリプトを実行してください。\n' ;;
    *:missing) printf 'Run this script from the extracted Tamayura folder.\n' ;;
    zh:unsupported) printf '玉响文件夹的路径包含 %% 或换行，无法添加到应用菜单。请移动文件夹后重新运行：%s\n' "$2" ;;
    ja:unsupported) printf 'Tamayura フォルダーのパスに %% または改行が含まれているため、アプリケーションメニューに追加できません。フォルダーを移動してから再実行してください: %s\n' "$2" ;;
    *:unsupported) printf 'The Tamayura folder path contains %% or a line break and cannot be added to the application menu. Move the folder and run this script again: %s\n' "$2" ;;
    zh:usage) printf '用法：%s [--remove]\n' "$2" ;;
    ja:usage) printf '使い方: %s [--remove]\n' "$2" ;;
    *:usage) printf 'Usage: %s [--remove]\n' "$2" ;;
  esac
}

refresh() {
  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$data_home/applications" >/dev/null 2>&1 || true
  fi
  if command -v gtk-update-icon-cache >/dev/null 2>&1 &&
    [ -f "$data_home/icons/hicolor/index.theme" ]; then
    gtk-update-icon-cache --quiet "$data_home/icons/hicolor" >/dev/null 2>&1 || true
  fi
}

case "${1:-}" in
  --remove)
    rm -f "$entry"
    for size in $sizes; do
      rm -f "$data_home/icons/hicolor/${size}x${size}/apps/$app_id.png"
    done
    refresh
    message removed
    exit 0
    ;;
  '') ;;
  *)
    message usage "$0" >&2
    exit 2
    ;;
esac

if [ ! -x "$bundle/tamayura" ] || [ ! -d "$bundle/data/icons/hicolor" ]; then
  message missing >&2
  exit 1
fi

# GLib checks the Exec program before turning %% back into %, so it would
# hide such an entry; Desktop Entry values cannot hold a line break.
case "$bundle" in
  *%* | *'
'*)
    message unsupported "$bundle" >&2
    exit 1
    ;;
esac

for size in $sizes; do
  target="$data_home/icons/hicolor/${size}x${size}/apps"
  mkdir -p "$target"
  cp "$bundle/data/icons/hicolor/${size}x${size}/apps/$app_id.png" "$target/$app_id.png"
done

# Desktop Entry quoting: a quoted Exec argument escapes " ` $ and \ with a
# backslash, and string values then escape each backslash once more.
program="$bundle/tamayura"
exec_value=$(printf '%s' "$program" |
  sed -e 's/\\/\\\\\\\\/g' -e 's/["`$]/\\\\&/g')
try_exec=$(printf '%s' "$program" | sed -e 's/\\/\\\\/g')

mkdir -p "$data_home/applications"
temporary="$entry.$$.tmp"
cat >"$temporary" <<EOF
[Desktop Entry]
Type=Application
Version=1.5
Name=Tamayura
Name[zh]=玉响
GenericName=Local Network Album
GenericName[zh]=局域网相册
GenericName[ja]=ローカルネットワークのアルバム
Comment=Browse and fetch photos and videos across devices on your local network
Comment[zh]=在局域网设备之间浏览与按需传递照片、视频
Comment[ja]=ローカルネットワーク上のデバイス間で写真や動画を閲覧し、必要なときに受け取れます
Exec="$exec_value"
TryExec=$try_exec
Icon=$app_id
Terminal=false
StartupNotify=true
StartupWMClass=$app_id
SingleMainWindow=true
Categories=Graphics;Photography;
Keywords=photo;video;gallery;LAN;share;sync;
Keywords[zh]=照片;视频;相册;局域网;共享;同步;
Keywords[ja]=写真;動画;アルバム;LAN;共有;同期;
EOF
chmod 644 "$temporary"
mv -f "$temporary" "$entry"
refresh
message added "$entry"
