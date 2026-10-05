"""Check the soak workload and response gates without starting a GPU server."""

import json
import runpy
from pathlib import Path

RUNNER = runpy.run_path(str(Path(__file__).with_name("benchmark-card1.py")))


def response(
    prompt_tokens=9000, completion_tokens=2000, reasoning="r" * 4200, content="answer " * 200, finish_reason="stop"
):
    body = {
        "choices": [{"message": {"content": content, "reasoning_content": reasoning}, "finish_reason": finish_reason}],
        "usage": {"prompt_tokens": prompt_tokens, "completion_tokens": completion_tokens},
    }
    return {"status": 200, "elapsed_s": 90, "body": json.dumps(body)}


def test_soak_request_has_long_varied_thinking_work():
    first = RUNNER["soak_request"](1)
    second = RUNNER["soak_request"](2)
    assert first["chat_template_kwargs"]["enable_thinking"] is True
    assert first["chat_template_kwargs"]["preserve_thinking"] is True
    assert first["reasoning_effort"] == "xhigh"
    assert first["max_tokens"] == 6144
    assert first["messages"][1]["content"].count("SAMPLE-") == 600
    assert first["messages"][1]["content"] != second["messages"][1]["content"]


def test_soak_response_requires_long_prompt_reasoning_and_final_answer():
    validate = RUNNER["validate_soak"]
    assert validate(response())["ok"] is True
    assert validate(response(prompt_tokens=8000))["ok"] is False
    assert validate(response(completion_tokens=1000))["ok"] is False
    assert validate(response(reasoning=""))["ok"] is False
    assert validate(response(content="short"))["ok"] is False
    assert validate(response(finish_reason="length"))["ok"] is False
