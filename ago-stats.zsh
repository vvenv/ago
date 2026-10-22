#!/usr/bin/env zsh
# ago stats — 显示最常用的命令行，按命令名分组（纯 zsh + awk）
#
# 用法: ago stats [-f 历史文件] [-n 前N个命令] [-k 每组K条] [-d 最近N天] [-g 命令名]

histfile=${HISTFILE:-~/.zsh_history}
top=15 per=5 days=0 only=

while getopts "f:n:k:d:g:h" opt; do
  case $opt in
    f) histfile=$OPTARG ;;
    n) top=$OPTARG ;;
    k) per=$OPTARG ;;
    d) days=$OPTARG ;;
    g) only=$OPTARG ;;
    *) print -u2 "用法: ago stats [-f 历史文件] [-n 前N个命令] [-k 每组K条] [-d 最近N天] [-g 命令名]"; exit 1 ;;
  esac
done

[[ -r $histfile ]] || { print -u2 "无法读取历史文件: $histfile"; exit 1 }

if [[ -t 1 ]]; then bold=$'\e[1m' dim=$'\e[2m' reset=$'\e[0m'; else bold= dim= reset=; fi
zmodload zsh/datetime
cutoff=0
(( days > 0 )) && cutoff=$(( EPOCHSECONDS - days * 86400 ))

# 用 zsh 自己读历史：自动处理 extended 格式、多行命令和中文的 metafy 编码
HISTSIZE=10000000
fc -R $histfile

# 第一步：拆分子命令并计数，输出 "类型<TAB>次数<TAB>命令名[<TAB>内容]"
# awk/sort 用 LC_ALL=C 按字节处理，避免截断后的残缺 UTF-8 让 sort 报错
fc -lnt '%s' 1 2>/dev/null | LC_ALL=C awk -v cutoff=$cutoff '
BEGIN {
  split("sudo time nohup env exec command builtin noglob nice", p, " ")
  for (i in p) prefix[p[i]] = 1
}
{
  ts = $1
  sub(/^[0-9]+ +/, "")
  if (ts < cutoff) next
  entries++
  gsub(/\t/, " ")
  # 按 | & ; 和换行（fc 输出为 \n）拆分，忽略引号内的分隔符和 heredoc 正文
  line = $0; seg = ""; q = ""; hd = ""; pend = ""; n = length(line)
  for (i = 1; i <= n; i++) {
    c = substr(line, i, 1)
    if (c == "\\") {
      d = substr(line, i + 1, 1)
      if (q == "" && d == "n") {
        if (hd != "") { t = seg; gsub(/^[ ]+|[ ]+$/, "", t); if (t == hd) hd = "" }
        else { handle(seg); if (pend != "") { hd = pend; pend = "" } }
        seg = ""; i++; continue
      }
      seg = seg c d; i++; continue
    }
    if (hd != "") { seg = seg c; continue }
    # 记下 <<EOF / <<-'\''EOF'\'' 的结束标记，下一行起跳过正文（<<< 不是 heredoc）
    if (q != "'\''" && substr(line, i, 2) == "<<" && substr(line, i + 2, 1) != "<") {
      t = substr(line, i + 2); sub(/^-?[ ]*["'\'']?/, "", t)
      if (match(t, /^[A-Za-z0-9_]+/)) pend = substr(t, 1, RLENGTH)
      seg = seg "<<"; i++; continue
    }
    if (q != "") { if (c == q) q = ""; seg = seg c; continue }
    if (c == "\"" || c == "'\''") { q = c; seg = seg c; continue }
    # 2>&1、>&2、&> 这类重定向里的 & 不是分隔符
    if (c == "&" && (substr(line, i - 1, 1) == ">" || substr(line, i + 1, 1) == ">")) { seg = seg c; continue }
    if (c == "|" || c == "&" || c == ";") { handle(seg); seg = ""; continue }
    seg = seg c
  }
  if (hd == "") handle(seg)
}
function handle(s,    w, nw, i, name, rest, j) {
  nw = split(s, w, /[ ]+/)
  i = 1
  while (i <= nw && (w[i] == "" || w[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/ || w[i] in prefix || (w[i] ~ /^-/ && w[i-1] in prefix))) i++
  if (i > nw) return
  name = w[i]
  if (name ~ /\//) sub(/.*\//, "", name)
  # 只接受像命令名的词，排除注释、引号、括号等多行内容里的碎片
  if (name !~ /^[A-Za-z0-9_.~+@][A-Za-z0-9_.~+@:-]*$/) return
  cnt[name]++
  if (i + 1 <= nw && w[i+1] !~ /^-/ && w[i+1] != "") subc[name SUBSEP w[i+1]]++
  rest = name
  for (j = i + 1; j <= nw; j++) if (w[j] != "") rest = rest " " w[j]
  if (length(rest) > 100) {
    rest = substr(rest, 1, 97)
    sub(/[\200-\377]+$/, "", rest)   # 去掉被截断的半个多字节字符
    rest = rest "..."
  }
  full[name SUBSEP rest]++
}
END {
  for (k in cnt) { print "T\t" cnt[k] "\t" k; nsub += cnt[k] }
  for (k in subc) { split(k, a, SUBSEP); print "S\t" subc[k] "\t" a[1] "\t" a[2] }
  for (k in full) { split(k, a, SUBSEP); print "F\t" full[k] "\t" a[1] "\t" a[2] }
  print "Z\t" entries "\t" nsub
}' |
# 第二步：按次数降序排好，再取每组的前几名并格式化输出
LC_ALL=C sort -t $'\t' -k2,2nr |
awk -F '\t' -v top=$top -v per=$per -v only="$only" -v bold="$bold" -v dim="$dim" -v reset="$reset" '
$1 == "Z" { entries = $2; nsub = $3; next }
$1 == "T" {
  ncmd++; cnt[$3] = $2
  if (only == "" ? norder < top : $3 == only) order[++norder] = $3
  next
}
$1 == "S" { if (ns[$3] < 8) subs[$3] = subs[$3] (ns[$3]++ ? ", " : "") $4 "(" $2 ")"; next }
$1 == "F" { if (nf[$3] < per) fulls[$3] = fulls[$3] sprintf("    %5d  %s\n", $2, $4); nf[$3]++; next }
END {
  printf "共 %d 条历史，%d 个子命令，%d 个不同命令名\n\n", entries, nsub, ncmd
  max = cnt[order[1]] ? cnt[order[1]] : 1
  for (r = 1; r <= norder; r++) {
    name = order[r]; c = cnt[name]
    bar = ""; w = int(20 * c / max + 0.5); if (w < 1) w = 1
    for (b = 0; b < w; b++) bar = bar "█"
    printf "%s%2d. %-14s%s %6d  %5.1f%%  %s\n", bold, r, name, reset, c, (nsub ? c * 100 / nsub : 0), bar
    if (ns[name] > 1) printf "    %s子命令: %s%s\n", dim, subs[name], reset
    printf "%s\n", fulls[name]
  }
}'
