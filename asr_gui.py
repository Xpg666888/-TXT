import logging
import os
from pathlib import Path
import platform
import subprocess
import sys
import webbrowser
import time
from typing import List, Tuple

# FIX: 修复中文路径报错 https://github.com/WEIFENG2333/AsrTools/issues/18  设置QT_QPA_PLATFORM_PLUGIN_PATH 
plugin_path = os.path.join(sys.prefix, 'Lib', 'site-packages', 'PyQt5', 'Qt5', 'plugins')
os.environ['QT_QPA_PLATFORM_PLUGIN_PATH'] = plugin_path

from PyQt5.QtCore import Qt, QRunnable, QThreadPool, QObject, pyqtSignal as Signal, pyqtSlot as Slot, QSize, QThread, \
    pyqtSignal
from PyQt5.QtGui import QCursor, QColor, QFont, QIcon
from PyQt5.QtWidgets import (QApplication, QWidget, QVBoxLayout, QHBoxLayout, QFileDialog,
                             QTableWidgetItem, QHeaderView, QSizePolicy)
from qfluentwidgets import (ComboBox, PushButton, LineEdit, TableWidget, FluentIcon as FIF,
                            Action, RoundMenu, InfoBar, InfoBarPosition,
                            FluentWindow, BodyLabel, MessageBox, setThemeColor)

from bk_asr.BcutASR import BcutASR
from bk_asr.JianYingASR import JianYingASR
from bk_asr.KuaiShouASR import KuaiShouASR
from bk_asr.WhisperASR import WhisperASR

APP_NAME = "Forever字幕工厂"
APP_NAME_EN = "Forever Subtitle Factory"
APP_AUTHOR = "Forever"
APP_GITHUB_URL = "https://github.com/Xpg666888/-TXT/upload"
APP_ICON_RELATIVE_PATHS = [
    os.path.join("resources", "app.ico"),
    os.path.join("resources", "app.png"),
]


def resolve_app_asset(relative_path: str) -> str:
    """Resolve asset path for source and PyInstaller modes."""
    if getattr(sys, "frozen", False) and hasattr(sys, "_MEIPASS"):
        base_dir = sys._MEIPASS
    else:
        base_dir = os.path.dirname(os.path.abspath(__file__))
    return os.path.join(base_dir, relative_path)


def load_app_icon() -> QIcon:
    for rel_path in APP_ICON_RELATIVE_PATHS:
        abs_path = resolve_app_asset(rel_path)
        if os.path.exists(abs_path):
            return QIcon(abs_path)
    return QIcon()

# 设置日志配置
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)


class WorkerSignals(QObject):
    finished = Signal(str, str)
    errno = Signal(str, str)


class ASRWorker(QRunnable):
    """ASR处理工作线程"""
    def __init__(self, file_path, asr_engine, export_format, profile='平衡'):
        super().__init__()
        self.file_path = file_path
        self.asr_engine = asr_engine
        self.export_format = export_format
        self.profile = profile
        self.signals = WorkerSignals()

        self.audio_path = None

    @staticmethod
    def _create_engine(engine_name: str, audio_path: str, use_cache: bool):
        if engine_name == 'Whisper':
            return WhisperASR(audio_path, use_cache=use_cache)
        if engine_name == 'B 接口':
            return BcutASR(audio_path, use_cache=use_cache)
        if engine_name == 'J 接口':
            return JianYingASR(audio_path, use_cache=use_cache)
        if engine_name == 'K 接口':
            return KuaiShouASR(audio_path, use_cache=use_cache)
        raise ValueError(f"未知的 ASR 引擎: {engine_name}")

    def _profile_retries(self) -> int:
        if self.profile == '极速':
            return 1
        if self.profile == '稳定':
            return 3
        return 2

    def _run_with_engine_retry(self, engine_name: str, use_cache: bool, retries: int = 2):
        last_error = None
        for attempt in range(1, retries + 1):
            try:
                asr = self._create_engine(engine_name, self.audio_path, use_cache=use_cache)
                logging.info(
                    "开始处理文件: %s 使用引擎: %s (第 %s/%s 次)",
                    self.file_path,
                    engine_name,
                    attempt,
                    retries,
                )
                return asr.run()
            except Exception as exc:
                last_error = exc
                logging.warning(
                    "引擎 %s 第 %s/%s 次失败: %s",
                    engine_name,
                    attempt,
                    retries,
                    str(exc),
                )
                # 给远端接口一点缓冲，避免连续失败
                time.sleep(1.5)
        raise last_error

    def _run_with_fallback(self, use_cache: bool):
        if self.asr_engine == '智能(自动)':
            # 稳定优先：本地Whisper -> B -> J -> K
            engine_chain: List[str] = ['Whisper', 'B 接口', 'J 接口', 'K 接口']
        else:
            engine_chain = [self.asr_engine]

        failures: List[Tuple[str, str]] = []
        retries = self._profile_retries()
        for engine_name in engine_chain:
            try:
                result = self._run_with_engine_retry(engine_name, use_cache=use_cache, retries=retries)
                return result, engine_name
            except Exception as exc:
                failures.append((engine_name, str(exc)))
                logging.warning("引擎 %s 最终失败，准备切换下一个引擎", engine_name)

        detail = " | ".join([f"{name}: {err}" for name, err in failures])
        raise RuntimeError(f"所有可用引擎均失败: {detail}")

    @Slot()
    def run(self):
        try:
            use_cache = True
            
            # 检查文件类型,如果不是音频则转换
            logging.info("[+]正在进ffmpeg转换")
            audio_exts = ['.mp3', '.wav']
            if not any(self.file_path.lower().endswith(ext) for ext in audio_exts):
                temp_audio = self.file_path.rsplit(".", 1)[0] + ".mp3"
                if not video2audio(self.file_path, temp_audio):
                    raise Exception("音频转换失败，确保安装ffmpeg")
                self.audio_path = temp_audio
            else:
                self.audio_path = self.file_path
            
            result, used_engine = self._run_with_fallback(use_cache=use_cache)
            
            # 根据导出格式选择转换方法
            save_ext = self.export_format.lower()
            if save_ext == 'srt':
                result_text = result.to_srt()
            elif save_ext == 'ass':
                result_text = result.to_ass()
            elif save_ext == 'txt':
                result_text = result.to_txt()
                
            logging.info(f"完成处理文件: {self.file_path} 使用引擎: {used_engine}")
            save_path = self.file_path.rsplit(".", 1)[0] + "." + save_ext
            with open(save_path, "w", encoding="utf-8") as f:
                f.write(result_text)
            self.signals.finished.emit(self.file_path, result_text)
        except Exception as e:
            logging.error(f"处理文件 {self.file_path} 时出错: {str(e)}")
            self.signals.errno.emit(self.file_path, f"处理时出错: {str(e)}")

class UpdateCheckerThread(QThread):
    msg = pyqtSignal(str, str, str)  # 用于发送消息的信号

    def __init__(self, parent=None):
        super().__init__(parent)

    def run(self):
        try:
            from check_update import check_update, check_internet_connection
            # 检查互联网连接
            if not check_internet_connection():
                self.msg.emit("错误", "无法连接到互联网，请检查网络连接。", "")
                return
            # 检查更新
            config = check_update(self)
            if config:
                if config['fource']:
                    self.msg.emit("更新", "检测到新版本，请下载最新版本。", config['update_download_url'])
                else:
                    self.msg.emit("可更新", "检测到新版本，请下载最新版本。", config['update_download_url'])
        except Exception as e:
            pass


class ASRWidget(QWidget):
    """ASR处理界面"""

    def __init__(self):
        super().__init__()
        self.init_ui()
        self.max_threads = 3  # 默认最大线程数
        self.thread_pool = QThreadPool()
        self.thread_pool.setMaxThreadCount(self.max_threads)
        self.combo_box.currentTextChanged.connect(self._update_thread_limit)
        self.combo_box.currentTextChanged.connect(self._update_engine_hint)
        self._update_thread_limit(self.combo_box.currentText())
        self._update_engine_hint(self.combo_box.currentText())
        self.processing_queue = []
        self.workers = {}  # 维护文件路径到worker的映射
        self.update_start_button_state()
        self.update_stats()


    def _update_thread_limit(self, engine_name: str):
        """B 接口容易被 B 站限流，批量处理时改为单线程。"""
        limit = 1 if engine_name in ('B 接口', '智能(自动)') else 3
        self.max_threads = limit
        self.thread_pool.setMaxThreadCount(limit)

    def init_ui(self):
        layout = QVBoxLayout(self)

        # ASR引擎选择区域
        engine_layout = QHBoxLayout()
        engine_label = BodyLabel("选择接口:", self)
        engine_label.setFixedWidth(70)
        self.combo_box = ComboBox(self)
        self.combo_box.addItems(['智能(自动)', 'B 接口', 'J 接口', 'K 接口', 'Whisper'])
        engine_layout.addWidget(engine_label)
        engine_layout.addWidget(self.combo_box)
        layout.addLayout(engine_layout)

        self.engine_hint = BodyLabel("", self)
        self.engine_hint.setStyleSheet("color: #6c757d;")
        layout.addWidget(self.engine_hint)

        # 智能策略区域
        strategy_layout = QHBoxLayout()
        strategy_label = BodyLabel("处理策略:", self)
        strategy_label.setFixedWidth(70)
        self.strategy_combo = ComboBox(self)
        self.strategy_combo.addItems(['极速', '平衡', '稳定'])
        self.strategy_combo.setCurrentText('平衡')
        strategy_layout.addWidget(strategy_label)
        strategy_layout.addWidget(self.strategy_combo)
        layout.addLayout(strategy_layout)

        # 导出格式选择区域 
        format_layout = QHBoxLayout()
        format_label = BodyLabel("导出格式:", self)
        format_label.setFixedWidth(70)
        self.format_combo = ComboBox(self)
        self.format_combo.addItems(['SRT', 'TXT', 'ASS'])
        format_layout.addWidget(format_label)
        format_layout.addWidget(self.format_combo)
        layout.addLayout(format_layout)

        # 文件选择区域
        file_layout = QHBoxLayout()
        self.file_input = LineEdit(self)
        self.file_input.setPlaceholderText("拖拽文件或文件夹到这里")
        self.file_input.setReadOnly(True)
        self.file_button = PushButton("选择文件", self)
        self.file_button.clicked.connect(self.select_file)
        self.retry_failed_button = PushButton("重试失败项", self)
        self.retry_failed_button.clicked.connect(self.retry_failed_files)
        self.clear_done_button = PushButton("清理已完成", self)
        self.clear_done_button.clicked.connect(self.clear_finished_rows)
        file_layout.addWidget(self.file_input)
        file_layout.addWidget(self.file_button)
        file_layout.addWidget(self.retry_failed_button)
        file_layout.addWidget(self.clear_done_button)
        layout.addLayout(file_layout)

        stats_layout = QHBoxLayout()
        self.stats_label = BodyLabel("总任务: 0 | 未处理: 0 | 处理中: 0 | 已完成: 0 | 错误: 0", self)
        self.stats_label.setStyleSheet("color: #4b5563;")
        stats_layout.addWidget(self.stats_label)
        layout.addLayout(stats_layout)

        # 文件列表表格
        self.table = TableWidget(self)
        self.table.setColumnCount(2)
        self.table.setHorizontalHeaderLabels(['文件名', '状态'])
        self.table.setContextMenuPolicy(Qt.CustomContextMenu)
        self.table.customContextMenuRequested.connect(self.show_context_menu)
        layout.addWidget(self.table)

        # 设置表格列的拉伸模式
        header = self.table.horizontalHeader()
        header.setSectionResizeMode(0, QHeaderView.Stretch)
        header.setSectionResizeMode(1, QHeaderView.Fixed)
        self.table.setColumnWidth(1, 100)
        self.table.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)

        # 处理按钮
        self.process_button = PushButton("开始处理", self)
        self.process_button.clicked.connect(self.process_files)
        self.process_button.setEnabled(False)  # 初始禁用
        layout.addWidget(self.process_button)

        self.setAcceptDrops(True)

    def _update_engine_hint(self, engine_name: str):
        if engine_name == '智能(自动)':
            self.engine_hint.setText("智能模式: Whisper -> B -> J -> K 自动降级, 兼顾质量和成功率")
        elif engine_name == 'Whisper':
            self.engine_hint.setText("Whisper本地模型: 稳定、离线可用, 建议优先")
        elif engine_name == 'B 接口':
            self.engine_hint.setText("B接口: 精度较好, 但可能触发风控, 已自动限制并发")
        elif engine_name == 'J 接口':
            self.engine_hint.setText("J接口: 速度较快, 接口偶发波动")
        else:
            self.engine_hint.setText("K接口: 响应快, 作为兜底引擎")

    def select_file(self):
        """选择文件对话框"""
        files, _ = QFileDialog.getOpenFileNames(self, "选择音频或视频文件", "",
                                                "Media Files (*.mp3 *.wav *.ogg *.mp4 *.avi *.mov *.ts)")
        for file in files:
            self.add_file_to_table(file)
        self.update_start_button_state()

    def add_file_to_table(self, file_path):
        """将文件添加到表格中"""
        if self.find_row_by_file_path(file_path) != -1:
            InfoBar.warning(
                title='文件已存在',
                content=f"文件 {os.path.basename(file_path)} 已经添加到列表中。",
                orient=Qt.Horizontal,
                isClosable=True,
                position=InfoBarPosition.TOP,
                duration=2000,
                parent=self
            )
            return

        row_count = self.table.rowCount()
        self.table.insertRow(row_count)
        item_filename = self.create_non_editable_item(os.path.basename(file_path))
        item_status = self.create_non_editable_item("未处理")
        item_status.setForeground(QColor("gray"))
        self.table.setItem(row_count, 0, item_filename)
        self.table.setItem(row_count, 1, item_status)
        item_filename.setData(Qt.UserRole, file_path)
        self.update_stats()

    def create_non_editable_item(self, text):
        """创建不可编辑的表格项"""
        item = QTableWidgetItem(text)
        item.setFlags(item.flags() & ~Qt.ItemIsEditable)
        return item

    def show_context_menu(self, pos):
        """显示右键菜单"""
        current_row = self.table.rowAt(pos.y())
        if current_row < 0:
            return

        self.table.selectRow(current_row)

        menu = RoundMenu(parent=self)
        reprocess_action = Action(FIF.SYNC, "重新处理")
        delete_action = Action(FIF.DELETE, "删除任务")
        open_dir_action = Action(FIF.FOLDER, "打开文件目录")
        menu.addActions([reprocess_action, delete_action, open_dir_action])

        delete_action.triggered.connect(self.delete_selected_row)
        open_dir_action.triggered.connect(self.open_file_directory)
        reprocess_action.triggered.connect(self.reprocess_selected_file)

        menu.exec(QCursor.pos())

    def delete_selected_row(self):
        """删除选中的行"""
        current_row = self.table.currentRow()
        if current_row >= 0:
            file_path = self.table.item(current_row, 0).data(Qt.UserRole)
            if file_path in self.workers:
                worker = self.workers[file_path]
                worker.signals.finished.disconnect(self.update_table)
                worker.signals.errno.disconnect(self.handle_error)
                # QThreadPool 不支持直接终止线程，通常需要设计任务可中断
                # 这里仅移除引用
                self.workers.pop(file_path, None)
            self.table.removeRow(current_row)
            self.update_start_button_state()
            self.update_stats()

    def open_file_directory(self):
        """打开文件所在目录"""
        current_row = self.table.currentRow()
        if current_row >= 0:
            current_item = self.table.item(current_row, 0)
            if current_item:
                file_path = current_item.data(Qt.UserRole)
                directory = os.path.dirname(file_path)
                try:
                    if platform.system() == "Windows":
                        os.startfile(directory)
                    elif platform.system() == "Darwin":
                        subprocess.Popen(["open", directory])
                    else:
                        subprocess.Popen(["xdg-open", directory])
                except Exception as e:
                    InfoBar.error(
                        title='无法打开目录',
                        content=str(e),
                        orient=Qt.Horizontal,
                        isClosable=True,
                        position=InfoBarPosition.TOP,
                        duration=3000,
                        parent=self
                    )

    def reprocess_selected_file(self):
        """重新处理选中的文件"""
        current_row = self.table.currentRow()
        if current_row >= 0:
            file_path = self.table.item(current_row, 0).data(Qt.UserRole)
            status = self.table.item(current_row, 1).text()
            if status == "处理中":
                InfoBar.warning(
                    title='当前文件正在处理中',
                    content="请等待当前文件处理完成后再重新处理。",
                    orient=Qt.Horizontal,
                    isClosable=True,
                    position=InfoBarPosition.TOP,
                    duration=3000,
                    parent=self
                )
                return
            self.add_to_queue(file_path)

    def retry_failed_files(self):
        """重试所有失败任务"""
        retry_count = 0
        for row in range(self.table.rowCount()):
            status_item = self.table.item(row, 1)
            if status_item and status_item.text() == "错误":
                file_path = self.table.item(row, 0).data(Qt.UserRole)
                self.processing_queue.append(file_path)
                retry_count += 1
                reset_item = self.create_non_editable_item("未处理")
                reset_item.setForeground(QColor("gray"))
                self.table.setItem(row, 1, reset_item)
        if retry_count:
            self.process_next_in_queue()
            self.update_start_button_state()
            self.update_stats()
        else:
            InfoBar.info(
                title='没有失败任务',
                content="当前列表中没有可重试的失败项。",
                orient=Qt.Horizontal,
                isClosable=True,
                position=InfoBarPosition.TOP,
                duration=2000,
                parent=self
            )

    def clear_finished_rows(self):
        """清理已完成任务行"""
        rows_to_remove = []
        for row in range(self.table.rowCount()):
            status = self.table.item(row, 1).text()
            if status == "已处理":
                rows_to_remove.append(row)
        for row in reversed(rows_to_remove):
            self.table.removeRow(row)
        self.update_start_button_state()
        self.update_stats()

    def add_to_queue(self, file_path):
        """将文件添加到处理队列并更新状态"""
        self.processing_queue.append(file_path)
        self.process_next_in_queue()

    def process_files(self):
        """处理所有未处理的文件"""
        for row in range(self.table.rowCount()):
            if self.table.item(row, 1).text() == "未处理":
                file_path = self.table.item(row, 0).data(Qt.UserRole)
                self.processing_queue.append(file_path)
        self.process_next_in_queue()

    def process_next_in_queue(self):
        """处理队列中的下一个文件"""
        while self.thread_pool.activeThreadCount() < self.max_threads and self.processing_queue:
            file_path = self.processing_queue.pop(0)
            if file_path not in self.workers:
                self.process_file(file_path)

    def process_file(self, file_path):
        """处理单个文件"""
        selected_engine = self.combo_box.currentText()
        selected_format = self.format_combo.currentText()
        selected_profile = self.strategy_combo.currentText()
        worker = ASRWorker(file_path, selected_engine, selected_format, selected_profile)
        worker.signals.finished.connect(self.update_table)
        worker.signals.errno.connect(self.handle_error)
        self.thread_pool.start(worker)
        self.workers[file_path] = worker

        row = self.find_row_by_file_path(file_path)
        if row != -1:
            status_item = self.create_non_editable_item("处理中")
            status_item.setForeground(QColor("orange"))
            self.table.setItem(row, 1, status_item)
            self.update_start_button_state()
            self.update_stats()

    def update_table(self, file_path, result):
        """更新表格中文件的处理状态"""
        row = self.find_row_by_file_path(file_path)
        if row != -1:
            item_status = self.create_non_editable_item("已处理")
            item_status.setForeground(QColor("green"))
            self.table.setItem(row, 1, item_status)

            InfoBar.success(
                title='处理完成',
                content=f"文件 {self.table.item(row, 0).text()} 已处理完成",
                orient=Qt.Horizontal,
                isClosable=True,
                position=InfoBarPosition.TOP,
                duration=1500,
                parent=self
            )

        self.workers.pop(file_path, None)
        self.process_next_in_queue()
        self.update_start_button_state()
        self.update_stats()

    def handle_error(self, file_path, error_message):
        """处理错误信息"""
        row = self.find_row_by_file_path(file_path)
        if row != -1:
            item_status = self.create_non_editable_item("错误")
            item_status.setForeground(QColor("red"))
            self.table.setItem(row, 1, item_status)

            InfoBar.error(
                title='处理出错',
                content=error_message,
                orient=Qt.Horizontal,
                isClosable=True,
                position=InfoBarPosition.TOP,
                duration=3000,
                parent=self
            )

        self.workers.pop(file_path, None)
        self.process_next_in_queue()
        self.update_start_button_state()
        self.update_stats()

    def find_row_by_file_path(self, file_path):
        """根据文件路径查找表格中的行号"""
        for row in range(self.table.rowCount()):
            item = self.table.item(row, 0)
            if item.data(Qt.UserRole) == file_path:
                return row
        return -1

    def update_start_button_state(self):
        """根据文件列表更新开始处理按钮的状态"""
        has_unprocessed = any(
            self.table.item(row, 1).text() == "未处理"
            for row in range(self.table.rowCount())
        )
        self.process_button.setEnabled(has_unprocessed)
        self.retry_failed_button.setEnabled(any(
            self.table.item(row, 1).text() == "错误"
            for row in range(self.table.rowCount())
        ))
        self.clear_done_button.setEnabled(any(
            self.table.item(row, 1).text() == "已处理"
            for row in range(self.table.rowCount())
        ))

    def update_stats(self):
        total = self.table.rowCount()
        status_counts = {"未处理": 0, "处理中": 0, "已处理": 0, "错误": 0}
        for row in range(total):
            status = self.table.item(row, 1).text()
            if status in status_counts:
                status_counts[status] += 1
        self.stats_label.setText(
            f"总任务: {total} | 未处理: {status_counts['未处理']} | "
            f"处理中: {status_counts['处理中']} | 已完成: {status_counts['已处理']} | "
            f"错误: {status_counts['错误']}"
        )

    def dragEnterEvent(self, event):
        """拖拽进入事件"""
        if event.mimeData().hasUrls():
            event.accept()
        else:
            event.ignore()

    def dropEvent(self, event):
        """拖拽释放事件"""
        supported_formats = ('.mp3', '.wav', '.ogg', '.flac', '.aac', '.m4a', '.wma',  # 音频格式
                           '.mp4', '.avi', '.mov', '.ts', '.mkv', '.wmv', '.flv', '.webm', '.rmvb')  # 视频格式
        files = [u.toLocalFile() for u in event.mimeData().urls()]
        for file in files:
            if os.path.isdir(file):
                for root, dirs, files_in_dir in os.walk(file):
                    for f in files_in_dir:
                        if f.lower().endswith(supported_formats):
                            self.add_file_to_table(os.path.join(root, f))
            elif file.lower().endswith(supported_formats):
                self.add_file_to_table(file)
        self.update_start_button_state()
        self.update_stats()


class InfoWidget(QWidget):
    """个人信息界面"""

    def __init__(self):
        super().__init__()
        self.init_ui()

    def init_ui(self):
        # GitHub URL 和仓库描述
        GITHUB_URL = APP_GITHUB_URL
        REPO_DESCRIPTION = """
    🚀 智能引擎：Whisper + B/J/K 多引擎自动降级，更稳更省心。
    🖥️ 高颜值界面：基于 PyQt5 和 qfluentwidgets，简洁高效。
    ⚡ 批量高效：支持批处理、失败重试、任务统计。
    📄 多格式支持：支持生成 .srt / .txt / .ass 字幕文件。
        """
        
        main_layout = QVBoxLayout(self)
        main_layout.setAlignment(Qt.AlignTop)
        # main_layout.setSpacing(50)

        # 标题
        title_label = BodyLabel(f"  {APP_NAME}", self)
        title_label.setFont(QFont("Segoe UI", 30, QFont.Bold))
        title_label.setAlignment(Qt.AlignCenter)
        main_layout.addWidget(title_label)

        subtitle_label = BodyLabel(f"{APP_NAME_EN}  |  作者：{APP_AUTHOR}", self)
        subtitle_label.setFont(QFont("Segoe UI", 11))
        subtitle_label.setStyleSheet("color: #5B8CFF;")
        subtitle_label.setAlignment(Qt.AlignCenter)
        main_layout.addWidget(subtitle_label)

        # 仓库描述区域
        desc_label = BodyLabel(REPO_DESCRIPTION, self)
        desc_label.setFont(QFont("Segoe UI", 12))
        main_layout.addWidget(desc_label)

        github_button = PushButton("GitHub 仓库", self)
        github_button.setIcon(FIF.GITHUB)
        github_button.setIconSize(QSize(20, 20))
        github_button.setMinimumHeight(42)
        github_button.clicked.connect(lambda _: webbrowser.open(GITHUB_URL))
        main_layout.addWidget(github_button)


class MainWindow(FluentWindow):
    """主窗口"""
    def __init__(self):
        super().__init__()
        self.setWindowTitle(APP_NAME)
        self.setWindowIcon(load_app_icon())

        # ASR 处理界面
        self.asr_widget = ASRWidget()
        self.asr_widget.setObjectName("main")
        self.addSubInterface(self.asr_widget, FIF.ALBUM, '字幕处理')

        # 个人信息界面
        self.info_widget = InfoWidget()
        self.info_widget.setObjectName("info")  # 设置对象名称
        self.addSubInterface(self.info_widget, FIF.GITHUB, '关于')

        self.navigationInterface.setExpandWidth(200)
        self.resize(800, 600)

        self.update_checker = UpdateCheckerThread(self)
        self.update_checker.msg.connect(self.show_msg)
        self.update_checker.start()

    def show_msg(self, title, content, update_download_url):
        w = MessageBox(title, content, self)
        if w.exec() and update_download_url:
            webbrowser.open(update_download_url)
        if title == "更新":
            sys.exit(0)

def video2audio(input_file: str, output: str = "") -> bool:
    """使用ffmpeg将视频转换为音频"""
    # 创建output目录
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output = str(output)

    cmd = [
        'ffmpeg',
        '-i', input_file,
        '-ac', '1',
        '-f', 'mp3',
        '-af', 'aresample=async=1',
        '-y',
        output
    ]
    result = subprocess.run(cmd, capture_output=True, check=True, encoding='utf-8', errors='replace')

    if result.returncode == 0 and Path(output).is_file():
        return True
    else:
        return False

def start():
    # enable dpi scale
    QApplication.setHighDpiScaleFactorRoundingPolicy(
        Qt.HighDpiScaleFactorRoundingPolicy.PassThrough)
    QApplication.setAttribute(Qt.AA_EnableHighDpiScaling)
    QApplication.setAttribute(Qt.AA_UseHighDpiPixmaps)

    app = QApplication(sys.argv)
    setThemeColor(QColor("#5B8CFF"))
    logging.info("%s by %s starting...", APP_NAME_EN, APP_AUTHOR)
    window = MainWindow()
    window.show()
    sys.exit(app.exec())


if __name__ == '__main__':
    start()
