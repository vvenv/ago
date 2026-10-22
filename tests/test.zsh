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
_ago_name 'clear; ls'; check "去掉紧跟的分号" "$REPLY" clear
_ago_name "PS1='a \$ '"; check "纯赋值没有命令名" "$REPLY" ""

print "排序（总是按最近）"
_ago_mode=list _ago_group=git _ago_query=; _ago_filter
check "组内按最近使用" "${_ago_cmds[${_ago_hits[1]}]} | ${_ago_cmds[${_ago_hits[2]}]}" "git push | git status"
_ago_mode=group _ago_query=; _ago_filter
check "分组按最近使用" "${_ago_gnames[${_ago_hits[1]}]} ${_ago_gnames[${_ago_hits[2]}]}" "echo npm"

print "过滤"
inlist() { _ago_mode=list _ago_group=$1 _ago_query=$2; _ago_filter }
inlist git git; check "子串匹配" $#_ago_hits 2
inlist git 'push git'; check "多个词，顺序无关" "${_ago_cmds[${_ago_hits[1]}]}" "git push"
inlist git 'GIT'; check "不区分大小写" $#_ago_hits 2
inlist git 'gps'; check "模糊匹配" "${_ago_cmds[${_ago_hits[1]}]}" "git push"
inlist echo '中文'; check "中文" $#_ago_hits 1
inlist git '*'; check "通配符按普通字符处理" $#_ago_hits 0
inlist git 'zzzz'; check "无结果" $#_ago_hits 0

print "分组与导航"
_ago_mode=group _ago_group= _ago_query=; _ago_filter
check "打开就是分组列表，没有「全部」" "${_ago_hits[1]}" 1
check "分组次数" "${_ago_hcounts[${_ago_hits[(i)${_ago_gidx[git]}]}]}" 3
check "取不到命令名的归到（其他）" "${+_ago_gidx[(其他)]}" 1
_ago_query=status; _ago_filter
# 只看第一项：子串匹配排在前面；临时目录名是随机的，可能被模糊匹配到，不能断言总数
check "分组列表里搜索的是命令" "${_ago_gnames[${_ago_hits[1]}]}" "git"
check "次数只算匹配的命令" "${_ago_hcounts[1]}" 2
check "提示该组第一条匹配的命令" "${_ago_cmds[${_ago_hfirst[1]}]}" "git status"
_ago_query=; _ago_filter
_ago_sel=${_ago_hits[(i)${_ago_gidx[git]}]}; _ago_enter
check "→ 进入 git 组" "$_ago_mode $_ago_group $#_ago_hits" "list git 2"
_ago_query=push; _ago_filter
_ago_back
check "← 回到分组列表" $_ago_mode group
check "← 后关键词保留" $_ago_query push
check "← 后选中刚才的组" "${_ago_gnames[${_ago_hits[_ago_sel]}]}" git
_ago_enter
check "带关键词进入，只列匹配的命令" "$#_ago_hits ${_ago_cmds[${_ago_hits[1]}]}" "1 git push"
_ago_mode=group _ago_group= _ago_query=

print "界面"
COLUMNS=60 BUFFER=git PREDISPLAY=
_ago_styles; strftime -s _ago_yesterday '%Y%m%d' $(( EPOCHSECONDS - 86400 ))
_ago_rows=5 _ago_mode=list _ago_group=git _ago_query=git; _ago_filter; _ago_render
[[ $POSTDISPLAY == *'➤'*'git push'* ]] && ok "选中行有 ➤ 标记" || bad "选中行有 ➤ 标记" "$POSTDISPLAY"
[[ $POSTDISPLAY == *'esc 退出'* ]] && ok "底部有按键提示" || bad "底部有按键提示"
title=${${(f)POSTDISPLAY}[1]}
[[ $title == ago*git*' · '<-> && $title != *(分组|条|个)* ]] && ok "标题只有组名和数量" || bad "标题只有组名和数量" "$title"
[[ ${(j:|:)region_highlight} == *fg=yellow* ]] && ok "关键词高亮" || bad "关键词高亮"
[[ $POSTDISPLAY != *个月前* ]] && ok "默认不显示时间" || bad "默认不显示时间" "$POSTDISPLAY"
_ago_show_time=1; _ago_render
[[ $POSTDISPLAY == *个月前* ]] && ok "打开后显示时间" || bad "打开后显示时间" "$POSTDISPLAY"
_ago_show_time=0
_ago_render
[[ ${${(f)POSTDISPLAY}[2]} == '➤ git push' ]] && ok "默认不显示次数" || bad "默认不显示次数" "${${(f)POSTDISPLAY}[2]}"
[[ $POSTDISPLAY == *'^O 次数'* ]] && ok "底部提示 ^O 次数" || bad "底部提示 ^O 次数"
_ago_show_count=1; _ago_render
[[ ${${(f)POSTDISPLAY}[2]} == '➤     1  git push' ]] && ok "打开后显示次数" || bad "打开后显示次数" "${${(f)POSTDISPLAY}[2]}"
_ago_show_time=1; _ago_render
[[ ${${(f)POSTDISPLAY}[2]} == '➤     1  '*个月前*'git push' ]] && ok "次数和时间可以同时显示" || bad "次数和时间可以同时显示" "${${(f)POSTDISPLAY}[2]}"
_ago_show_time=0 _ago_show_count=0
_ago_when ${_ago_cmds[(i)echo 中文命令]}; check "相对时间" "${REPLY%% *}" "1周前"
rel() { _ago_reltime $(( EPOCHSECONDS - $1 )); print -r -- $REPLY }
check "1 分钟内显示秒" "$(rel 5) $(rel 59)" "5秒前 59秒前"
check "1 小时内显示分钟" "$(rel 60) $(rel 3599)" "1分钟前 59分钟前"
check "24 小时内显示小时" "$(rel 3600) $(rel 86399)" "1小时前 23小时前"
check "超过 24 小时按天算" "$(rel $(( 3 * 86400 )))" "3天前"
check "未来的时间（时钟误差）显示 1 秒前" "$(rel -30)" "1秒前"

print "偏好设置"
_ago_show_time=1 _ago_show_count=1; _ago_prefs_save
_ago_show_time=0 _ago_show_count=0; _ago_prefs_load
check "保存后能读回" "$_ago_show_time $_ago_show_count" "1 1"
print -r -- "sort=most
time=\$(touch $tmp/PWNED4)
time=\`touch $tmp/PWNED5\`
count=yes" > $tmp/conf/config
_ago_show_time=0 _ago_show_count=0; _ago_prefs_load
[[ -e $tmp/PWNED4 || -e $tmp/PWNED5 ]] && bad "配置文件里的命令不会被执行" || ok "配置文件里的命令不会被执行"
check "非法的值和旧的 sort 项被忽略" "$_ago_show_time $_ago_show_count" "0 0"

print "删除确认"
_ago_mode=list _ago_group=git _ago_query=; _ago_filter; _ago_sel=1
_ago_ask_delete
check "组里删除一条命令" "${#_ago_del} ${_ago_del[1]}" "1 git push"
[[ $_ago_ask == *"git push"*"1 条历史"* ]] && ok "确认提示写明命令和条数" || bad "确认提示写明命令和条数" "$_ago_ask"
COLUMNS=80; _ago_render
[[ $POSTDISPLAY == *'y 确认删除'* ]] && ok "确认时底部显示 y 确认删除" || bad "确认时底部显示 y 确认删除" "$POSTDISPLAY"
[[ ${(j:|:)region_highlight} == *fg=red* ]] && ok "确认时用红色提示" || bad "确认时用红色提示"
_ago_ask= _ago_del=()
_ago_mode=group _ago_group= _ago_query=; _ago_filter
_ago_sel=${_ago_hits[(i)${_ago_gidx[git]}]}; _ago_ask_delete
check "分组列表里删除整组" "${#_ago_del} ${(j:,:)${(@o)_ago_del}}" "2 git push,git status"
[[ $_ago_ask == *"git 整组 2 条命令"*"3 条历史"* ]] && ok "整组确认提示" || bad "整组确认提示" "$_ago_ask"
check "确认前不改变选中项" "${_ago_gnames[${_ago_hits[_ago_sel]}]}" git
_ago_query=status; _ago_filter; _ago_sel=1; _ago_ask_delete
check "有关键词时只删匹配的命令" "${(j:,:)_ago_del}" "git status"
[[ $_ago_ask == *"匹配的 1 条命令"* ]] && ok "有关键词时提示「匹配的」" || bad "有关键词时提示「匹配的」" "$_ago_ask"
_ago_ask= _ago_del=() _ago_query=; _ago_filter

print "删除历史（在交互 shell 里运行）"
if (( $+commands[python3] )); then
  mkdir -p $tmp/dp
  for line in "${(@f)$(python3 -I $root/tests/delete_pty.py $root $tmp/dp)}"; do
    case $line in
      ok\ *)  ok "${line#ok }" ;;
      bad\ *) bad "${line#bad }" ;;
    esac
  done
else
  print "  - 没有 python3，跳过"
fi

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
