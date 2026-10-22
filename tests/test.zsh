#!/usr/bin/env zsh
# ago 的测试：zsh tests/test.zsh
# 不依赖终端，直接调用内部函数检查结果

root=${0:A:h:h}
tmp=$(mktemp -d)
trap 'rm -rf $tmp' EXIT

integer pass=0 fail=0
ok()   { (( pass++ )); print -r -- "  ✓ $1" }
bad()  { (( fail++ )); print -r -- "  ✗ $1"; [[ -n $2 ]] && print -r -- "      $2" }
check() { # check 描述 实际值 期望值
  if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1" "期望 [$3]，实际 [$2]"; fi
}

# 测试用的历史：时间从旧到新。包含会被执行就会留下痕迹的命令替换
zmodload zsh/datetime
now=$EPOCHSECONDS
cat > $tmp/hist <<EOF
: $(( now - 400 * 86400 )):0;echo \$(touch $tmp/PWNED1)
: $(( now - 300 * 86400 )):0;ls \`touch $tmp/PWNED2\`
: $(( now - 200 * 86400 )):0;x[\$(touch $tmp/PWNED3)]=1
: $(( now - 100 * 86400 )):0;git status
: $(( now - 50 * 86400 )):0;git status
: $(( now - 40 * 86400 )):0;git push
: $(( now - 30 * 86400 )):0;sudo -E pnpm dev
: $(( now - 20 * 86400 )):0;FOO=1 npm test 2>&1 | grep ok
: $(( now - 10 * 86400 )):0;echo 中文命令
: $(( now - 60 )):0;ago git
EOF

HISTSIZE=1000
fc -R $tmp/hist
AGO_CONFIG=$tmp/conf/config   # 不碰真实的偏好设置
source $root/ago.zsh 2>/dev/null

print "加载"
_ago_load
check "去重后的命令数（不含 ago 自己）" $#_ago_cmds 8
check "最近一条" "${_ago_cmds[1]}" "echo 中文命令"
check "次数统计" "${_ago_counts[${_ago_cmds[(i)git status]}]}" 2

print "安全"
[[ -e $tmp/PWNED1 || -e $tmp/PWNED2 || -e $tmp/PWNED3 ]] \
  && bad "历史里的命令替换不会被执行" "$(ls $tmp | grep PWNED)" \
  || ok "历史里的命令替换不会被执行"

print "命令名"
_ago_name 'sudo -E pnpm dev'; check "跳过 sudo 和它的参数" "$REPLY" pnpm
_ago_name 'FOO=1 BAR=2 npm test'; check "跳过环境变量赋值" "$REPLY" npm
_ago_name '/usr/local/bin/git log'; check "只取路径最后一段" "$REPLY" git
_ago_name "PS1='a \$ '"; check "纯赋值没有命令名" "$REPLY" ""

print "排序"
first() { _ago_filter; REPLY=${_ago_cmds[${_ago_hits[1]}]} }
_ago_query=
_ago_sort=recent; first; check "最近" "$REPLY" "echo 中文命令"
_ago_sort=oldest; first; check "最远" "$REPLY" "echo \$(touch $tmp/PWNED1)"
_ago_sort=most;   first; check "最多" "$REPLY" "git status"
_ago_sort=least;  first; check "最少（次数相同按最近）" "$REPLY" "echo 中文命令"
_ago_sort=recent; _ago_cycle_sort 1; check "→ 切到下一个排序" $_ago_sort oldest
_ago_sort=recent; _ago_cycle_sort -1; check "← 从第一个绕到最后" $_ago_sort least

print "过滤"
_ago_sort=recent
_ago_query='git'; _ago_filter; check "子串匹配" $#_ago_hits 2
_ago_query='push git'; _ago_filter; check "多个词，顺序无关" "${_ago_cmds[${_ago_hits[1]}]}" "git push"
_ago_query='GIT'; _ago_filter; check "不区分大小写" $#_ago_hits 2
_ago_query='gps'; _ago_filter; check "模糊匹配" "${_ago_cmds[${_ago_hits[1]}]}" "git push"
_ago_query='中文'; _ago_filter; check "中文" $#_ago_hits 1
_ago_query='*'; _ago_filter; check "通配符按普通字符处理" $#_ago_hits 0
_ago_query='zzzz'; _ago_filter; check "无结果" $#_ago_hits 0

print "分组与导航"
_ago_query=; _ago_mode=group; _ago_sort=most; _ago_filter
check "第一项固定是「全部」" "${_ago_hits[1]}" 0
check "按次数最多的分组" "${_ago_gnames[${_ago_hits[2]}]}" git
check "分组次数" "${_ago_gcounts[${_ago_hits[2]}]}" 3
_ago_query=gi; _ago_filter; check "搜索分组时不显示「全部」" "${_ago_gnames[${_ago_hits[1]}]}" git
_ago_query=; _ago_filter; _ago_sel=2; _ago_enter
check "→ 进入 git 组" "$_ago_mode $_ago_group $#_ago_hits" "list git 2"
_ago_back
check "← 回到分组列表" $_ago_mode group
check "← 后选中刚才的组" "${_ago_gnames[${_ago_hits[_ago_sel]}]}" git
_ago_sel=1; _ago_enter
check "→ 进入「全部」" "$_ago_mode [$_ago_group] $#_ago_hits" "list [] 8"
_ago_back; check "从「全部」返回时选中第一项" $_ago_sel 1
_ago_mode=list; _ago_group=; _ago_sort=recent

print "界面"
COLUMNS=60 BUFFER=git PREDISPLAY=
_ago_styles; strftime -s _ago_today '%Y%m%d' $EPOCHSECONDS
_ago_rows=5 _ago_query=git _ago_sort=recent; _ago_filter; _ago_render
[[ $POSTDISPLAY == *'➤'*'git push'* ]] && ok "选中行有 ➤ 标记" || bad "选中行有 ➤ 标记" "$POSTDISPLAY"
[[ $POSTDISPLAY == *'Esc 退出'* ]] && ok "底部有按键提示" || bad "底部有按键提示"
[[ ${(j:|:)region_highlight} == *fg=yellow* ]] && ok "关键词高亮" || bad "关键词高亮"
[[ $POSTDISPLAY != *个月前* ]] && ok "默认不显示时间" || bad "默认不显示时间" "$POSTDISPLAY"
_ago_show_time=1; _ago_render
[[ $POSTDISPLAY == *个月前* ]] && ok "打开后显示时间" || bad "打开后显示时间" "$POSTDISPLAY"
_ago_show_time=0
_ago_when ${_ago_cmds[(i)echo 中文命令]}; check "相对时间" "${REPLY%% *}" "1周前"

print "偏好设置"
_ago_sort=most _ago_show_time=1; _ago_prefs_save
_ago_sort=recent _ago_show_time=0; _ago_prefs_load
check "保存后能读回" "$_ago_sort $_ago_show_time" "most 1"
print -r -- "sort=\$(touch $tmp/PWNED4)
time=\`touch $tmp/PWNED5\`
sort=bogus" > $tmp/conf/config
_ago_sort=recent _ago_show_time=0; _ago_prefs_load
[[ -e $tmp/PWNED4 || -e $tmp/PWNED5 ]] && bad "配置文件里的命令不会被执行" || ok "配置文件里的命令不会被执行"
check "非法的值被忽略" "$_ago_sort $_ago_show_time" "recent 0"

print "统计报表"
out=$(zsh $root/ago-stats.zsh -f $tmp/hist -n 20 -k 3)
[[ $out == *git*3* ]] && ok "git 计 3 次" || bad "git 计 3 次" "$out"
[[ $out == *grep* ]] && ok "管道后的命令也统计" || bad "管道后的命令也统计"
[[ $out != *' 1. 1 '* && $out != *$'\n'' '<->'. 1 '* ]] && ok "2>&1 不会被拆开" || bad "2>&1 不会被拆开"

print "安装"
zd=$tmp/zd; mkdir -p $zd; print 'export A=1' > $zd/.zshrc
ZDOTDIR=$zd sh $root/install.sh >/dev/null
ZDOTDIR=$zd sh $root/install.sh >/dev/null
check "重复安装只加一行" "$(grep -c ago-install $zd/.zshrc)" 1
ZDOTDIR=$zd sh $root/install.sh --uninstall >/dev/null
check "卸载后恢复原样" "$(cat $zd/.zshrc)" 'export A=1'

print
if (( fail )); then
  print "失败 $fail 项，通过 $pass 项"
  exit 1
fi
print "全部通过（$pass 项）"
