# ago — 零依赖的 zsh 历史命令搜索：模糊搜索、选择、编辑、回车执行
#
# 安装：./install.sh（会在 ~/.zshrc 里加一行 source）
# 使用：按 Ctrl-R，或输入 ago [关键词]；统计报表：ago stats
#
# 打开后先看到按命令名分组的列表（git、pnpm…），按最近使用排序：
#   输入        搜索命令（空格分隔多个词，先按子串匹配，再按模糊匹配）
#   ↑ ↓         选择（也可用 Ctrl-P / Ctrl-N；PgUp / PgDn 翻页）
#   → / 回车    进入选中的组
#   ←           返回分组列表
#   回车        在组里：把选中的命令放到命令行，可以继续编辑，再回车执行
#   退格 / Del  删除选中的命令或整组（关键词为空时用退格；需要按 y 确认）
#   Ctrl-T      显示 / 隐藏最后使用时间（会保存到 ~/.config/ago/config）
#   esc         取消（Ctrl-G 同样）
#
# 安全说明：命令文本只作为字符串处理，绝不放进 (( )) 或 eval，
# 否则历史里的 $(...) 会被执行。

# 可在 source 之前设置：
#   AGO_KEY=...    打开搜索的快捷键（默认 ^R，即 Ctrl-R）
#   AGO_NO_BIND=1  不绑定快捷键，只用 ago 命令
#   NO_COLOR=1     不使用颜色
#   AGO_CONFIG=... 偏好设置文件（默认 ${XDG_CONFIG_HOME:-~/.config}/ago/config）

zmodload zsh/parameter zsh/datetime

typeset -g _ago_dir=${${(%):-%x}:A:h}   # 本文件所在目录
typeset -g _ago_version=0.5.0
typeset -gi _ago_pending=0
typeset -g _ago_initq=

# 命令（按最近使用排列）
typeset -ga _ago_cmds _ago_lower _ago_counts _ago_names _ago_evts
# 分组（按组内最近一次使用排列）
typeset -ga _ago_gnames _ago_gcounts _ago_gfirst
typeset -gA _ago_gidx   # 组名 → 分组下标
# 当前显示的行：命令下标或分组下标；分组时还有该组的次数和第一条匹配的命令
typeset -ga _ago_hits _ago_hcounts _ago_hfirst
typeset -gA _ago_tmap   # 事件号 → 时间戳，懒加载缓存
typeset -gA _ago_st     # 界面样式
typeset -ga _ago_terms _ago_rh
typeset -g  _ago_out= _ago_today= _ago_yesterday=
typeset -gi _ago_base=0
typeset -g  _ago_cache_key= _ago_query= _ago_group= _ago_mode=group
typeset -gi _ago_sel=1 _ago_top=1 _ago_rows=10 _ago_show_time=0
typeset -g  _ago_conf=${AGO_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/ago/config}
typeset -g  _ago_other='(其他)'   # 取不到命令名的历史归到这一组
typeset -ga _ago_del          # 等待确认删除的命令
typeset -g  _ago_ask= _ago_msg= _ago_msg_style=   # 确认提示 / 操作结果提示

# 取命令名：跳过 FOO=bar、sudo 之类的前缀。结果放在 REPLY
_ago_name() {
  local -a w
  local x prefixed=0
  w=(${=${1[1,300]}})   # 只按空白拆分，不会求值或展开通配符
  for x in $w; do
    [[ $x == [A-Za-z_]*=* ]] && continue
    [[ $x == (sudo|time|nohup|env|exec|command|builtin|noglob|nice) ]] && { prefixed=1; continue }
    (( prefixed )) && [[ $x == -* ]] && continue
    REPLY=${${x:t}%%[;|&]*}   # 去掉紧跟的 ; | &，例如 "clear;" → clear
    # 只接受像命令名的词，排除引号、括号等碎片
    [[ $REPLY == [A-Za-z0-9_.~+@]* && $REPLY != *[\'\"\(\)\$\`]* ]] || REPLY=
    return
  done
  REPLY=
}

# 从 $history 统计。命令和分组都按最近使用排列
_ago_load() {
  local key="$HISTCMD:${#history}"
  [[ $key == $_ago_cache_key ]] && return
  _ago_cache_key=$key

  local -A cnt
  local -a order evt
  local k c
  local -i n i j
  for k in ${(Onk)history}; do        # 从新到旧
    c=${history[$k]}
    n=${cnt[$c]:-0}
    (( n )) || { order+=("$c"); evt+=($k) }
    cnt[$c]=$(( n + 1 ))
  done

  _ago_cmds=() _ago_lower=() _ago_counts=() _ago_names=() _ago_evts=()
  _ago_gnames=() _ago_gcounts=() _ago_gfirst=() _ago_gidx=()
  for (( i = 1; i <= $#order; i++ )); do
    c=${order[i]}
    n=${cnt[$c]}
    _ago_name "$c"
    [[ $REPLY == ago ]] && continue   # 不列出 ago 自己的调用
    [[ -z $REPLY ]] && REPLY=$_ago_other
    _ago_cmds+=("$c")
    _ago_lower+=("${(L)c}")
    _ago_counts+=($n)
    _ago_names+=("$REPLY")
    _ago_evts+=(${evt[i]})
    if [[ -z ${_ago_gidx[$REPLY]} ]]; then
      _ago_gnames+=("$REPLY")
      _ago_gcounts+=(0)
      _ago_gfirst+=($#_ago_cmds)   # 该组最近一条命令的下标
      _ago_gidx[$REPLY]=$#_ago_gnames
    fi
    j=${_ago_gidx[$REPLY]}
    _ago_gcounts[j]=$(( _ago_gcounts[j] + n ))
  done
}

# 按关键词过滤，结果放在 _ago_hits。
# 命令列表：当前组里匹配的命令。分组列表：含有匹配命令的组，次数是这些命令的次数之和。
# 子串匹配排在模糊匹配前面，各自再按最近使用排序
_ago_filter() {
  local -a terms fpats sub fuz gsum gfirst
  local t ch pat
  local -i i j ok
  terms=(${=${(L)_ago_query}})
  _ago_terms=($terms)
  _ago_hits=() _ago_hcounts=() _ago_hfirst=()
  _ago_sel=1 _ago_top=1

  if [[ $_ago_mode == group && -z $terms ]]; then
    _ago_hits=({1..$#_ago_gnames}) _ago_hcounts=($_ago_gcounts) _ago_hfirst=($_ago_gfirst)
    (( $#_ago_gnames )) || _ago_hits=()
    return
  fi

  # 每个词的模糊模式：git → *g*i*t*
  for t in $terms; do
    pat='*'
    for ch in ${(s::)t}; do pat+="${(b)ch}*"; done
    fpats+=("$pat")
  done

  for (( i = 1; i <= $#_ago_cmds; i++ )); do
    [[ $_ago_mode == list && ${_ago_names[i]} != "$_ago_group" ]] && continue
    ok=1
    for t in $terms; do [[ ${_ago_lower[i]} == *${(b)t}* ]] || { ok=0; break }; done
    if (( ok )); then sub+=($i); continue; fi
    ok=1
    for pat in $fpats; do [[ ${_ago_lower[i]} == ${~pat} ]] || { ok=0; break }; done
    (( ok )) && fuz+=($i)
  done

  if [[ $_ago_mode == list ]]; then
    _ago_hits=($sub $fuz)
    return
  fi

  for i in $sub $fuz; do
    j=${_ago_gidx[${_ago_names[i]}]}
    if (( ! gsum[j] )); then
      _ago_hits+=($j)
      gfirst[j]=$i
    fi
    gsum[j]=$(( gsum[j] + _ago_counts[i] ))
  done
  for j in $_ago_hits; do
    _ago_hcounts+=(${gsum[j]})
    _ago_hfirst+=(${gfirst[j]})
  done
}

# 截断到指定显示宽度（中文算 2 列）
_ago_fit() {
  local s=$1
  while [[ $s == *[[:space:]] ]]; do s=${s[1,-2]}; done   # 去掉结尾的换行和空格
  s=${s//$'\n'/↵}
  s=${s//$'\t'/ }
  local -i w=$2
  (( w < 2 )) && w=2
  if (( ${(m)#s} > w )); then
    s=${s[1,w]}
    while (( ${(m)#s} > w - 1 )); do s=${s[1,-2]}; done
    s+='…'
  fi
  REPLY=$s
}

# 第 $1 条命令最后一次使用的相对时间（今天 / 3天前 / 2个月前），放在 REPLY，补齐到 8 列。
# 只查屏幕上显示的行，查过就缓存
_ago_when() {
  local -i e=${_ago_evts[$1]} t d
  local line day
  local -a w
  if [[ -z ${_ago_tmap[$e]} ]]; then
    line="$(fc -lt '%s' $e $e 2>/dev/null)"
    line=${line%%$'\n'*}
    w=(${=line[1,40]})   # 只取 "事件号 时间戳" 两个字段
    [[ ${w[2]} == <-> ]] && _ago_tmap[$e]=${w[2]} || _ago_tmap[$e]=0
  fi
  t=${_ago_tmap[$e]}
  if (( t == 0 )); then
    REPLY=
  else
    strftime -s day '%Y%m%d' $t
    d=$(( (EPOCHSECONDS - t) / 86400 ))
    if   [[ $day == $_ago_today ]];     then REPLY=今天
    elif [[ $day == $_ago_yesterday ]]; then REPLY=昨天
    elif (( d < 7 ));   then REPLY="$(( d > 1 ? d : 2 ))天前"
    elif (( d < 30 ));  then REPLY="$(( d / 7 ))周前"
    elif (( d < 365 )); then REPLY="$(( d / 30 ))个月前"
    else                     REPLY="$(( d / 365 ))年前"
    fi
  fi
  while (( ${(m)#REPLY} < 8 )); do REPLY+=' '; done
}

# 颜色。设置 NO_COLOR 时只用反色和下划线
_ago_styles() {
  if [[ -n $NO_COLOR ]]; then
    _ago_st=(brand bold dim '' sel standout match underline prompt bold warn 'bold,underline' ok bold)
  else
    _ago_st=(brand 'fg=magenta,bold' dim 'fg=8' sel 'fg=cyan,bold' match 'fg=yellow,bold' prompt 'fg=yellow'
             warn 'fg=red,bold' ok 'fg=green')
  fi
}

# 往界面追加一段文字，$2 是样式（可为空）。位置按字符计，从 BUFFER 开头算起
_ago_put() {
  [[ -n $2 ]] && _ago_rh+=("$(( _ago_base + ${#_ago_out} )) $(( _ago_base + ${#_ago_out} + ${#1} )) $2")
  _ago_out+=$1
}

# 高亮文本 $1 里命中关键词的位置，$2 是这段文本在界面中的起始位置
_ago_mark() {
  [[ -n ${_ago_st[match]} ]] || return
  local s=${(L)1} t ch
  local -i p q k len=${#1}
  for t in $_ago_terms; do
    p=${s[(i)${(b)t}]}
    if (( p <= len )); then
      while (( p <= len )); do
        _ago_rh+=("$(( $2 + p - 1 )) $(( $2 + p - 1 + ${#t} )) ${_ago_st[match]}")
        p=${s[(ib:p+${#t}:)${(b)t}]}
      done
    else
      # 模糊匹配：依次找每个字符
      q=1
      for ch in ${(s::)t}; do
        k=${s[(ib:q:)${(b)ch}]}
        (( k > len )) && break
        _ago_rh+=("$(( $2 + k - 1 )) $(( $2 + k )) ${_ago_st[match]}")
        q=k+1
      done
    fi
  done
}

_ago_render() {
  local -i n=$#_ago_hits i j f w=$(( COLUMNS - (_ago_show_time ? 21 : 11) )) gw=0
  local cnt when name hint seg line style
  local -a segs
  _ago_out= _ago_rh=() _ago_base=${#BUFFER}

  (( _ago_sel > n )) && _ago_sel=n
  (( _ago_sel < 1 )) && _ago_sel=1
  (( _ago_sel < _ago_top )) && _ago_top=_ago_sel
  (( _ago_sel >= _ago_top + _ago_rows )) && _ago_top=$(( _ago_sel - _ago_rows + 1 ))

  # 标题行
  _ago_put $'\n'
  _ago_put ago ${_ago_st[brand]}
  if [[ $_ago_mode == group ]]; then
    _ago_put "  $n" ${_ago_st[dim]}
  else
    _ago_put '  '
    _ago_put "$_ago_group" ${_ago_st[sel]}
    _ago_put " · $n" ${_ago_st[dim]}
  fi

  # 分组列表里有关键词时，命令提示对齐成一列（组名最多按 16 列算）
  if [[ $_ago_mode == group && -n $_ago_terms ]]; then
    for (( j = _ago_top; j < _ago_top + _ago_rows && j <= n; j++ )); do
      name=${_ago_gnames[${_ago_hits[j]}]}
      (( ${(m)#name} > gw )) && gw=${(m)#name}
    done
    (( gw > 16 )) && gw=16
  fi

  # 列表
  for (( j = _ago_top; j < _ago_top + _ago_rows && j <= n; j++ )); do
    i=${_ago_hits[j]}
    when= hint=
    if [[ $_ago_mode == group ]]; then
      cnt=${_ago_hcounts[j]} f=${_ago_hfirst[j]}
      _ago_fit "${_ago_gnames[i]}" $w; name=$REPLY
      # 有关键词时，在组名后面提示该组最近一条匹配的命令
      if (( gw )) && (( w - gw > 12 )); then
        _ago_fit "${_ago_cmds[f]}" $(( w - gw - 3 )); hint=$REPLY
        while (( ${(m)#name} < gw )); do name+=' '; done
      fi
    else
      cnt=${_ago_counts[i]} f=$i
      _ago_fit "${_ago_cmds[i]}" $w; name=$REPLY
    fi
    if (( _ago_show_time )); then _ago_when $f; when="$REPLY  "; fi
    _ago_put $'\n'
    if (( j == _ago_sel )); then
      style=${_ago_st[sel]}
      [[ -n $_ago_ask ]] && style=${_ago_st[warn]}
      _ago_put "➤ ${(l:5:)cnt}  $when" $style
      _ago_put "$name" $style
    else
      _ago_put '  '
      _ago_put "${(l:5:)cnt}  $when" ${_ago_st[dim]}
      _ago_put "$name"
    fi
    _ago_mark "$name" $(( _ago_base + ${#_ago_out} - ${#name} ))
    if [[ -n $hint ]]; then
      _ago_put "   $hint" ${_ago_st[dim]}
      _ago_mark "$hint" $(( _ago_base + ${#_ago_out} - ${#hint} ))
    fi
  done
  if (( n == 0 )); then
    _ago_put $'\n'
    _ago_put "  没有匹配的命令" ${_ago_st[dim]}
  fi

  # 底部：确认删除 / 操作结果 / 按键提示（随状态变化，宽度不够时在分隔符处换行）
  if [[ -n $_ago_ask ]]; then
    _ago_fit "$_ago_ask" $(( COLUMNS - 1 ))
    _ago_put $'\n'; _ago_put "$REPLY" ${_ago_st[warn]}
    segs=("y 确认删除" "其它键取消")
  else
    if [[ -n $_ago_msg ]]; then
      _ago_fit "$_ago_msg" $(( COLUMNS - 1 ))
      _ago_put $'\n'; _ago_put "$REPLY" ${_ago_st[$_ago_msg_style]}
    fi
    (( n > _ago_rows )) && segs+=("$_ago_sel/$n")
    segs+=("↑↓ 选择")
    if [[ $_ago_mode == group ]]; then
      segs+=("→ 进入")
    else
      segs+=("← 返回" "Enter 编辑")
    fi
    (( n )) && segs+=("${${_ago_query:+Del}:-⌫} 删除")
    segs+=("^T 时间")
    [[ -n $_ago_query ]] && segs+=("^U 清空")
    segs+=("esc 退出")
  fi
  line=
  for seg in $segs; do
    if [[ -n $line ]] && (( ${(m)#line} + 3 + ${(m)#seg} > COLUMNS - 1 )); then
      _ago_put $'\n'; _ago_put "$line" ${_ago_st[dim]}
      line=
    fi
    line+=${line:+ | }$seg
  done
  _ago_put $'\n'; _ago_put "$line" ${_ago_st[dim]}

  POSTDISPLAY=$_ago_out
  region_highlight=("${_ago_saved_rh[@]}" "P0 ${#PREDISPLAY} ${_ago_st[prompt]}" "${_ago_rh[@]}")
}

# → / 回车：进入选中的组。关键词保留，组里只列出匹配的命令
_ago_enter() {
  [[ $_ago_mode == group ]] && (( $#_ago_hits )) || return
  _ago_group=${_ago_gnames[${_ago_hits[_ago_sel]}]}
  _ago_mode=list
  _ago_filter
}

# ←：返回分组列表，并选中刚才所在的组
_ago_back() {
  [[ $_ago_mode == list ]] || return
  local g=$_ago_group
  local -i j
  _ago_mode=group _ago_group=
  _ago_filter
  for (( j = 1; j <= $#_ago_hits; j++ )); do
    [[ ${_ago_gnames[${_ago_hits[j]}]} == "$g" ]] && { _ago_sel=j; return }
  done
}

# 准备删除选中的行：在组里是这条命令，在分组列表里是整组（有关键词时只算匹配的命令）。
# 要删的命令放进 _ago_del，确认提示放进 _ago_ask
_ago_ask_delete() {
  (( $#_ago_hits )) || return
  local -i i=${_ago_hits[_ago_sel]} total=0 sel=$_ago_sel
  local g
  _ago_del=()
  if [[ $_ago_mode == list ]]; then
    _ago_del=("${_ago_cmds[i]}")
    _ago_fit "${_ago_cmds[i]}" 40
    _ago_ask="删除「$REPLY」的全部 ${_ago_counts[i]} 条历史？"
    return
  fi
  g=${_ago_gnames[i]}
  # 借用命令列表的过滤，取出这一组里（匹配的）命令
  _ago_mode=list _ago_group=$g
  _ago_filter
  for i in $_ago_hits; do
    _ago_del+=("${_ago_cmds[i]}")
    (( total += _ago_counts[i] ))
  done
  _ago_mode=group _ago_group=
  _ago_filter
  _ago_sel=sel
  if [[ -n $_ago_terms ]]; then
    _ago_ask="删除 $g 组中匹配的 $#_ago_del 条命令（共 $total 条历史）？"
  else
    _ago_ask="删除 $g 整组 $#_ago_del 条命令（共 $total 条历史）？"
  fi
}

# 从历史里删除参数中的命令（每条的所有出现），同时更新历史文件和当前 shell 的历史。
# 做法：先把还没保存的历史写进 $HISTFILE；把文件按记录拆开（原样保留字节，不碰 zsh 对
# 非 ASCII 字符的内部编码）；再用一个临时的独立历史列表读这些记录，得到每条记录的命令文本，
# 据此决定删除哪些记录；写回文件，最后重新载入当前 shell 的历史。
# zsh 会把最后读入的一条当作"当前行"而不放进 $history，所以读的时候在末尾多放一条哨兵。
# 写回前先备份到 $HISTFILE.ago-bak。成功时 REPLY 是删除的条数；失败时什么都不改，REPLY 是原因
_ago_hist_delete() {
  local f=$HISTFILE tmp=${TMPDIR:-/tmp}/ago-hist.$$.$RANDOM line cur text body t
  local -A del
  local -a raw recs keep texts
  local -i cont=0 R i removed=0 hs n0
  for text in "$@"; do del[$text]=1; done

  [[ -n $f ]] || { REPLY="没有设置 HISTFILE，无法删除"; return 1 }
  [[ -w $f ]] || { REPLY="无法写入 $f"; return 1 }
  fc -AI $f 2>/dev/null   # 把内存里还没保存的历史先写进文件

  # 拆成记录：和 zsh 读历史的规则一样，以反斜杠结尾的行和下一行属于同一条
  raw=("${(@f)$(<$f)}")
  for line in "${raw[@]}"; do
    if (( cont )); then cur+=$'\n'$line; else cur=$line; fi
    if [[ $line == *\\ ]]; then cont=1; else cont=0; recs+=("$cur"); fi
  done
  (( cont )) && recs+=("$cur")
  R=$#recs
  (( R )) || { REPLY="历史文件是空的"; return 1 }

  # 用独立的历史列表读这些记录（末尾加哨兵）；读的时候关掉会丢记录的去重选项
  print -r -l -- "${recs[@]}" ': 0:0;__ago_sentinel__' >| $tmp.in || { REPLY="无法写临时文件"; return 1 }
  fc -p $tmp $(( R + 10 )) $(( R + 10 ))
  {
    setopt localoptions nohistignoredups nohistignorealldups nohistsavenodups
    fc -R $tmp.in
    for i in ${(onk)history}; do texts+=("${history[$i]}"); done
  } always {
    fc -P
    command rm -f -- $tmp $tmp.in
  }
  [[ ${texts[-1]} == __ago_sentinel__ ]] && shift -p texts
  (( $#texts == R )) || { REPLY="历史条数对不上（$#texts/$R），没有删除"; return 1 }

  for (( i = 1; i <= R; i++ )); do
    text=${texts[i]}
    # 纯 ASCII 的记录逐条核对，确认记录和命令是对齐的
    if [[ $text != *[^[:ascii:]]* ]]; then
      body=${recs[i]}
      body=${body#: <->:<->;}
      body=${body//$'\\\n'/$'\n'}
      t=$text
      while [[ $body == *[[:space:]] ]]; do body=${body[1,-2]}; done   # zsh 读入时会去掉末尾空白
      while [[ $t == *[[:space:]] ]]; do t=${t[1,-2]}; done
      [[ $body == "$t" ]] || { REPLY="历史文件和预期不一致，没有删除"; return 1 }
    fi
    if [[ -n ${del[$text]} ]]; then (( removed++ )); else keep+=("${recs[i]}"); fi
  done
  (( removed )) || { REPLY="没有找到要删除的记录"; return 1 }

  command cp -p -- $f $f.ago-bak 2>/dev/null
  if (( $#keep )); then print -r -l -- "${keep[@]}" >| $f; else : >| $f; fi || { REPLY="无法写入 $f"; return 1 }

  # 清空当前 shell 的历史，再从文件重新载入。
  # HISTSIZE=0 会留下最近的一条；重新载入后它是最旧的一条，再临时缩小 HISTSIZE 把它挤掉
  hs=$HISTSIZE
  HISTSIZE=0
  n0=${#history}
  HISTSIZE=$hs
  fc -R $f
  if (( n0 && ${#history} > n0 )); then
    HISTSIZE=$(( ${#history} - n0 ))
    HISTSIZE=$hs
  fi
  REPLY=$removed
}

# 确认后执行删除，并刷新列表
_ago_do_delete() {
  local -i sel=$_ago_sel
  if _ago_hist_delete "${_ago_del[@]}"; then
    _ago_msg="已删除 $REPLY 条历史${HISTFILE:+（备份：${HISTFILE/#$HOME/~}.ago-bak）}" _ago_msg_style=ok
  else
    _ago_msg=$REPLY _ago_msg_style=warn
  fi
  _ago_del=() _ago_ask=
  _ago_cache_key= _ago_tmap=()   # 事件号变了，缓存全部作废
  _ago_load
  _ago_filter
  # 组里的命令删光了就回到分组列表
  [[ $_ago_mode == list ]] && (( ! $#_ago_hits )) && _ago_back
  (( _ago_sel = sel ))
}

# 偏好设置：只按白名单读取 key=value，不会执行文件内容
_ago_prefs_load() {
  [[ -r $_ago_conf ]] || return 0
  local k v
  while IFS='=' read -r k v; do
    case $k in
      time) case $v in (0|1) _ago_show_time=$v ;; esac ;;
    esac
  done < $_ago_conf
}

_ago_prefs_save() {
  [[ -d ${_ago_conf:h} ]] || mkdir -p -- ${_ago_conf:h} 2>/dev/null || return 0
  print -r -- "# ago 偏好设置，由 ago 自动保存
time=$_ago_show_time" >| $_ago_conf 2>/dev/null
}

ago-widget() {
  local saved_buffer=$BUFFER saved_pre=$PREDISPLAY key k2 k3
  local -i saved_cursor=$CURSOR done=0 saved_time
  local -a _ago_saved_rh=("${region_highlight[@]}")

  _ago_load
  _ago_prefs_load
  saved_time=$_ago_show_time
  _ago_styles
  strftime -s _ago_today '%Y%m%d' $EPOCHSECONDS
  strftime -s _ago_yesterday '%Y%m%d' $(( EPOCHSECONDS - 86400 ))
  _ago_query=${_ago_initq:-$BUFFER} _ago_group= _ago_mode=group _ago_ask= _ago_msg= _ago_del=()
  _ago_initq=
  _ago_rows=$(( LINES / 2 - 3 ))
  (( _ago_rows > 10 )) && _ago_rows=10
  (( _ago_rows < 3 )) && _ago_rows=3
  _ago_filter
  PREDISPLAY="搜索 › "

  {
    while (( ! done )); do
      BUFFER=$_ago_query
      CURSOR=$#BUFFER
      _ago_render
      zle -R
      read -k key || break
      _ago_msg=
      # 等待确认删除：y 或回车确认，其它任何键取消（方向键之类的整段吃掉，不当作输入）
      if [[ -n $_ago_ask ]]; then
        if [[ $key == (y|Y|$'\r'|$'\n') ]]; then
          _ago_do_delete
        else
          [[ $key == $'\e' ]] && while read -t 0.05 -k k2; do :; done
          _ago_ask= _ago_del=()
          _ago_msg="已取消" _ago_msg_style=dim
        fi
        continue
      fi
      case $key in
        $'\e')
          if read -t 0.05 -k k2 && [[ $k2 == ('['|O) ]]; then
            read -k k3
            case $k3 in
              A) (( _ago_sel-- )) ;;
              B) (( _ago_sel++ )) ;;
              C) _ago_enter ;;
              D) _ago_back ;;
              3) read -k k2; _ago_ask_delete ;;                # Delete
              5) read -k k2; (( _ago_sel -= _ago_rows )) ;;   # PgUp
              6) read -k k2; (( _ago_sel += _ago_rows )) ;;   # PgDn
            esac
          else
            BUFFER=$saved_buffer CURSOR=$saved_cursor done=1
          fi ;;
        $'\C-g') BUFFER=$saved_buffer CURSOR=$saved_cursor done=1 ;;
        $'\C-p') (( _ago_sel-- )) ;;
        $'\C-n') (( _ago_sel++ )) ;;
        $'\C-t') (( _ago_show_time = ! _ago_show_time )) ;;
        $'\r'|$'\n')
          (( $#_ago_hits )) || continue
          if [[ $_ago_mode == group ]]; then
            _ago_enter
          else
            BUFFER=${_ago_cmds[${_ago_hits[_ago_sel]}]} CURSOR=${#BUFFER} done=1
          fi ;;
        $'\C-?'|$'\C-h')
          if [[ -n $_ago_query ]]; then
            _ago_query=${_ago_query[1,-2]}
            _ago_filter
          else
            _ago_ask_delete
          fi ;;
        $'\C-u') _ago_query= ; _ago_filter ;;
        *)
          if [[ $key == [[:print:]] ]]; then
            _ago_query+=$key
            _ago_filter
          fi ;;
      esac
    done
  } always {
    (( _ago_show_time == saved_time )) || _ago_prefs_save
    POSTDISPLAY=
    PREDISPLAY=$saved_pre
    region_highlight=("${_ago_saved_rh[@]}")
    zle -R
  }
}

zle -N ago-widget

# `ago` 命令在 zle 外运行，没法直接画界面：先记下请求，下一个提示符出现时再打开
_ago_line_init() {
  (( _ago_pending )) || return 0
  _ago_pending=0
  zle ago-widget
}
autoload -Uz add-zle-hook-widget
add-zle-hook-widget line-init _ago_line_init

_ago_help() {
  local b=$'\e[1;35m' g=$'\e[90m' c=$'\e[36m' r=$'\e[0m'
  [[ -n $NO_COLOR || ! -t 1 ]] && b= g= c= r=
  print -r -- "${b}ago${r} ${g}$_ago_version · 找回以前用过的命令${r}

${c}ago${r} [关键词]       打开搜索（也可以直接按 ${AGO_KEY:-^R}）
${c}ago stats${r} [选项]   最常用命令统计，按命令名分组
                   ${g}-n 前N个命令  -k 每组K条  -d 最近N天  -g 只看某个命令${r}
${c}ago update${r}         更新到最新版
${c}ago uninstall${r}      卸载
${c}ago version${r}        显示版本

${g}搜索界面：输入 搜索 | ↑↓ 选择 | → 进入组 | ← 返回 | Enter 编辑 | ⌫/Del 删除 | ^T 时间 | esc 退出
偏好设置：$_ago_conf${r}"
}

ago() {
  case $1 in
    stats)
      shift
      zsh "$_ago_dir/ago-stats.zsh" -f "${HISTFILE:-$HOME/.zsh_history}" "$@" ;;
    update|upgrade)
      if [[ ! -d $_ago_dir/.git ]]; then
        print -u2 "ago: $_ago_dir 不是 git 仓库，请重新运行安装命令来更新"
        return 1
      fi
      local old=$_ago_version
      git -C "$_ago_dir" pull --ff-only -q || return
      source "$_ago_dir/ago.zsh"
      if [[ $old == $_ago_version ]]; then
        print -r -- "ago 已是最新版 $_ago_version"
      else
        print -r -- "ago 已从 $old 更新到 $_ago_version"
      fi ;;
    uninstall|remove)
      sh "$_ago_dir/install.sh" --uninstall || return
      bindkey "${AGO_KEY:-^R}" history-incremental-search-backward
      unfunction ago ;;
    -h|--help|help)
      _ago_help ;;
    -v|--version|version)
      print -r -- "ago $_ago_version" ;;
    *)
      _ago_initq="$*"
      _ago_pending=1 ;;
  esac
}

# tab 补全子命令
_ago_complete() {
  local -a subs=(
    'stats:最常用命令统计'
    'update:更新到最新版'
    'uninstall:卸载'
    'help:显示帮助'
    'version:显示版本'
  )
  if (( CURRENT == 2 )); then
    _describe 'ago 子命令' subs
  elif [[ ${words[2]} == stats ]]; then
    _arguments '-n[前 N 个命令]:N' '-k[每组 K 条]:K' '-d[最近 N 天]:天数' '-g[只看某个命令]:命令' '-f[历史文件]:文件:_files'
  fi
}
(( $+functions[compdef] )) && compdef _ago_complete ago

[[ -n $AGO_NO_BIND ]] || bindkey "${AGO_KEY:-^R}" ago-widget
