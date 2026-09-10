"""
Rename agent: given a file's current name and its content, suggests a
tidied-up, descriptive file name. Runs on Amazon Bedrock AgentCore Runtime.
"""

import logging
import os
import re

from bedrock_agentcore.runtime import BedrockAgentCoreApp
from strands import Agent, tool
from strands.models import BedrockModel

logging.basicConfig(
    level=getattr(logging, os.environ.get("LOG_LEVEL", "INFO")),
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger("rename-agent")

MODEL_ID = os.environ.get("MODEL_ID", "apac.anthropic.claude-3-5-sonnet-20241022-v2:0")

SYSTEM_PROMPT = """\
You are a meticulous file-naming assistant. Given a file's current name and
its content, propose one better file name for it.

Rules:
- Keep the original file extension unchanged.
- Base the name on what the content is actually about, not on the old name.
- Use lowercase kebab-case (words separated by hyphens), no spaces.
- Only use letters, digits, hyphens, and a single dot before the extension.
- Keep it short: aim for 3-6 words.
- Always call the `sanitize_filename` tool on your candidate name before
  giving your final answer, and return the sanitized result.
- Respond with the final file name only, nothing else.
"""


@tool
def sanitize_filename(candidate: str, extension: str) -> str:
    """Normalize a candidate file name: lowercase kebab-case, safe characters, correct extension.

    Args:
        candidate: The proposed file name or stem.
        extension: The extension to enforce, without a leading dot (e.g. "py").
    """
    stem = re.sub(r"\.[^.]*$", "", candidate)
    stem = stem.strip().lower()
    stem = re.sub(r"[^a-z0-9]+", "-", stem).strip("-")
    stem = stem or "untitled"
    extension = extension.strip().lstrip(".").lower()
    return f"{stem}.{extension}" if extension else stem


def _build_agent() -> Agent:
    model = BedrockModel(
        model_id=MODEL_ID,
        additional_request_fields={"temperature": 0.1, "max_tokens": 200},
    )
    return Agent(model=model, tools=[sanitize_filename], system_prompt=SYSTEM_PROMPT)


app = BedrockAgentCoreApp()
agent = _build_agent()


@app.entrypoint
def rename(payload: dict) -> dict:
    """AgentCore Runtime entrypoint.

    Expected payload: {"file_name": "<current name>", "file_content": "<text>"}
    Returns: {"file_name": "<suggested name>"}
    """
    file_name = payload.get("file_name", "")
    file_content = payload.get("file_content", "")

    logger.info("Renaming request for file_name=%s (%d chars of content)", file_name, len(file_content))

    prompt = (
        f"Current file name: {file_name}\n\n"
        f"File content:\n{file_content[:8000]}"
    )
    response = agent(prompt)

    suggested = ""
    if response and hasattr(response, "message"):
        content = response.message.get("content", [])
        if content:
            suggested = content[0].get("text", "").strip()

    if not suggested:
        logger.warning("Model returned no suggestion; falling back to sanitized original name.")
        extension = file_name.rsplit(".", 1)[-1] if "." in file_name else ""
        suggested = sanitize_filename(file_name, extension)

    return {"file_name": suggested}


if __name__ == "__main__":
    app.run()
