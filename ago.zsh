# ago — 零依赖的 zsh 历史命令搜索：模糊搜索、选择、编辑、回车执行
#
# 安装：./install.sh（会在 ~/.zshrc 里加一行 source）
# 使用：按 Ctrl-R，或输入 ago [关键词]；统计报表：ago stats
#   输入        过滤（空格分隔多个词，先按子串匹配，再按模糊匹配）
#   ↑ ↓         选择（也可用 Ctrl-P / Ctrl-N）
#   ← →         切换排序：最近 / 最远 / 最多 / 最少（也可用 Ctrl-O）
#   回车        把选中的命令放到命令行，可以继续编辑，再回车执行
#   Tab         切换到"按命令名分组"，选中某个命令名后只看这一组
#   Esc         取消（Ctrl-G 同样）
#
# 安全说明：命令文本只作为字符串处理，绝不放进 (( )) 或 eval，
# 否则历史里的 $(...) 会被执行。

# 可在 source 之前设置：
#   AGO_KEY=...    打开搜索的快捷键（默认 ^R，即 Ctrl-R）
#   AGO_NO_BIND=1  不绑定快捷键，只用 ago 命令

zmodload zsh/parameter

typeset -g _ago_dir=${${(%):-%x}:A:h}   # 本文件所在目录
typeset -g _ago_version=0.1.0
typeset -gi _ago_pending=0
typeset -g _ago_initq=

typeset -ga _ago_cmds _ago_lower _ago_counts _ago_names _ago_evts
typeset -ga _ago_gnames _ago_gcounts _ago_gfirst _ago_hits
typeset -gA _ago_dmap   # 事件号 → 日期，懒加载缓存
typeset -ga _ago_most _ago_least _ago_gmost _ago_gleast
typeset -ga _ago_sorts=(recent oldest most least)
typeset -gA _ago_sort_label=(recent 最近 oldest 最远 most 最多 least 最少)
typeset -g  _ago_cache_key= _ago_query= _ago_group= _ago_mode=list _ago_sort=recent
typeset -gi _ago_sel=1 _ago_top=1 _ago_rows=10

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
  _ago_hits=()
  _ago_sel=1 _ago_top=1
  _ago_order

  if [[ $_ago_mode == group ]]; then
    for i in $reply; do
      ok=1
      for t in $terms; do [[ ${(L)_ago_gnames[i]} == *${(b)t}* ]] || { ok=0; break }; done
      (( ok )) && _ago_hits+=($i)
    done
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

# 第 $1 条命令最后一次使用的日期，放在 REPLY。只查屏幕上显示的行，查过就缓存
_ago_date() {
  local -i e=${_ago_evts[$1]}
  local line
  local -a w
  if [[ -z ${_ago_dmap[$e]} ]]; then
    line="$(fc -lt '%y-%m-%d' $e $e 2>/dev/null)"
    line=${line%%$'\n'*}
    w=(${=line[1,40]})   # 只取 "事件号 日期" 两个字段
    [[ ${w[2]} == <->-<->-<-> ]] && _ago_dmap[$e]=${w[2]} || _ago_dmap[$e]='--------'
  fi
  REPLY=${_ago_dmap[$e]}
}

_ago_render() {
  local -a lines
  local -i n=$#_ago_hits i j w=$(( COLUMNS - 21 ))
  local head line mark date

  (( _ago_sel > n )) && _ago_sel=n
  (( _ago_sel < 1 )) && _ago_sel=1
  (( _ago_sel < _ago_top )) && _ago_top=_ago_sel
  (( _ago_sel >= _ago_top + _ago_rows )) && _ago_top=$(( _ago_sel - _ago_rows + 1 ))

  if [[ $_ago_mode == group ]]; then
    head="  按命令名分组  $n 个"
  elif [[ -n $_ago_group ]]; then
    head="  [$_ago_group]  $n 条   退格可回到全部"
  else
    head="  $n/$#_ago_cmds 条"
  fi
  head+="   排序:${_ago_sort_label[$_ago_sort]}   ↑↓选择 ←→排序 回车确定 Tab分组 Esc取消"
  _ago_fit "$head" $(( COLUMNS - 1 ))
  lines=("$REPLY")

  local -i hl_start=-1 hl_end=-1 pos=$(( ${#BUFFER} + 1 + ${#lines[1]} + 1 ))
  for (( j = _ago_top; j < _ago_top + _ago_rows && j <= n; j++ )); do
    i=${_ago_hits[j]}
    if (( j == _ago_sel )); then mark='▶'; else mark=' '; fi
    if [[ $_ago_mode == group ]]; then
      _ago_date ${_ago_gfirst[i]}; date=$REPLY
      _ago_fit "${_ago_gnames[i]}" $w
      line="$mark ${(l:6:)_ago_gcounts[i]}  $date  $REPLY"
    else
      _ago_date $i; date=$REPLY
      _ago_fit "${_ago_cmds[i]}" $w
      line="$mark ${(l:6:)_ago_counts[i]}  $date  $REPLY"
    fi
    (( j == _ago_sel )) && { hl_start=$pos; hl_end=$(( pos + ${#line} )) }
    pos+=$(( ${#line} + 1 ))
    lines+=("$line")
  done
  (( n == 0 )) && lines+=("  （没有匹配的命令）")

  POSTDISPLAY=$'\n'"${(pj:\n:)lines}"
  region_highlight=("${_ago_saved_rh[@]}" "$(( ${#BUFFER} + 1 )) $(( ${#BUFFER} + 1 + ${#lines[1]} )) fg=8")
  (( hl_start >= 0 )) && region_highlight+=("$hl_start $hl_end standout")
}

# 循环切换排序方式：$1 为 1 或 -1
_ago_cycle_sort() {
  local -i i=${_ago_sorts[(i)$_ago_sort]}
  i=$(( (i - 1 + $1 + $#_ago_sorts) % $#_ago_sorts + 1 ))
  _ago_sort=${_ago_sorts[i]}
  _ago_filter
}

ago-widget() {
  local saved_buffer=$BUFFER key k2 k3
  local -i saved_cursor=$CURSOR done=0
  local -a _ago_saved_rh=("${region_highlight[@]}")

  _ago_load
  _ago_query=${_ago_initq:-$BUFFER} _ago_group= _ago_mode=list
  _ago_initq=
  _ago_rows=$(( LINES / 2 - 2 ))
  (( _ago_rows > 12 )) && _ago_rows=12
  (( _ago_rows < 3 )) && _ago_rows=3
  _ago_filter

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
              C) _ago_cycle_sort 1 ;;
              D) _ago_cycle_sort -1 ;;
            esac
          else
            BUFFER=$saved_buffer CURSOR=$saved_cursor done=1
          fi ;;
        $'\C-g') BUFFER=$saved_buffer CURSOR=$saved_cursor done=1 ;;
        $'\C-p') (( _ago_sel-- )) ;;
        $'\C-n') (( _ago_sel++ )) ;;
        $'\C-o') _ago_cycle_sort 1 ;;
        $'\r'|$'\n')
          (( $#_ago_hits )) || continue
          local -i i=${_ago_hits[_ago_sel]}
          if [[ $_ago_mode == group ]]; then
            _ago_group=${_ago_gnames[i]} _ago_mode=list _ago_query=
            _ago_filter
          else
            BUFFER=${_ago_cmds[i]} CURSOR=${#BUFFER} done=1
          fi ;;
        $'\t')
          if [[ $_ago_mode == group ]]; then _ago_mode=list; else _ago_mode=group _ago_group=; fi
          _ago_query=
          _ago_filter ;;
        $'\C-?'|$'\C-h')
          if [[ -n $_ago_query ]]; then
            _ago_query=${_ago_query[1,-2]}
          elif [[ -n $_ago_group ]]; then
            _ago_group=
          fi
          _ago_filter ;;
        $'\C-u') _ago_query= ; _ago_filter ;;
        *)
          if [[ $key == [[:print:]] ]]; then
            _ago_query+=$key
            _ago_filter
          fi ;;
      esac
    done
  } always {
    POSTDISPLAY=
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

ago() {
  case $1 in
    stats)
      shift
      zsh "$_ago_dir/ago-stats.zsh" -f "${HISTFILE:-$HOME/.zsh_history}" "$@" ;;
    -h|--help|help)
      print -r -- "ago $_ago_version — zsh 历史命令搜索

用法:
  ago [关键词]     打开搜索（也可以直接按 ${AGO_KEY:-^R}）
  ago stats [选项] 最常用命令统计，按命令名分组
                   -n 前N个命令  -k 每组K条  -d 最近N天  -g 只看某个命令
  ago version      显示版本

搜索界面:
  输入 过滤   ↑↓ 选择   ←→ 排序(最近/最远/最多/最少)
  Tab 按命令名分组   回车 放到命令行编辑   Esc 取消" ;;
    -v|--version|version)
      print -r -- "ago $_ago_version" ;;
    *)
      _ago_initq="$*"
      _ago_pending=1 ;;
  esac
}

[[ -n $AGO_NO_BIND ]] || bindkey "${AGO_KEY:-^R}" ago-widget
