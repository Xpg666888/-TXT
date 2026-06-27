"""从源码目录测试 B 接口，用法: python scripts/test_bcut_source.py [音频路径]"""
import logging
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(message)s")

from bk_asr.BcutASR import BcutASR, MODEL_ID


def main() -> int:
    if len(sys.argv) > 1:
        audio = Path(sys.argv[1])
    else:
        audio = Path(r"D:\FormatFactory\Music\Cheerful\32s Night dance.mp3")
    if not audio.is_file():
        print(f"找不到测试音频: {audio}")
        return 1

    print(f"源码目录: {ROOT}")
    print(f"MODEL_ID={MODEL_ID}")
    print(f"测试文件: {audio}")

    asr = BcutASR(str(audio), use_cache=False)
    result = asr.run()
    print(f"成功，字幕句数: {len(result.segments)}")
    if result.segments:
        print(f"首句: {result.segments[0].text}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"失败: {exc}")
        raise
