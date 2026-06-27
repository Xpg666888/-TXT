import os
import tempfile
from pathlib import Path
from typing import Optional

from .ASRData import ASRDataSeg
from .BaseASR import BaseASR


DEFAULT_MODEL_DIR = r"D:\青柠srt字幕工具箱260601\青柠srt字幕工具箱260601\models\faster-whisper\medium"
DEFAULT_MODEL_NAME = "medium"
PROJECT_MODEL_DIR = str((Path(__file__).resolve().parent.parent / "models" / "faster-whisper" / "medium"))


class WhisperASR(BaseASR):
    """
    本地 faster-whisper 引擎。
    优先加载本地目录模型，找不到时回退到模型名称下载。
    """

    def __init__(self, audio_path: [str, bytes], model: Optional[str] = None, use_cache: bool = False):
        super().__init__(audio_path, use_cache)
        model_candidates = [model, os.getenv("WHISPER_MODEL_PATH"), PROJECT_MODEL_DIR, DEFAULT_MODEL_DIR]
        selected_model = None
        for candidate in model_candidates:
            if not candidate:
                continue
            # 目录存在时优先使用本地模型
            if os.path.isdir(candidate):
                selected_model = candidate
                break
        self.model = selected_model or DEFAULT_MODEL_NAME
        self.compute_type = os.getenv("WHISPER_COMPUTE_TYPE", "int8")
        self.device = os.getenv("WHISPER_DEVICE", "auto")
        self.language = os.getenv("WHISPER_LANGUAGE", "zh")
        self._model_runner = self._build_model_runner()

    def _build_model_runner(self):
        try:
            from faster_whisper import WhisperModel
        except ImportError as exc:
            raise ImportError(
                "未安装 faster-whisper，请先执行: pip install faster-whisper"
            ) from exc
        model_ref = self.model
        if os.path.isdir(model_ref):
            return WhisperModel(model_ref, device=self.device, compute_type=self.compute_type)
        # 非目录时按模型名处理，例如 "medium"
        model_name = model_ref or DEFAULT_MODEL_NAME
        return WhisperModel(model_name, device=self.device, compute_type=self.compute_type)

    def _run(self) -> dict:
        return self._submit()

    def _make_segments(self, resp_data: dict) -> list[ASRDataSeg]:
        return [ASRDataSeg(u["text"], u["start"], u["end"]) for u in resp_data["segments"]]

    def _get_key(self) -> str:
        return f"{self.__class__.__name__}-{self.model}-{self.compute_type}-{self.crc32_hex}"

    def _submit(self) -> dict:
        temp_path = None
        audio_input = self.audio_path
        if isinstance(self.audio_path, bytes):
            tmp = tempfile.NamedTemporaryFile(delete=False, suffix=".mp3")
            tmp.write(self.file_binary)
            tmp.flush()
            tmp.close()
            temp_path = tmp.name
            audio_input = temp_path
        elif isinstance(self.audio_path, str):
            audio_input = self.audio_path
        else:
            audio_input = str(Path(self.audio_path))

        try:
            segments, _info = self._model_runner.transcribe(
                audio=audio_input,
                language=self.language,
                vad_filter=True,
                beam_size=5,
            )
            result = []
            for seg in segments:
                result.append(
                    {
                        "text": seg.text.strip(),
                        "start": int(seg.start * 1000),
                        "end": int(seg.end * 1000),
                    }
                )
            return {"segments": result}
        finally:
            if temp_path and os.path.exists(temp_path):
                os.remove(temp_path)


