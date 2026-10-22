"""在伪终端里运行 tests/delete.zsh：打开交互 zsh，source 测试文件，再按 Ctrl-X Ctrl-T。

用法：python3 tests/delete_pty.py <ago 目录> <临时目录>
把 $tmp/log 的内容原样输出（ok / bad 行），超时或没有完成时输出一行 bad。
"""
import os
import pty
import select
import sys
import time

root, tmp = sys.argv[1], sys.argv[2]
log = os.path.join(tmp, "log")


def metafy(text):
    """按 zsh 写历史文件的方式编码：0x83..0xA2 的字节写成 0x83 加上该字节异或 0x20"""
    out = bytearray()
    for b in text.encode("utf-8"):
        if 0x83 <= b <= 0xA2:
            out += bytes([0x83, b ^ 0x20])
        else:
            out.append(b)
    return bytes(out)


# 测试用的历史。多行命令在文件里每行末尾加反斜杠；"  -d x \ " 末尾有空格，不算续行
records = [
    (1700000000, "echo keep1"),
    (1700000100, "git push origin main"),
    (1700000200, "ls *.txt | grep (a)"),
    (1700000300, "echo 中文 删除"),
    (1700000400, "cat <<X\\\n多行 七\\\nX"),
    (1700000500, "git push origin main"),
    (1700000600, "echo 中文 保留 七"),
    (1700000700, f"echo $(touch {tmp}/PWNED6)"),
    (1700000800, "curl -H 'a: b' \\\n  -d x \\ "),
    (1700000900, "echo last"),
]
data = b"".join(metafy(f": {ts}:0;{cmd}") + b"\n" for ts, cmd in records)
with open(os.path.join(tmp, "h"), "wb") as f:
    f.write(data)
with open(os.path.join(tmp, "h.orig"), "wb") as f:
    f.write(data)

pid, fd = pty.fork()
if pid == 0:
    loc = "C.UTF-8" if sys.platform.startswith("linux") else "en_US.UTF-8"
    os.environ.update(HOME=tmp, TERM="xterm", LANG=loc, LC_ALL=loc)
    os.execvp("zsh", ["zsh", "-f", "-i"])


def drain(seconds):
    end = time.time() + seconds
    while time.time() < end:
        ready, _, _ = select.select([fd], [], [], 0.05)
        if ready:
            try:
                os.read(fd, 65536)
            except OSError:
                return


def wait_for_done(seconds):
    end = time.time() + seconds
    while time.time() < end:
        drain(0.2)
        if os.path.exists(log) and open(log, encoding="utf-8").read().endswith("done\n"):
            return True
    return False


drain(1)
os.write(fd, f"source {root}/tests/delete.zsh {root} {tmp}\r".encode())
drain(1.5)
os.write(fd, b"\x18\x14")  # Ctrl-X Ctrl-T
finished = wait_for_done(20)
os.write(fd, b"exit\r")
drain(0.5)

if os.path.exists(log):
    sys.stdout.write("".join(l for l in open(log, encoding="utf-8") if l != "done\n"))
if not finished:
    print("bad 删除测试没有在 20 秒内完成 | 见 " + log)
