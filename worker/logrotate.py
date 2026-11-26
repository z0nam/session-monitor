#!/usr/bin/env python3
"""session-monitor 로그 순환 — 워커 주기에 끼워 하루 한 번 도는 저빈도 점검. stdlib만 사용.

- 크기 상한(MAX_BYTES)을 넘은 로그는 **copytruncate** 한다: 꼬리를 `<로그>.1` 로 복사한 뒤
  원본을 같은 inode 그대로 0으로 자른다. 한 세대(.1)만 남긴다.
  mv 로 옮기지 않는 이유: launchd 의 StandardOut/ErrPath 는 데몬(ollama, KeepAlive)이
  열어 둔 채 계속 쓰므로, mv 하면 데몬이 옛 파일(.1)에 계속 쓴다.
  copytruncate 가 안전한 근거: launchd 는 이 파일들을 O_APPEND 로 연다
  (`lsof +fg -p <pid>` 에서 FD 플래그 AP 확인, 2026-11-26). O_APPEND 쓰기는 매번 현재 EOF 에
  붙으므로 truncate 뒤 다음 쓰기는 0 바이트부터 이어진다 — 구멍(sparse hole)이 생기지 않는다.
  한계: 복사와 truncate 사이 아주 짧은 틈에 쓰인 줄은 잃을 수 있다(로그라 허용).
- `.1` 에는 원본의 마지막 MAX_BYTES 만 복사한다 → 파일 하나가 최대 2×MAX_BYTES 를 넘지 않는다.
- 날짜별 파일이 쌓이는 디렉터리(report/logs)는 PRUNE_DAYS 보다 오래된 `*.log` 를 지운다.
- 비치명: 어떤 실패도 예외로 올리지 않고 로그 한 줄만 남긴다(워커 본 작업을 막지 않는다).
"""
import glob
import os
import time

MAX_BYTES = 10 * 1024 * 1024     # 파일당 상한 10MB. 넘으면 .1 로 한 세대만 남김
INTERVAL = 24 * 3600             # 점검 주기(하루 1회). 워커는 120초마다 돌지만 대부분 스탬프만 보고 끝난다
PRUNE_DAYS = 90                  # 날짜별 로그 디렉터리 보존 기간


def targets(smon_home):
    """크기 상한을 적용할 로그 파일 목록. 없는 파일은 건너뛴다(원격 맥 등)."""
    logs = os.path.expanduser("~/Library/Logs")
    data = os.path.expanduser("~/.local/share/smon")
    return [
        os.path.join(logs, "ollama.log"),           # com.namun.ollama (KeepAlive 데몬)
        os.path.join(logs, "smon-worker.log"),      # com.namun.smon-worker (이 워커 자신)
        os.path.join(logs, "smon-pull.log"),        # com.namun.smon-pull
        os.path.join(data, "apply-color.log"),      # hooks/apply-color.sh (DB 이전 후 위치)
        os.path.join(smon_home, "apply-color.log"),  # hooks/apply-color.sh (레거시 위치)
        os.path.join(smon_home, "report", "logs", "launchd.err"),  # com.namun.smon-report
    ]


def prune_dirs(smon_home):
    """PRUNE_DAYS 보다 오래된 `*.log` 를 지울 디렉터리 목록."""
    return [os.path.join(smon_home, "report", "logs")]


def copytruncate(path, max_bytes=MAX_BYTES):
    """path 가 max_bytes 를 넘으면 꼬리 max_bytes 를 path.1 로 복사하고 path 를 제자리에서 0으로 자른다.
    순환했으면 True. inode 는 바뀌지 않는다(열린 O_APPEND 핸들이 계속 같은 파일에 쓴다)."""
    try:
        size = os.path.getsize(path)
    except OSError:
        return False
    if size <= max_bytes:
        return False
    tmp = path + ".1.tmp"
    try:
        # 복사(복사 중 붙은 내용 포함)를 flush·fsync·close 로 확정한 뒤에야 원본을 자른다.
        # 복사가 실패하면(디스크 가득 등) 원본은 그대로 남는다.
        with open(path, "rb") as src, open(tmp, "wb") as dst:
            src.seek(size - max_bytes)
            src.readline()               # 잘린 첫 줄은 버린다(줄 경계에서 시작)
            while True:
                buf = src.read(1 << 20)
                if not buf:
                    break
                dst.write(buf)
            dst.flush()
            os.fsync(dst.fileno())
    except BaseException:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise
    with open(path, "r+b") as f:         # 확정 직후 바로 자른다 — 틈을 최소화
        f.truncate(0)
    os.replace(tmp, path + ".1")
    return True


def prune(dirpath, days=PRUNE_DAYS, now=None):
    """dirpath 의 `*.log` 중 mtime 이 days 일보다 오래된 것을 지운다. 지운 개수를 돌려준다."""
    cutoff = (now or time.time()) - days * 86400
    n = 0
    for p in glob.glob(os.path.join(dirpath, "*.log")):
        try:
            if os.path.getmtime(p) < cutoff:
                os.remove(p)
                n += 1
        except OSError:
            pass
    return n


def due(stamp, interval=INTERVAL, now=None):
    """스탬프 파일이 없거나 interval 보다 오래됐으면 True."""
    try:
        return (now or time.time()) - os.path.getmtime(stamp) >= interval
    except OSError:
        return True


def run(smon_home, stamp, log=print, force=False, max_bytes=MAX_BYTES, files=None, dirs=None):
    """하루 1회 점검. 예외를 밖으로 내보내지 않는다. files/dirs 를 주면 기본 목록 대신 쓴다(테스트용)."""
    try:
        if not force and not due(stamp):
            return
        # 스탬프를 먼저 찍는다 — 순환이 매번 실패해도 120초마다 재시도하지 않게
        with open(stamp, "a"):
            pass
        os.utime(stamp, None)
    except OSError as e:
        log(f"logrotate: stamp failed: {e}")
        return
    for path in (targets(smon_home) if files is None else files):
        try:
            if copytruncate(path, max_bytes):
                log(f"logrotate: rotated {path}")
        except Exception as e:      # 권한·디스크 등 — 다음 대상은 계속
            log(f"logrotate: {path} failed: {e}")
    for d in (prune_dirs(smon_home) if dirs is None else dirs):
        try:
            n = prune(d)
            if n:
                log(f"logrotate: pruned {n} old logs in {d}")
        except Exception as e:
            log(f"logrotate: prune {d} failed: {e}")


if __name__ == "__main__":          # 수동 실행: python3 worker/logrotate.py  (스탬프 무시하고 즉시)
    home = os.environ.get("SMON_HOME") or os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
    stamp = os.path.join(os.path.expanduser("~/.local/share/smon"), "logrotate.stamp")
    if not os.path.isdir(os.path.dirname(stamp)):
        stamp = os.path.join(home, "logrotate.stamp")
    run(home, stamp, force=True)
