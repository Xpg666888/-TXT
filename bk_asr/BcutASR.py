import json
import logging
import threading
import time
from typing import Optional

import requests

from .ASRData import ASRDataSeg
from .BaseASR import BaseASR


__version__ = "0.0.4"

API_BASE_URL = "https://member.bilibili.com/x/bcut/rubick-interface"

API_REQ_UPLOAD = API_BASE_URL + "/resource/create"
API_COMMIT_UPLOAD = API_BASE_URL + "/resource/create/complete"
API_CREATE_TASK = API_BASE_URL + "/task"
API_QUERY_RESULT = API_BASE_URL + "/task/result"

MODEL_ID = "7"
# 平衡速度与稳定性，避免每秒轮询触发风控
POLL_INTERVAL = 10
RESULT_RETRY_INTERVAL = 20
MAX_RESULT_RETRIES = 3
# 接口偶发返回 state=3 时，自动重建一次任务
MAX_TASK_CREATE_RETRIES = 2

HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/124.0.0.0 Safari/537.36"
    ),
    "Accept": "application/json, text/plain, */*",
    "Accept-Language": "zh-CN,zh;q=0.9",
    "Cache-Control": "no-cache",
    "Referer": "https://www.bilibili.com/",
    "Origin": "https://www.bilibili.com",
}


class BcutAPIError(Exception):
    def __init__(self, code, message: str) -> None:
        self.code = code
        self.message = message
        super().__init__(f"{code}: {message}")


class BcutASR(BaseASR):
    """必剪 语音识别接口"""

    _result_lock = threading.Lock()

    def __init__(self, audio_path: [str, bytes], use_cache: bool = False):
        super().__init__(audio_path, use_cache=use_cache)
        self.session = requests.Session()
        self.task_id: Optional[str] = None
        self.__etags: list[str] = []
        self.__in_boss_key: Optional[str] = None
        self.__resource_id: Optional[str] = None
        self.__upload_id: Optional[str] = None
        self.__upload_urls: list[str] = []
        self.__per_size: Optional[int] = None
        self.__clips: Optional[int] = None
        self.__download_url: Optional[str] = None

    def upload(self) -> None:
        if not self.file_binary:
            raise ValueError("none set data")

        payload = {
            "type": 2,
            "name": "audio.mp3",
            "size": len(self.file_binary),
            "ResourceFileType": "mp3",
            "model_id": MODEL_ID,
        }
        resp = self.session.post(
            API_REQ_UPLOAD,
            data=json.dumps(payload),
            headers={**HEADERS, "Content-Type": "application/json"},
            timeout=60,
        )
        if resp.status_code == 412:
            resp.raise_for_status()
        resp.raise_for_status()
        resp_data = resp.json()
        if resp_data.get("code"):
            raise BcutAPIError(resp_data["code"], resp_data.get("message", "unknown error"))
        resp_data = resp_data["data"]

        self.__in_boss_key = resp_data["in_boss_key"]
        self.__resource_id = resp_data["resource_id"]
        self.__upload_id = resp_data["upload_id"]
        self.__upload_urls = resp_data["upload_urls"]
        self.__per_size = resp_data["per_size"]
        self.__clips = len(resp_data["upload_urls"])

        logging.info(
            "申请上传成功, 总计大小%sKB, %s分片, 分片大小%sKB: %s",
            resp_data["size"] // 1024,
            self.__clips,
            resp_data["per_size"] // 1024,
            self.__in_boss_key,
        )
        self.__upload_part()
        self.__commit_upload()

    def __upload_part(self) -> None:
        for clip in range(self.__clips):
            start_range = clip * self.__per_size
            end_range = (clip + 1) * self.__per_size
            logging.info("开始上传分片%s: %s-%s", clip, start_range, end_range)
            resp = self.session.put(
                self.__upload_urls[clip],
                data=self.file_binary[start_range:end_range],
                headers=HEADERS,
                timeout=120,
            )
            resp.raise_for_status()
            etag = resp.headers.get("Etag")
            self.__etags.append(etag)
            logging.info("分片%s上传成功: %s", clip, etag)

    def __commit_upload(self) -> None:
        payload = {
            "InBossKey": self.__in_boss_key,
            "ResourceId": self.__resource_id,
            "Etags": ",".join(self.__etags),
            "UploadId": self.__upload_id,
            "model_id": MODEL_ID,
        }
        resp = self.session.post(
            API_COMMIT_UPLOAD,
            data=json.dumps(payload),
            headers={**HEADERS, "Content-Type": "application/json"},
            timeout=60,
        )
        resp.raise_for_status()
        resp_data = resp.json()
        if resp_data.get("code"):
            raise BcutAPIError(resp_data["code"], resp_data.get("message", "unknown error"))
        self.__download_url = resp_data["data"]["download_url"]
        logging.info("提交成功")

    def create_task(self) -> str:
        resp = self.session.post(
            API_CREATE_TASK,
            json={"resource": self.__download_url, "model_id": MODEL_ID},
            headers={**HEADERS, "Content-Type": "application/json"},
            timeout=60,
        )
        resp.raise_for_status()
        resp_data = resp.json()
        if resp_data.get("code"):
            raise BcutAPIError(resp_data["code"], resp_data.get("message", "unknown error"))
        self.task_id = resp_data["data"]["task_id"]
        logging.info("任务已创建: %s", self.task_id)
        return self.task_id

    def _parse_banned_error(self, resp: requests.Response) -> Optional[BcutAPIError]:
        try:
            data = resp.json()
        except ValueError:
            return None
        code = data.get("code")
        message = data.get("message", "")
        if code == -412 or message == "request was banned":
            return BcutAPIError(
                code,
                "B站接口请求被限流，请等待10~30分钟后重试，并避免同时处理多个文件",
            )
        if code:
            return BcutAPIError(code, message or "unknown error")
        return None

    def result(self, task_id: Optional[str] = None) -> dict:
        with self._result_lock:
            last_error: Optional[Exception] = None
            for attempt in range(MAX_RESULT_RETRIES):
                resp = self.session.get(
                    API_QUERY_RESULT,
                    params={"model_id": MODEL_ID, "task_id": task_id or self.task_id},
                    headers=HEADERS,
                    timeout=60,
                )
                if resp.status_code == 412:
                    api_error = self._parse_banned_error(resp)
                    if api_error:
                        last_error = api_error
                    else:
                        last_error = requests.HTTPError(
                            f"412 Client Error: Precondition Failed for url: {resp.url}",
                            response=resp,
                        )
                    wait = RESULT_RETRY_INTERVAL * (attempt + 1)
                    logging.warning(
                        "查询结果被限流，%ss 后重试 (%s/%s)",
                        wait,
                        attempt + 1,
                        MAX_RESULT_RETRIES,
                    )
                    time.sleep(wait)
                    continue

                resp.raise_for_status()
                data = resp.json()
                code = data.get("code", 0)
                if code not in (0, None):
                    raise BcutAPIError(code, data.get("message", "unknown error"))
                return data["data"]

            if isinstance(last_error, BcutAPIError):
                raise last_error
            if last_error:
                raise last_error
            raise RuntimeError("查询结果失败")

    def _run(self):
        self.upload()
        last_error: Optional[Exception] = None

        for task_attempt in range(MAX_TASK_CREATE_RETRIES):
            self.create_task()
            time.sleep(POLL_INTERVAL)

            task_resp = None
            for _ in range(120):
                task_resp = self.result()
                state = task_resp.get("state")
                if state == 4:
                    logging.info("转换成功")
                    return json.loads(task_resp["result"])
                if state == 3:
                    last_error = BcutAPIError(state, task_resp.get("remark") or "识别失败")
                    logging.warning(
                        "任务失败(state=3)，准备重试创建任务 (%s/%s)",
                        task_attempt + 1,
                        MAX_TASK_CREATE_RETRIES,
                    )
                    break
                time.sleep(POLL_INTERVAL)
            else:
                last_error = RuntimeError("识别超时，请稍后重试")

            if task_attempt < MAX_TASK_CREATE_RETRIES - 1:
                time.sleep(2)
                continue

        if last_error:
            raise last_error
        raise RuntimeError("识别失败，请稍后重试")

    def _make_segments(self, resp_data: dict) -> list[ASRDataSeg]:
        return [
            ASRDataSeg(u["transcript"], u["start_time"], u["end_time"])
            for u in resp_data["utterances"]
        ]


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")
    asr = BcutASR(r"test.mp3")
    print(asr.run())
