# ago — 零依赖的 zsh 历史命令搜索：模糊搜索、选择、编辑、回车执行
#
# 安装：./install.sh（会在 ~/.zshrc 里加一行 source）
# 使用：按 Ctrl-R，或输入 ago [关键词]；统计报表：ago stats
#   输入        过滤（空格分隔多个词，先按子串匹配，再按模糊匹配）
#   ↑ ↓         选择（也可用 Ctrl-P / Ctrl-N；PgUp / PgDn 翻页）
#   ←           返回分组列表（git、pnpm…，第一项是"全部"）
#   →           在分组列表里进入选中的组
#   Tab         切换排序：最近 / 最远 / 最多 / 最少（Shift-Tab 反向）
#   Ctrl-T      显示 / 隐藏最后使用时间
#   回车        把选中的命令放到命令行，可以继续编辑，再回车执行
#   Esc         取消（Ctrl-G 同样）
#
# 排序方式和是否显示时间会保存到 ~/.config/ago/config
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
typeset -g _ago_version=0.3.0
typeset -gi _ago_pending=0
typeset -g _ago_initq=

typeset -ga _ago_cmds _ago_lower _ago_counts _ago_names _ago_evts
typeset -ga _ago_gnames _ago_gcounts _ago_gfirst _ago_hits
typeset -gA _ago_tmap   # 事件号 → 时间戳，懒加载缓存
typeset -gA _ago_st     # 界面样式
typeset -ga _ago_terms _ago_rh
typeset -g  _ago_out= _ago_today= _ago_yesterday=
typeset -gi _ago_base=0
typeset -ga _ago_most _ago_least _ago_gmost _ago_gleast
typeset -ga _ago_sorts=(recent oldest most least)
typeset -gA _ago_sort_label=(recent 最近 oldest 最远 most 最多 least 最少)
typeset -g  _ago_cache_key= _ago_query= _ago_group= _ago_mode=list _ago_sort=recent
typeset -gi _ago_sel=1 _ago_top=1 _ago_rows=10 _ago_total=0 _ago_show_time=0
typeset -g  _ago_conf=${AGO_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/ago/config}

# 取命令名：跳过 FOO=bar、sudo 之类的前缀。结果放在 REPLY
_ago_name() {
  local -a w
  local x prefixed=0
  w=(${=${1[1,300]}})   # 只按空白拆分，不会求值或展开通配符
  for x in $w; do
    [[ $x == [A-Za-z_]*=* ]] && continue
    [[ $x == (sudo|time|nohup|env|exec|command|builtin|noglob|nice) ]] && { prefixed=1; continue }
    (( prefixed )) && [[ $x == -* ]] && continue
    REPLY=${x:t}
    # 只接受像命令名的词，排除引号、括号等碎片
    [[ $REPLY == [A-Za-z0-9_.~+@]* && $REPLY != *[\'\"\(\)\$\`]* ]] || REPLY=
    return
  done
  REPLY=
}

# 按次数给下标排序：$1 次数数组名，$2 输出数组名，$3 desc|asc；次数相同时越近越靠前
_ago_sortidx() {
  local -a src keyed out
  local k
  local -i i n
  src=(${(P)1})
  for (( i = 1; i <= $#src; i++ )); do
    n=${src[i]}
    [[ $3 == desc ]] && n=$(( 999999999 - n ))
    keyed+=("${(l:9::0:)n} ${(l:9::0:)i}")
  done
  for k in ${(o)keyed}; do out+=($(( 10#${k##* } ))); done
  set -A $2 $out
}

# 从 $history 统计。各数组都按"最近使用"排列，其它排序用下标数组表示
_ago_load() {
  local key="$HISTCMD:${#history}"
  [[ $key == $_ago_cache_key ]] && return
  _ago_cache_key=$key

  local -A cnt gidx
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
  _ago_gnames=() _ago_gcounts=() _ago_gfirst=()
  for (( i = 1; i <= $#order; i++ )); do
    c=${order[i]}
    n=${cnt[$c]}
    _ago_name "$c"
    [[ $REPLY == ago ]] && continue   # 不列出 ago 自己的调用
    _ago_cmds+=("$c")
    _ago_lower+=("${(L)c}")
    _ago_counts+=($n)
    _ago_names+=("$REPLY")
    _ago_evts+=(${evt[i]})
    [[ -z $REPLY ]] && continue
    if [[ -z ${gidx[$REPLY]} ]]; then
      _ago_gnames+=("$REPLY")
      _ago_gcounts+=(0)
      _ago_gfirst+=($#_ago_cmds)   # 该组最近一条命令的下标
      gidx[$REPLY]=$#_ago_gnames
    fi
    j=${gidx[$REPLY]}
    _ago_gcounts[j]=$(( _ago_gcounts[j] + n ))
  done

  _ago_sortidx _ago_counts _ago_most desc
  _ago_sortidx _ago_counts _ago_least asc
  _ago_sortidx _ago_gcounts _ago_gmost desc
  _ago_sortidx _ago_gcounts _ago_gleast asc
  _ago_total=0
  for n in $_ago_counts; do (( _ago_total += n )); done
}

# 当前排序下的下标顺序，放在 reply
_ago_order() {
  local -i n
  if [[ $_ago_mode == group ]]; then
    n=$#_ago_gnames
    case $_ago_sort in
      recent) reply=({1..$n}) ;;
      oldest) reply=({$n..1}) ;;
      most)   reply=($_ago_gmost) ;;
      least)  reply=($_ago_gleast) ;;
    esac
  else
    n=$#_ago_cmds
    case $_ago_sort in
      recent) reply=({1..$n}) ;;
      oldest) reply=({$n..1}) ;;
      most)   reply=($_ago_most) ;;
      least)  reply=($_ago_least) ;;
    esac
  fi
  (( n )) || reply=()
}

# 根据查询词和分组过滤，结果是下标列表 _ago_hits
_ago_filter() {
  local -a terms sub fuz reply
  local t ch pat i ok
  terms=(${=${(L)_ago_query}})
  _ago_terms=($terms)
  _ago_hits=()
  _ago_sel=1 _ago_top=1
  _ago_order

  if [[ $_ago_mode == group ]]; then
    for i in $reply; do
      ok=1
      for t in $terms; do [[ ${(L)_ago_gnames[i]} == *${(b)t}* ]] || { ok=0; break }; done
      (( ok )) && _ago_hits+=($i)
    done
    [[ -z $terms ]] && _ago_hits=(0 $_ago_hits)   # 下标 0 表示"全部"，固定在第一项
    return
  fi

  # 每个词的模糊模式：git → *g*i*t*
  local -a fpats
  for t in $terms; do
    pat='*'
    for ch in ${(s::)t}; do pat+="${(b)ch}*"; done
    fpats+=("$pat")
  done

  for i in $reply; do
    [[ -n $_ago_group && ${_ago_names[i]} != "$_ago_group" ]] && continue
    ok=1
    for t in $terms; do [[ ${_ago_lower[i]} == *${(b)t}* ]] || { ok=0; break }; done
    if (( ok )); then sub+=($i); continue; fi
    ok=1
    for pat in $fpats; do [[ ${_ago_lower[i]} == ${~pat} ]] || { ok=0; break }; done
    (( ok )) && fuz+=($i)
  done
  _ago_hits=($sub $fuz)
}

# 截断到指定显示宽度（中文算 2 列）
_ago_fit() {
  local s=$1
  while [[ $s == *[[:space:]] ]]; do s=${s[1,-2]}; done   # 去掉结尾的换行和空格
  s=${s//$'\n'/↵}
  s=${s//$'\t'/ }
  local -i w=$2
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
    _ago_st=(brand bold dim '' sel standout match underline prompt bold)
  else
    _ago_st=(brand 'fg=magenta,bold' dim 'fg=8' sel 'fg=cyan,bold' match 'fg=yellow,bold' prompt 'fg=yellow')
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
  local -i n=$#_ago_hits i j w=$(( COLUMNS - (_ago_show_time ? 21 : 11) ))
  local label=${_ago_sort_label[$_ago_sort]} cnt when name style seg line
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
    _ago_put "  分组 · $#_ago_gnames 个 · $label" ${_ago_st[dim]}
  else
    _ago_put "  分组 › " ${_ago_st[dim]}
    _ago_put "${_ago_group:-全部}" ${_ago_st[sel]}
    if [[ -n $_ago_group ]]; then
      _ago_put " · $n 条 · $label" ${_ago_st[dim]}
    else
      _ago_put " · $n/$#_ago_cmds 条 · $label" ${_ago_st[dim]}
    fi
  fi

  # 列表
  for (( j = _ago_top; j < _ago_top + _ago_rows && j <= n; j++ )); do
    i=${_ago_hits[j]}
    when=
    if [[ $_ago_mode == group ]] && (( i == 0 )); then
      cnt=$_ago_total; name=全部
      (( _ago_show_time )) && { _ago_when 1; when=$REPLY }
    elif [[ $_ago_mode == group ]]; then
      cnt=${_ago_gcounts[i]}; name=${_ago_gnames[i]}
      (( _ago_show_time )) && { _ago_when ${_ago_gfirst[i]}; when=$REPLY }
    else
      cnt=${_ago_counts[i]}; name=${_ago_cmds[i]}
      (( _ago_show_time )) && { _ago_when $i; when=$REPLY }
    fi
    [[ -n $when ]] && when+='  '
    _ago_fit "$name" $w; name=$REPLY
    _ago_put $'\n'
    if (( j == _ago_sel )); then
      _ago_put "➤ ${(l:5:)cnt}  $when" ${_ago_st[sel]}
      _ago_put "$name" ${_ago_st[sel]}
    else
      _ago_put '  '
      _ago_put "${(l:5:)cnt}  $when" ${_ago_st[dim]}
      _ago_put "$name"
    fi
    _ago_mark "$name" $(( _ago_base + ${#_ago_out} - ${#name} ))
  done
  if (( n == 0 )); then
    _ago_put $'\n'
    _ago_put "  没有匹配的命令" ${_ago_st[dim]}
  fi

  # 底部按键提示：随状态变化，宽度不够时在分隔符处换行
  (( n > _ago_rows )) && segs+=("$_ago_sel/$n")
  segs+=("↑↓ 选择")
  if [[ $_ago_mode == group ]]; then
    segs+=("→ 进入")
  else
    segs+=("← 分组" "Enter 编辑")
  fi
  segs+=("Tab 排序" "^T 时间")
  [[ -n $_ago_query ]] && segs+=("^U 清空")
  segs+=("Esc 退出")
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

# 循环切换排序方式：$1 为 1 或 -1
_ago_cycle_sort() {
  local -i i=${_ago_sorts[(i)$_ago_sort]}
  i=$(( (i - 1 + $1 + $#_ago_sorts) % $#_ago_sorts + 1 ))
  _ago_sort=${_ago_sorts[i]}
  _ago_filter
}

# → / 回车：在分组列表里进入选中的组
_ago_enter() {
  [[ $_ago_mode == group ]] && (( $#_ago_hits )) || return
  local -i i=${_ago_hits[_ago_sel]}
  if (( i == 0 )); then _ago_group=; else _ago_group=${_ago_gnames[i]}; fi
  _ago_mode=list _ago_query=
  _ago_filter
}

# ←：从命令列表返回分组列表，并选中刚才所在的组
_ago_back() {
  [[ $_ago_mode == list ]] || return
  local g=$_ago_group
  local -i j
  _ago_mode=group _ago_group= _ago_query=
  _ago_filter
  [[ -z $g ]] && return   # 来自"全部"，它就在第一项
  for (( j = 1; j <= $#_ago_hits; j++ )); do
    (( _ago_hits[j] )) || continue
    [[ ${_ago_gnames[${_ago_hits[j]}]} == "$g" ]] && { _ago_sel=j; return }
  done
}

# 偏好设置：只按白名单读取 key=value，不会执行文件内容
_ago_prefs_load() {
  [[ -r $_ago_conf ]] || return 0
  local k v
  while IFS='=' read -r k v; do
    case $k in
      sort) case $v in (recent|oldest|most|least) _ago_sort=$v ;; esac ;;
      time) case $v in (0|1) _ago_show_time=$v ;; esac ;;
    esac
  done < $_ago_conf
}

_ago_prefs_save() {
  [[ -d ${_ago_conf:h} ]] || mkdir -p -- ${_ago_conf:h} 2>/dev/null || return 0
  print -r -- "# ago 偏好设置，由 ago 自动保存
sort=$_ago_sort
time=$_ago_show_time" >| $_ago_conf 2>/dev/null
}

ago-widget() {
  local saved_buffer=$BUFFER saved_pre=$PREDISPLAY key k2 k3 prefs
  local -i saved_cursor=$CURSOR done=0
  local -a _ago_saved_rh=("${region_highlight[@]}")

  _ago_load
  _ago_prefs_load
  prefs="$_ago_sort $_ago_show_time"
  _ago_styles
  strftime -s _ago_today '%Y%m%d' $EPOCHSECONDS
  strftime -s _ago_yesterday '%Y%m%d' $(( EPOCHSECONDS - 86400 ))
  _ago_query=${_ago_initq:-$BUFFER} _ago_group= _ago_mode=list
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
      case $key in
        $'\e')
          if read -t 0.05 -k k2 && [[ $k2 == ('['|O) ]]; then
            read -k k3
            case $k3 in
              A) (( _ago_sel-- )) ;;
              B) (( _ago_sel++ )) ;;
              C) _ago_enter ;;
              D) _ago_back ;;
              Z) _ago_cycle_sort -1 ;;                         # Shift-Tab
              5) read -k k2; (( _ago_sel -= _ago_rows )) ;;   # PgUp
              6) read -k k2; (( _ago_sel += _ago_rows )) ;;   # PgDn
            esac
          else
            BUFFER=$saved_buffer CURSOR=$saved_cursor done=1
          fi ;;
        $'\C-g') BUFFER=$saved_buffer CURSOR=$saved_cursor done=1 ;;
        $'\C-p') (( _ago_sel-- )) ;;
        $'\C-n') (( _ago_sel++ )) ;;
        $'\t'|$'\C-o') _ago_cycle_sort 1 ;;
        $'\C-t') (( _ago_show_time = ! _ago_show_time )) ;;
        $'\r'|$'\n')
          (( $#_ago_hits )) || continue
          if [[ $_ago_mode == group ]]; then
            _ago_enter
          else
            BUFFER=${_ago_cmds[${_ago_hits[_ago_sel]}]} CURSOR=${#BUFFER} done=1
          fi ;;
        $'\C-?'|$'\C-h')
          [[ -n $_ago_query ]] && { _ago_query=${_ago_query[1,-2]}; _ago_filter } ;;
        $'\C-u') _ago_query= ; _ago_filter ;;
        *)
          if [[ $key == [[:print:]] ]]; then
            _ago_query+=$key
            _ago_filter
          fi ;;
      esac
    done
  } always {
    [[ "$_ago_sort $_ago_show_time" == $prefs ]] || _ago_prefs_save
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

${g}搜索界面：输入 过滤 | ↑↓ 选择 | ← 分组 | → 进入 | Tab 排序 | ^T 时间 | Enter 编辑 | Esc 退出
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

# Tab 补全子命令
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
