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

# 配色参考 mole status：紫色标题、绿色进度条、灰色分隔线
if [[ -t 1 ]]; then
  bold=$'\e[1m' title=$'\e[1;38;5;141m' fill=$'\e[38;5;120m' track=$'\e[38;5;238m' dim=$'\e[38;5;244m' reset=$'\e[0m'
else
  bold= title= fill= track= dim= reset=
fi
cols=${COLUMNS:-$(tput cols 2>/dev/null)}
(( cols >= 40 )) || cols=80
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
  # 只把像单词的参数当子命令（git push、pnpm dev），路径、引号、user@host 等不算
  if (i + 1 <= nw && w[i+1] ~ /^[A-Za-z][A-Za-z0-9_.:-]*$/) subc[name SUBSEP w[i+1]]++
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
# 布局参考 mole status：两栏卡片，每行「标签 进度条 数值」，汇总信息放在卡片最后一行
awk -F '\t' -v top=$top -v per=$per -v only="$only" -v days=$days -v cols=$cols -v home="$HOME" \
  -v bold="$bold" -v title="$title" -v fill="$fill" -v track="$track" -v dim="$dim" -v reset="$reset" '
function bar(c, m,    w, s, b) {
  w = int(16 * c / m + 0.5); if (w < 1) w = 1
  s = fill; for (b = 0; b < 16; b++) { if (b == w) s = s track; s = s (b < w ? "█" : "░") }
  return s reset
}
function rep(c, n,    s) { s = ""; while (n-- > 0) s = s c; return s }
# 按字节估算显示宽度：跳过颜色码，中日韩字符占 2 列，◉ ╌ · 等符号占 1 列
function cw(c) { return c < "\200" ? 1 : (c >= "\343" && c <= "\355" || c >= "\360") ? 2 : 1 }
function cb(c) { return c < "\200" ? 1 : c >= "\360" ? 4 : c >= "\340" ? 3 : c >= "\300" ? 2 : 1 }
function dw(s,    n, i, c, l) {
  n = 0; l = length(s)
  for (i = 1; i <= l; i += cb(c)) {
    c = substr(s, i, 1)
    if (c == "\033") { while (i < l && substr(s, i, 1) != "m") i++; c = "m"; continue }
    n += cw(c)
  }
  return n
}
function clip(s, n,    i, l, c, t, tw) {
  if (dw(s) <= n) return s
  t = ""; tw = 0; l = length(s)
  for (i = 1; i <= l; i += cb(c)) {
    c = substr(s, i, 1)
    if (tw + cw(c) > n - 3) break
    t = t substr(s, i, cb(c)); tw += cw(c)
  }
  return t "..."
}
function pct(a, b) { return sprintf("%5.1f%%", b ? a * 100 / b : 0) }
function card(icon, name) {
  H[++nc] = 0
  add(title icon " " name reset "  " track rep("╌", colw - dw(icon name) - 3) reset)
}
function add(s) { L[nc, ++H[nc]] = s }
function lab(s, w) { s = clip(s, w); return s rep(" ", w - dw(s)) }
function cell(k, i) { return i <= H[k] ? L[k, i] : "" }
function pad(s) { return s rep(" ", colw - dw(s)) }
$1 == "Z" { entries = $2; nsub = $3; next }
$1 == "T" {
  ncmd++; cnt[$3] = $2
  if (only == "" ? norder < top : $3 == only) order[++norder] = $3
  next
}
$1 == "S" { ws[$3] += $2; if (ns[$3]++ < per) { sc[$3, ns[$3]] = $2; sl[$3, ns[$3]] = $4 }; next }
$1 == "F" { if (nf[$3]++ < per) { fc[$3, nf[$3]] = $2; fl[$3, nf[$3]] = $4 }; next }
END {
  two = cols >= 100
  colw = two ? int((cols - 4) / 2) : cols; if (colw > 72) colw = 72
  printf "%sStats%s  %s%d%s 条历史  %s%d%s 次调用  %s%d%s 个命令名%s\n", title, reset,
    bold, entries, reset, bold, nsub, reset, bold, ncmd, reset, (days > 0 ? dim "  · 最近 " days " 天" reset : "")
  if (!norder) { if (only != "") printf "\n%s没有找到命令: %s%s\n", dim, only, reset; exit }

  # 排行卡片：和 mole 的进程列表一样，#N 进度条 占比 次数 命令名
  if (only == "") {
    card("◉", "常用命令"); shown = 0
    for (r = 1; r <= norder; r++) {
      name = order[r]; shown += cnt[name]
      add(dim lab("#" r, 6) reset bar(cnt[name], cnt[order[1]]) "  " pct(cnt[name], nsub) "  " sprintf("%5d", cnt[name]) "  " bold clip(name, colw - 40) reset)
    }
    if (ncmd > norder) add(dim lab("其余", 6) (ncmd - norder) " 个命令 · " (nsub - shown) " 次" reset)
  }

  # 详情卡片：git、pnpm 这类按子命令统计；cd、grep 这类参数是路径或文本的，列出完整命令
  ndet = only == "" ? (norder < 5 ? norder : 5) : norder
  for (r = 1; r <= ndet; r++) {
    name = order[r]; c = cnt[name]
    card("▸", name)
    if (ns[name] > 1 && ws[name] * 2 >= c) {
      lw = 6; m = ns[name] < per ? ns[name] : per
      for (k = 1; k <= m; k++) if (dw(sl[name, k]) + 2 > lw) lw = dw(sl[name, k]) + 2
      if (lw > 16) lw = 16
      for (k = 1; k <= m; k++)
        add(lab(sl[name, k], lw) bar(sc[name, k], sc[name, 1]) "  " pct(sc[name, k], c) "  " sprintf("%5d", sc[name, k]))
    } else {
      lw = 6; m = nf[name] < per ? nf[name] : per
      for (k = 1; k <= m; k++) {
        s = fl[name, k]
        if (home != "") { while ((i = index(s, home "/")) > 0) s = substr(s, 1, i - 1) "~" substr(s, i + length(home)) }
        add(dim lab("#" k, lw) reset bar(fc[name, k], fc[name, 1]) "  " sprintf("%5d", fc[name, k]) "  " clip(s, colw - lw - 25))
      }
    }
    add(dim lab("合计", lw) c " 次 · 占全部 " sprintf("%.1f%%", nsub ? c * 100 / nsub : 0) reset)
  }

  print ""
  if (!two) {
    for (k = 1; k <= nc; k++) { for (i = 1; i <= H[k]; i++) print L[k, i]; if (k < nc) print "" }
    exit
  }
  # 两栏：排行放左栏，右栏叠放详情直到和左栏差不多高，剩下的详情两两并排
  k = 1
  if (only == "") {
    nr = 0
    for (k = 2; k <= nc && nr < H[1]; k++) {
      if (nr) R[++nr] = ""
      for (i = 1; i <= H[k]; i++) R[++nr] = L[k, i]
    }
    h = H[1] > nr ? H[1] : nr
    for (i = 1; i <= h; i++) print pad(cell(1, i)) "    " (i <= nr ? R[i] : "")
    if (k <= nc) print ""
  }
  for (; k <= nc; k += 2) {
    h = H[k] > H[k + 1] ? H[k] : H[k + 1]
    for (i = 1; i <= h; i++) print pad(cell(k, i)) "    " cell(k + 1, i)
    if (k + 2 <= nc) print ""
  }
}'
