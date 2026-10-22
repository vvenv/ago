#!/bin/sh
# ago 安装脚本
#
#   ./install.sh              安装：在 ~/.zshrc 里加一行 source（可重复运行）
#   ./install.sh --uninstall  卸载：删掉那一行（不删除本目录）
#
# 也可以不 clone，一行命令安装（会 clone 到 $AGO_HOME，默认 ~/.ago）：
#   sh -c "$(curl -fsSL https://raw.githubusercontent.com/vvenv/ago/main/install.sh)"
set -e

TAG='# ago-install'
RC="${ZDOTDIR:-$HOME}/.zshrc"
AGO_HOME="${AGO_HOME:-$HOME/.ago}"
AGO_REPO="${AGO_REPO:-https://github.com/vvenv/ago.git}"

say() { printf '%s\n' "$*"; }
die() { printf 'ago: %s\n' "$*" >&2; exit 1; }

# 找到 ago.zsh 所在目录：优先用脚本旁边的，否则 clone 一份
dir=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
if [ ! -f "$dir/ago.zsh" ]; then
  command -v git >/dev/null || die "需要 git 来下载 ago"
  if [ -d "$AGO_HOME/.git" ]; then
    git -C "$AGO_HOME" pull --ff-only -q
  else
    git clone -q --depth 1 "$AGO_REPO" "$AGO_HOME"
  fi
  dir=$AGO_HOME
fi

# 删除 rc 文件里带标记的行（写回原文件，保留权限和软链接）
strip_line() {
  [ -f "$RC" ] || return 0
  grep -q "$TAG\$" "$RC" || return 0
  cp "$RC" "$RC.ago-bak"
  grep -v "$TAG\$" "$RC.ago-bak" > "$RC.ago-tmp" || true
  cat "$RC.ago-tmp" > "$RC"
  rm -f "$RC.ago-tmp"
}

if [ "$1" = "--uninstall" ]; then
  strip_line
  say "已从 $RC 移除 ago（备份：$RC.ago-bak）。重新打开终端后生效。"
  say "如需彻底删除，手动删掉目录：$dir"
  exit 0
fi

command -v zsh >/dev/null || die "ago 需要 zsh"
zsh -c 'autoload -Uz is-at-least && is-at-least 5.3' || die "ago 需要 zsh 5.3 或更新版本"

strip_line
[ -f "$RC" ] && [ -n "$(tail -c 1 "$RC")" ] && printf '\n' >> "$RC"
printf '[ -f "%s/ago.zsh" ] && source "%s/ago.zsh"  %s\n' "$dir" "$dir" "$TAG" >> "$RC"

say "ago 已安装到 $RC"
say "执行 source $RC 或重新打开终端，然后按 Ctrl-R 或输入 ago 开始使用。"
