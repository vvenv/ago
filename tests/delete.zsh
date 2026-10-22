# 删除历史的测试，在真实的交互 zsh 里、从 ZLE 小部件中运行（和用户按键删除时的环境一样）。
# 由 tests/delete_pty.py 驱动：
#   1. 在提示符下 source 本文件：准备测试用的历史文件并载入
#   2. 按 Ctrl-X Ctrl-T：小部件 _t_run 依次执行删除和检查，结果写到 $tmp/log
# log 每行是 "ok 描述" 或 "bad 描述 | 详情"，最后一行是 "done"

_t_root=$1 _t_tmp=$2
setopt extendedhistory
unsetopt sharehistory incappendhistory

# 测试用的历史文件 $tmp/h 由 delete_pty.py 按 zsh 的格式生成（非 ASCII 字符中的部分字节会被转义）

HISTFILE=$_t_tmp/h HISTSIZE=1000 SAVEHIST=1000
fc -R
AGO_CONFIG=$_t_tmp/conf/config
source $_t_root/ago.zsh 2>/dev/null

_t_run() {
  local t=$_t_tmp log=$_t_tmp/log
  ok()  { print -r -- "ok $1" >> $log }
  bad() { print -r -- "bad $1 | $2" >> $log }
  check() { [[ $2 == "$3" ]] && ok "$1" || bad "$1" "期望 [$3]，实际 [$2]" }
  has() { [[ -n ${(M)${(v)history}:#$1} ]] }   # 内存历史里有没有这条命令（精确比较）
  infile() { [[ $(<$t/h) == *$1* ]] }          # 历史文件里有没有这段字节

  _ago_hist_delete "git push origin main"
  check "删除重复命令的所有记录" "$REPLY" 2
  has "git push origin main" && bad "内存里不再有" || ok "内存里不再有"
  infile "git push" && bad "文件里不再有" || ok "文件里不再有"
  [[ $(<$t/h.ago-bak) == "$(<$t/h.orig)"* ]] && ok "删除前做了备份" || bad "删除前做了备份"
  infile ": 1700000000:0;echo keep1" && ok "保留的记录原样不变（含时间戳）" || bad "保留的记录原样不变（含时间戳）"
  has "echo 中文 保留 七" && ok "其它中文命令保留（含转义字节）" || bad "其它中文命令保留（含转义字节）" "${(j:|:)${(@v)history}}"

  _ago_hist_delete "echo 中文 删除" $'cat <<X\n多行 七\nX'
  check "删除中文和多行命令（含转义字节）" "$REPLY" 2
  has "echo 中文 删除" && bad "中文命令已删除" || ok "中文命令已删除"
  has "echo 中文 保留 七" && ok "相似的中文命令不受影响" || bad "相似的中文命令不受影响"
  local kept=${(M)${(f)"$(<$t/h.orig)"}:#: 1700000600:*}   # 按时间戳找到那条中文记录的原始字节
  [[ -n $kept ]] && infile "$kept" && ok "文件里中文记录的字节原样保留" || bad "文件里中文记录的字节原样保留"

  _ago_hist_delete "ls *.txt | grep (a)" "echo \$(touch $t/PWNED6)"
  check "删除含通配符和命令替换的命令" "$REPLY" 2
  [[ -e $t/PWNED6 ]] && bad "删除时不执行命令内容" || ok "删除时不执行命令内容"

  _ago_hist_delete "echo last"
  check "删除最近一条" "$REPLY" 1
  has "echo last" && bad "最近一条不会残留在内存" || ok "最近一条不会残留在内存"
  infile "echo last" && bad "最近一条从文件删除" || ok "最近一条从文件删除"
  # 文件里行尾的反斜杠是换行标记，不属于命令本身；下一行末尾的空白会被 zsh 去掉
  has $'curl -H \'a: b\' \n  -d x \\' && ok "末尾带空格的续行命令保留" || bad "末尾带空格的续行命令保留" "${(qq)${(@v)history}}"
  has "echo keep1" && ok "其它命令仍在内存" || bad "其它命令仍在内存"

  local -a same=(${(M)${(@v)history}:#echo keep1})
  check "内存里没有重复的记录" $#same 1
  local recent=${history[${${(@Onk)history}[1]}]}
  _ago_hist_delete "$recent"
  check "删除刚刚执行过的命令" "$REPLY" 1
  has "$recent" && bad "刚执行过的命令不会残留在内存" || ok "刚执行过的命令不会残留在内存"
  has "echo keep1" && ok "删除后其它命令还在" || bad "删除后其它命令还在"

  cp $t/h $t/h.before
  _ago_hist_delete "不存在的命令"
  check "删除不存在的命令时报告失败" "$?:$REPLY" "1:没有找到要删除的记录"
  [[ $(<$t/h) == "$(<$t/h.before)" ]] && ok "失败时文件不变" || bad "失败时文件不变"

  print -r -- done >> $log
  zle -M "测试完成"
}
zle -N _t_run
bindkey '^X^T' _t_run
