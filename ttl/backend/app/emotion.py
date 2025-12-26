from __future__ import annotations

"""
轻量级情绪识别（无外部依赖）。
源自第三方 astrbot_plugin_tts_emotion_router/emotion/infer.py，移植 classify 与默认关键词。
"""

from typing import Dict, List, Optional, Pattern, Set
import re

# 原始项目中的默认关键词列表（保留中文与表情关键词）
DEFAULT_EMOTION_KEYWORDS_LIST: Dict[str, List[str]] = {
    "happy": ["开心", "高兴", "喜欢", "太棒了", "哈哈", "lol", ":)", "😀"],
    "sad": ["难过", "伤心", "失望", "呜呜", "无语", "哭", "sad", ":(", "😢"],
    "angry": ["气死", "愤怒", "生气", "nm", "tmd", "艹", "怒", "怒了", "😡"],
}

EMOTIONS: List[str] = ["neutral", "happy", "sad", "angry"]

# 极简启发式情绪分类器
DEFAULT_KEYWORDS: Dict[str, Set[str]] = {
    k: set(v) for k, v in DEFAULT_EMOTION_KEYWORDS_LIST.items()
}

URL_RE: Pattern = re.compile(r"https?://|www\.")
CODE_BLOCK_RE: Pattern = re.compile(r"```[a-zA-Z0-9_+-]*\n.*?\n```", re.DOTALL)
INLINE_CODE_RE: Pattern = re.compile(r"`([^`\n]+)`")

# Azure SSML 风格映射
EMOTION_STYLE_MAP: Dict[str, str] = {
    "happy": "cheerful",
    "sad": "sad",
    "angry": "angry",
    "neutral": "chat",
}


def is_informational(text: str) -> bool:
    # 包含链接/代码/文件提示等，视为信息性，倾向 neutral
    has_url = bool(URL_RE.search(text or ""))
    has_code_block = bool(CODE_BLOCK_RE.search(text or ""))
    has_inline_code = False
    for match in INLINE_CODE_RE.finditer(text or ""):
        code_content = match.group(1)
        if (
            " " in code_content
            or "\n" in code_content
            or code_content.count(".") > 1
            or code_content.count("/") > 1
            or len(code_content) > 20
        ):
            has_inline_code = True
            break
    return has_url or has_code_block or has_inline_code


def classify(
    text: str,
    context: Optional[List[str]] = None,
    keywords: Optional[Dict[str, Set[str]]] = None,
) -> str:
    # 如果是信息类文本，直接返回 neutral
    if is_informational(text or ""):
        return "neutral"

    t = (text or "").lower()
    score: Dict[str, float] = {"happy": 0.0, "sad": 0.0, "angry": 0.0}

    kw_map = keywords if keywords else DEFAULT_KEYWORDS

    # 简单计数词典命中
    for emo, words in kw_map.items():
        if emo in score:
            for w in words:
                if w.lower() in t:
                    score[emo] += 1.0

    # 感叹号、全大写等作为情绪增强
    if text and "!" in text:
        score["angry"] += 0.5
    if text and text.strip() and text == text.upper() and any(c.isalpha() for c in text):
        score["angry"] += 1.0

    # 上下文弱加权
    if context:
        valid_context = [c for c in context if isinstance(c, str)]
        if valid_context:
            ctx = "\n".join(valid_context[-3:]).lower()
            for emo, words in kw_map.items():
                if emo in score:
                    for w in words:
                        if w.lower() in ctx:
                            score[emo] += 0.2

    label = max(score.keys(), key=lambda k: score[k])
    if score[label] <= 0.5:
        return "neutral"
    return label
