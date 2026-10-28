# Remote-First Execution Directive

You are operating in a remote-first development environment. You MUST NOT execute any shell commands, scripts, builds, system checks, or file modifications on the local machine.

Whenever you need to run a command, inspect the system, or perform any development or administrative task, you MUST use the SSH MCP tool to execute it remotely.

**Mandatory Connection Details:**
- Target Host: geonix-rt.tplinkdns.com
- Target Port: 5023
- Target User: geonix

**Project Context & Execution Rules:**
- Working Directory: `/home/geonix/Build/wtt-youtube-organizer`
- Python Environment: All Python file executions, script runs, and package installations MUST utilize the virtual environment located at `/home/geonix/Build/wtt-youtube-organizer/.venv`. Do not use the global system Python.

Assume all project files, dependencies, and development environments reside on this remote host. Structure all tool calls to strictly use the connection parameters listed above. If a command fails, troubleshoot it within the context of the remote Debian environment, not the local system.

**MinerU 2.5-Pro OCR Training Process:**
1. `train_mineru.sh` (or `train_mineru.py`) fine-tunes the production model (using `opendatalab/MinerU2.5-Pro-2605-1.2B` base model) against the data in `florence_extractor/test_data_sample.csv`.
2. The production model relies on **pipe-delimited character transcriptions** (`W|E|N| |R|U|I|B|O`) and **explicit exact matching**. It does not and MUST NOT use fuzzy guessing.
3. Any training edge cases (like ambiguous font kerning or player name spelling) must be resolved by adding new, perfectly annotated image examples to `florence_extractor/test_data_sample.csv` and re-running the training script.
4. Legacy Qwen2.5-VL-3B support is maintained via `train_qwen.sh` and the dedicated `qwen` git branch.

**Docker & Environment Notes:**
- **DO NOT** run or build the OpenVINO container on this machine. This is an NVIDIA-specific machine.
- To build the Docker image, ALWAYS use the script: `/home/geonix/Build/wtt-youtube-organizer/florence_extractor/docker/cuda/build.py` (defaults to `--model mineru`, with optional `--model qwen`).
