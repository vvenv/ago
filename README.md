<div align="center">

# ago

**找回以前用过的命令。**

零依赖的 zsh 历史搜索：模糊搜索 → 选择 → 编辑 → 回车执行

[![test](https://github.com/vvenv/ago/actions/workflows/test.yml/badge.svg)](https://github.com/vvenv/ago/actions/workflows/test.yml)
[![license](https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square)](LICENSE)
![zsh](https://img.shields.io/badge/zsh-5.3%2B-green.svg?style=flat-square)

</div>

```
$ 搜索 › push
ago  3
➤ git      git push origin main
  pnpm     pnpm push:docs
  docker   docker push vvenv/app
↑↓ 选择 | → 进入 | Del 删除 | ^O 次数 | ^T 时间 | ^U 清空 | esc 退出
```

按 → 进入 git 组：

```
$ 搜索 › push
ago  git · 3
➤ git push origin main
  git push --tags
  git push -f
↑↓ 选择 | ← 返回 | Enter 编辑 | Del 删除 | ^O 次数 | ^T 时间 | ^U 清空 | esc 退出
```

按 `Ctrl-O` 显示使用次数，按 `Ctrl-T` 显示最后使用时间：

```
$ 搜索 › push
ago  git · 3
➤   115  5分钟前   git push origin main
      2  3周前     git push --tags
      1  2个月前   git push -f
```

## 特性

- **零依赖**：纯 zsh 实现，不需要 fzf、Python 或其它工具
- **模糊搜索**：多个关键词用空格分开，匹配到的字会高亮，支持中文
- **按命令名分组**：打开就是 git、pnpm、docker 等分组，按 → 进入、← 返回；组和命令都按最近使用排序
- **搜索跨两级**：在分组列表里输入关键词，只显示含有匹配命令的组，并提示最近一条匹配的命令
- **简洁的列表**：默认只显示命令，需要时按 Ctrl-O 显示使用次数、Ctrl-T 显示最后使用时间
- **记住偏好**：是否显示次数和时间会自动保存，下次打开沿用
- **先编辑再执行**：选中的命令放到命令行，改好再回车，不会直接执行
- **删除历史**：按退格删除选中的命令或整组，需要按 y 确认，删除前自动备份
- **统计报表**：`ago stats` 显示最常用的命令，按命令名分组
- **安全**：历史里的 `$(...)` 等内容只当作文本处理，不会被执行（有[测试](tests/test.zsh)保证）

## 安装

需要 zsh 5.3 或更新版本（macOS 自带的 zsh 就可以）。

```sh
sh -c "$(curl -fsSL https://raw.githubusercontent.com/vvenv/ago/main/install.sh)"
source ~/.zshrc
```

代码会放在 `~/.ago`，并在 `~/.zshrc` 末尾加一行 `source`。重复运行不会重复添加。

<details>
<summary>手动安装</summary>

```sh
git clone https://github.com/vvenv/ago.git ~/.ago && ~/.ago/install.sh
```

代码也可以放在任意目录，在该目录里运行 `./install.sh` 即可。目录移动后重新运行一次。

</details>

## 使用

```sh
ago                # 打开搜索（或者直接按 Ctrl-R）
ago git push       # 带着关键词打开搜索
ago stats          # 最常用命令统计
ago update         # 更新到最新版
ago uninstall      # 卸载
ago help           # 帮助
```

在命令行里已经输入了一部分时按 Ctrl-R，已输入的内容会直接作为关键词。

### 搜索界面的按键

| 按键 | 作用 |
| --- | --- |
| 输入文字 | 搜索命令，空格分隔多个关键词，不区分大小写 |
| `↑` `↓` / `Ctrl-P` `Ctrl-N` | 上下选择 |
| `PgUp` `PgDn` | 翻页 |
| `→` / `回车` | 在分组列表里进入选中的组 |
| `←` | 返回分组列表，选中刚才所在的组 |
| `回车` | 在组里：把选中的命令放到命令行 |
| `Ctrl-O` | 显示 / 隐藏使用次数 |
| `Ctrl-T` | 显示 / 隐藏最后一次使用的时间（30秒前、5分钟前、2小时前、昨天、3天前…） |
| `退格` | 删除关键词的一个字；关键词为空时，删除选中的命令或整组 |
| `Delete` | 删除选中的命令或整组（有关键词时也可以用） |
| `Ctrl-U` | 清空关键词 |
| `esc` / `Ctrl-G` | 退出，恢复原来的命令行 |

每行显示组名或命令；打开次数显示后，分组列表里的次数是组内（匹配的）命令次数之和。多行命令用 `↵` 表示换行，选中后会还原成原来的多行。取不到命令名的历史（比如单独的 `FOO=1`）归在「(其他)」组。

关键词在进入和返回时都会保留。匹配规则：先列出包含所有关键词的命令，再列出按顺序模糊匹配的命令，例如输入 `gps` 也能找到 `git push`；两部分各自按最近使用排序。

### 删除历史

关键词为空时按退格（或任何时候按 Delete），会删除选中的行：

- 在组里：删除这条命令的**所有**历史记录
- 在分组列表里：删除整组；有关键词时只删除这一组里匹配的命令

底部会用红字写明要删除什么、共多少条历史，按 `y`（或回车）确认，按其它任意键取消。删除会同时更新历史文件和当前 shell 的历史；写入前会把原文件备份为 `~/.zsh_history.ago-bak`（只保留最近一次）。其它已经打开的终端里，删除的命令还会留在它们的内存中，重新打开即可。

### 统计报表

```sh
ago stats              # 前 15 个命令，每组列 5 条最常用的完整命令
ago stats -n 30 -k 10  # 前 30 个命令，每组列 10 条
ago stats -d 30        # 只统计最近 30 天
ago stats -g git       # 只看 git
```

```
 3. git              1192   10.6%  █████
    子命令: ps(349), ca(248), push(115), rebase(112), pull(28), checkout(24)
      342  git ps
      248  git ca
```

一条命令里有 `|`、`&&`、`;` 时会拆开分别统计；`sudo`、`env`、`FOO=bar` 这类前缀会被跳过；heredoc 正文不计入。

## 配置

### 偏好设置

在搜索界面里切换的次数显示（Ctrl-O）和时间显示（Ctrl-T）会自动保存到 `~/.config/ago/config`，下次打开沿用，多个终端共用：

```ini
count=0       # 1 显示使用次数
time=0        # 1 显示最后使用时间
```

也可以手动编辑这个文件。ago 只读取这两项，不会把它当作脚本执行。

### 环境变量

在 `~/.zshrc` 里 `source` ago 的那一行**之前**设置：

```sh
AGO_KEY='^F'      # 改用 Ctrl-F 打开（默认 ^R）
AGO_NO_BIND=1     # 不绑定任何快捷键，只用 ago 命令
NO_COLOR=1        # 不使用颜色（通用约定，见 no-color.org）
AGO_CONFIG=...    # 偏好设置文件的位置（默认 $XDG_CONFIG_HOME/ago/config）
```

## 卸载

```sh
ago uninstall   # 从 ~/.zshrc 删除那一行，备份为 ~/.zshrc.ago-bak
rm -rf ~/.ago ~/.config/ago   # 可选：删除代码和偏好设置
```

## 常见问题

**和 oh-my-zsh 冲突吗？**
不冲突。ago 会覆盖 oh-my-zsh 默认的 Ctrl-R（逐条反向搜索）。想保留原来的 Ctrl-R，设置 `AGO_KEY` 换一个键即可。卸载时会把 Ctrl-R 还原。

**数据从哪来？**
来自当前 shell 的历史（zsh 的 `$history`），与 `~/.zsh_history` 一致。开启了 `share_history`（oh-my-zsh 默认开启）时，其它终端里刚执行的命令也能搜到。ago 不会写入或修改历史文件。

**删除会不会弄坏历史文件？**
ago 不自己解析或重新编码历史：它按记录把原文件拆开，用 zsh 自己读出每条记录对应的命令，只去掉要删除的记录，其余字节原样写回（包括 zsh 对中文等字符的内部编码）。删除前会核对记录和命令是否一一对应，对不上就放弃、不做任何修改，并先备份原文件。

**为什么有时第一次打开稍慢？**
每执行一条新命令后，第一次打开会重新统计历史。8000 条历史大约需要 0.2 秒，之后每次按键过滤约 30 毫秒。

## 开发

```sh
zsh tests/test.zsh   # 运行测试
```

| 文件 | 说明 |
| --- | --- |
| `ago.zsh` | 搜索界面和 `ago` 命令 |
| `ago-stats.zsh` | `ago stats` 统计报表（zsh + awk） |
| `install.sh` | 安装 / 卸载 |
| `tests/test.zsh` | 测试（`zsh tests/test.zsh` 运行全部） |
| `tests/delete.zsh`、`tests/delete_pty.py` | 删除历史的测试，在伪终端的交互 zsh 中运行（需要 python3） |

## 许可证

[MIT](LICENSE)
