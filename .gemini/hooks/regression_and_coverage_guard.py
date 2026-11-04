#!/usr/bin/env python3
"""Gemini CLI Zero-Regression & Mandatory Test Coverage Pipeline Hook.

Operates over SSH on the remote host (or locally if executed directly on the host).

Enforces:
  1. Append-Only Existing Tests: Extending existing test files with new test
     cases is allowed, but deleting or modifying existing lines in committed
     test files is blocked (unless @allow-test-edit is in the prompt).
  2. Mandatory Test Coverage: Any turn that modifies production code CANNOT
     finish unless it also adds new unit/E2E test lines.
  3. Cross-Checkout Red/Green Verification:
     - Run A: HEAD tests against New Prod Code MUST PASS (Zero Regressions).
     - Run B: New tests against HEAD Prod Code MUST FAIL (Proves tests aren't hollow).
     - Run C: New tests against New Prod Code MUST PASS.
"""

import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

# ============================================================================
# PROJECT-SPECIFIC CONFIGURATION
# ============================================================================
REMOTE_HOST = "99.31.213.169"
REMOTE_PORT = 5023
REMOTE_USER = "geonix"
SSH_KEY_PATH = os.path.expanduser("~/.ssh/omv_id_rsa")
REMOTE_REPO_DIR = "/home/geonix/Build/wtt-youtube-organizer"

PROD_FILE_REGEXES = [
    r"(^|/)frontend/lib/.*\.dart$",
    r"(^|/)cmd/.*\.go$",
    r"(^|/)florence_extractor/.*\.py$",
]

UNIT_TEST_REGEXES = [
    r"(^|/)frontend/test/unit/.*\.dart$",
    r"(^|/)frontend/test/widget/.*\.dart$",
    r"(^|/)frontend/test/responsive/.*\.dart$",
    r"(^|/)cmd/.*_test\.go$",
    r"(^|/)florence_extractor/.*_test\.py$",
]

E2E_TEST_REGEXES = [
    r"(^|/)frontend/integration_test/.*\.dart$",
    r"(^|/)cmd/.*/integration_test\.go$",
]

REQUIRE_BOTH_UNIT_AND_E2E = False
ENABLE_RED_GREEN_INVERSION_CHECK = True

ALLOW_TEST_EDIT_RE = re.compile(r"(@allow-test-edit|\[allow-test-edit\])", re.I)
SKIP_TEST_GATE_RE = re.compile(r"(@skip-test-gate|\[skip-test-gate\])", re.I)
# ============================================================================


def emit(payload: dict) -> None:
    sys.stdout.write(json.dumps(payload))
    sys.stdout.flush()
    sys.exit(0)


def log_err(msg: str) -> None:
    sys.stderr.write(f"[regression-pipeline] {msg}\n")
    sys.stderr.flush()


def is_local_execution() -> bool:
    return os.path.isdir(REMOTE_REPO_DIR) and Path(REMOTE_REPO_DIR).resolve() == Path(os.getcwd()).resolve()


def run_remote_sh(cmd_str: str, timeout: int = 30) -> tuple[int, str, str]:
    """Execute command in remote repo directory via SSH or locally if already on host."""
    if is_local_execution():
        p = subprocess.run(
            ["bash", "-c", cmd_str],
            cwd=REMOTE_REPO_DIR,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return p.returncode, p.stdout, p.stderr

    ssh_cmd = [
        "ssh",
        "-p", str(REMOTE_PORT),
        "-i", SSH_KEY_PATH,
        "-o", "BatchMode=yes",
        "-o", "StrictHostKeyChecking=no",
        "-o", "ConnectTimeout=10",
        f"{REMOTE_USER}@{REMOTE_HOST}",
        f"cd {REMOTE_REPO_DIR} && {cmd_str}",
    ]
    try:
        p = subprocess.run(
            ssh_cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return 124, "", "SSH command timed out"
    except Exception as e:
        return 1, "", str(e)


def matches_any(rel_path: str, patterns: list[str]) -> bool:
    norm = rel_path.replace("\\", "/").lstrip("./")
    return any(re.search(p, norm) for p in patterns)


def is_unit_test(rel_path: str) -> bool:
    if is_e2e_test(rel_path):
        return False
    return matches_any(rel_path, UNIT_TEST_REGEXES)


def is_e2e_test(rel_path: str) -> bool:
    return matches_any(rel_path, E2E_TEST_REGEXES)


def is_any_test(rel_path: str) -> bool:
    return is_unit_test(rel_path) or is_e2e_test(rel_path)


def is_prod_file(rel_path: str) -> bool:
    if is_any_test(rel_path):
        return False
    if rel_path.startswith(".gemini/") or rel_path.endswith("GEMINI.md"):
        return False
    return matches_any(rel_path, PROD_FILE_REGEXES)


def is_tracked_in_head(rel_path: str) -> bool:
    code, _, _ = run_remote_sh(f"git cat-file -e 'HEAD:{rel_path}'")
    return code == 0


def get_head_content(rel_path: str) -> str | None:
    code, stdout, _ = run_remote_sh(f"git show 'HEAD:{rel_path}'")
    return stdout if code == 0 else None


def state_path(session_id: str) -> Path:
    safe = re.sub(r"[^a-zA-Z0-9_-]", "_", session_id or "default")
    return Path(f"/tmp/gemini_pipeline_state_{safe}.json")


def load_state(session_id: str) -> dict:
    p = state_path(session_id)
    if p.is_file():
        try:
            return json.loads(p.read_text())
        except Exception:
            pass
    return {}


def save_state(session_id: str, state: dict) -> None:
    try:
        state_path(session_id).write_text(json.dumps(state, indent=2))
    except Exception as e:
        log_err(f"Could not save state: {e}")


def is_pure_addition_replace(old_string: str, new_string: str) -> bool:
    """Return True if `new_string` preserves all non-empty lines of `old_string` in order."""
    old_lines = [line.strip() for line in old_string.splitlines() if line.strip()]
    new_lines = [line.strip() for line in new_string.splitlines() if line.strip()]
    if not old_lines:
        return True
    idx = 0
    for line in new_lines:
        if idx < len(old_lines) and line == old_lines[idx]:
            idx += 1
    return idx == len(old_lines)


def check_git_diff_append_only(rel_path: str) -> tuple[bool, list[str]]:
    """Inspect `git diff -U0 HEAD -- rel_path` on remote to ensure no lines removed."""
    code, stdout, _ = run_remote_sh(f"git diff -U0 HEAD -- '{rel_path}'")
    if code != 0:
        return True, []

    removed_lines = []
    for line in stdout.splitlines():
        if line.startswith("---") or line.startswith("+++") or line.startswith("@@"):
            continue
        if line.startswith("-"):
            stripped = line[1:].strip()
            if stripped and stripped not in ("}", "});", "]);", ");", "};"):
                removed_lines.append(stripped)
    return len(removed_lines) == 0, removed_lines


def count_added_test_lines(rel_path: str) -> int:
    """Count meaningful `+` lines added to a tracked or untracked test file."""
    if not is_tracked_in_head(rel_path):
        code, stdout, _ = run_remote_sh(f"wc -l < '{rel_path}' 2>/dev/null || echo 0")
        try:
            return int(stdout.strip())
        except ValueError:
            return 0

    code, stdout, _ = run_remote_sh(f"git diff -U0 HEAD -- '{rel_path}'")
    if code != 0:
        return 0
    return sum(
        1
        for l in stdout.splitlines()
        if l.startswith("+") and not l.startswith("+++") and l[1:].strip()
    )


def handle_before_agent(data: dict) -> None:
    session_id = data.get("session_id", "default")
    prompt = data.get("prompt", "") or ""
    save_state(
        session_id,
        {
            "prompt": prompt,
            "allow_test_edit": bool(ALLOW_TEST_EDIT_RE.search(prompt)),
            "skip_test_gate": bool(SKIP_TEST_GATE_RE.search(prompt)),
            "retry_count": 0,
        },
    )
    emit({"decision": "allow"})


def handle_before_tool(data: dict) -> None:
    session_id = data.get("session_id", "default")
    state = load_state(session_id)
    if state.get("allow_test_edit"):
        emit({"decision": "allow"})

    tool_name = data.get("tool_name", "")
    tool_input = data.get("tool_input", {}) or {}

    allowed_tools = (
        "replace",
        "write_file",
        "mcp_ssh-remote_ssh-edit-block",
        "mcp_ssh-remote_ssh-write-chunk",
    )
    if tool_name not in allowed_tools:
        emit({"decision": "allow"})

    raw_path = (
        tool_input.get("file_path")
        or tool_input.get("filePath")
        or ""
    )
    if not raw_path:
        emit({"decision": "allow"})

    # Normalize relative path against REMOTE_REPO_DIR
    rel_path = raw_path
    if rel_path.startswith(REMOTE_REPO_DIR + "/"):
        rel_path = rel_path[len(REMOTE_REPO_DIR) + 1:]
    rel_path = rel_path.lstrip("./")

    # New test files are always allowed
    if not is_any_test(rel_path) or not is_tracked_in_head(rel_path):
        emit({"decision": "allow"})

    # Existing committed test file: check for pure addition
    if tool_name in ("replace", "mcp_ssh-remote_ssh-edit-block"):
        old_s = tool_input.get("old_string") or tool_input.get("oldText") or ""
        new_s = tool_input.get("new_string") or tool_input.get("newText") or ""
        if is_pure_addition_replace(old_s, new_s):
            emit({"decision": "allow"})
    elif tool_name in ("write_file", "mcp_ssh-remote_ssh-write-chunk"):
        head_content = get_head_content(rel_path) or ""
        new_content = tool_input.get("content") or ""
        if is_pure_addition_replace(head_content, new_content):
            emit({"decision": "allow"})

    emit(
        {
            "decision": "deny",
            "reason": (
                f"APPEND-ONLY TEST GUARD: '{rel_path}' is an existing committed test file. "
                "You may EXTEND this file by appending new test cases while keeping all "
                "existing test lines intact, or create a new test file. "
                "Modifying or deleting existing test assertions is forbidden unless the user "
                "includes '@allow-test-edit' in their prompt."
            ),
        }
    )


def get_changed_files() -> list[str]:
    cmd = "git diff --name-only HEAD && git ls-files --others --exclude-standard"
    code, stdout, _ = run_remote_sh(cmd)
    if code != 0:
        return []
    return sorted({f.strip() for f in stdout.splitlines() if f.strip()})


def determine_test_command(changed_files: list[str]) -> str | None:
    has_frontend = any(f.startswith("frontend/") for f in changed_files)
    has_cmd = any(f.startswith("cmd/") for f in changed_files)
    has_ml = any(f.startswith("florence_extractor/") for f in changed_files)

    cmds = []
    if has_frontend:
        cmds.append("cd frontend && /home/geonix/Build/flutter/bin/flutter test test/unit/")
    if has_cmd:
        cmds.append("cd cmd/wtt-youtube-organizer/matchfinder_cli && go test -short")
    if has_ml:
        cmds.append("cd florence_extractor && /home/geonix/Build/wtt-youtube-organizer/qwen_venv/bin/python3 -m unittest prod_video_processor_test.py match_start_finder_test.py")

    if not cmds:
        return None
    return " && ".join(cmds)


def run_cross_checkout_verification(
    changed_prod: list[str],
    changed_tests: list[str],
    allow_test_edit: bool,
) -> tuple[bool, str]:
    """Execute the 3-Run Cross-Checkout Matrix (Runs A, B, C) over SSH."""
    test_cmd = determine_test_command(changed_prod + changed_tests)
    if not test_cmd:
        return True, ""

    try:
        # ----------------------------------------------------------------
        # RUN A: Old HEAD Tests vs. New Production Code (Zero Regressions)
        # ----------------------------------------------------------------
        if not allow_test_edit and changed_tests:
            # Revert test files to HEAD temporarily
            tracked_tests = [t for t in changed_tests if is_tracked_in_head(t)]
            untracked_tests = [t for t in changed_tests if not is_tracked_in_head(t)]
            
            stash_setup = ""
            if tracked_tests:
                tests_str = " ".join(f"'{t}'" for t in tracked_tests)
                stash_setup += f"git checkout HEAD -- {tests_str} && "
            
            # Run test command
            run_a_script = (
                "python3 -c '\n"
                "import subprocess, sys\n"
                f"tracked = {json.dumps(tracked_tests)}\n"
                f"untracked = {json.dumps(untracked_tests)}\n"
                "backups = {}\n"
                "for t in tracked + untracked:\n"
                "    try:\n"
                "        with open(t, \"rb\") as f: backups[t] = f.read()\n"
                "    except Exception: backups[t] = None\n"
                "try:\n"
                "    for t in tracked:\n"
                "        subprocess.call([\"git\", \"checkout\", \"HEAD\", \"--\", t])\n"
                "    for t in untracked:\n"
                "        subprocess.call([\"rm\", \"-f\", t])\n"
                f"    res = subprocess.run({json.dumps(test_cmd)}, shell=True, capture_output=True, text=True, timeout=120)\n"
                "    sys.stdout.write(res.stdout)\n"
                "    sys.stderr.write(res.stderr)\n"
                "    ret = res.returncode\n"
                "finally:\n"
                "    for t, content in backups.items():\n"
                "        if content is None: subprocess.call([\"rm\", \"-f\", t])\n"
                "        else:\n"
                "            with open(t, \"wb\") as f: f.write(content)\n"
                "sys.exit(ret)\n"
                "'"
            )
            code_a, stdout_a, stderr_a = run_remote_sh(run_a_script, timeout=150)
            if code_a != 0:
                tail = (stdout_a + "\n" + stderr_a)[-2500:]
                return False, (
                    "RUN A FAILED (EXISTING HEAD TESTS BROKE AGAINST YOUR NEW PROD CODE):\n"
                    "Your production changes caused a regression in existing tests. "
                    "Fix the production code so all pre-existing tests pass:\n\n"
                    f"{tail}"
                )

        # ----------------------------------------------------------------
        # RUN C: New/Extended Tests vs. New Production Code
        # ----------------------------------------------------------------
        code_c, stdout_c, stderr_c = run_remote_sh(test_cmd, timeout=150)
        if code_c != 0:
            tail = (stdout_c + "\n" + stderr_c)[-2500:]
            return False, (
                "RUN C FAILED (TEST SUITE FAILED ON CURRENT WORKING TREE):\n"
                f"{tail}"
            )

        # ----------------------------------------------------------------
        # RUN B: New/Extended Tests vs. Old HEAD Prod Code (Red-Green Check)
        # ----------------------------------------------------------------
        if ENABLE_RED_GREEN_INVERSION_CHECK and changed_prod and changed_tests:
            tracked_prod = [p for p in changed_prod if is_tracked_in_head(p)]
            untracked_prod = [p for p in changed_prod if not is_tracked_in_head(p)]

            run_b_script = (
                "python3 -c '\n"
                "import subprocess, sys\n"
                f"tracked = {json.dumps(tracked_prod)}\n"
                f"untracked = {json.dumps(untracked_prod)}\n"
                "backups = {}\n"
                "for p in tracked + untracked:\n"
                "    try:\n"
                "        with open(p, \"rb\") as f: backups[p] = f.read()\n"
                "    except Exception: backups[p] = None\n"
                "try:\n"
                "    for p in tracked:\n"
                "        subprocess.call([\"git\", \"checkout\", \"HEAD\", \"--\", p])\n"
                "    for p in untracked:\n"
                "        subprocess.call([\"rm\", \"-f\", p])\n"
                f"    res = subprocess.run({json.dumps(test_cmd)}, shell=True, capture_output=True, text=True, timeout=120)\n"
                "    sys.stdout.write(res.stdout)\n"
                "    sys.stderr.write(res.stderr)\n"
                "    ret = res.returncode\n"
                "finally:\n"
                "    for p, content in backups.items():\n"
                "        if content is None: subprocess.call([\"rm\", \"-f\", p])\n"
                "        else:\n"
                "            with open(p, \"wb\") as f: f.write(content)\n"
                "sys.exit(ret)\n"
                "'"
            )
            code_b, stdout_b, stderr_b = run_remote_sh(run_b_script, timeout=150)
            if code_b == 0:
                return False, (
                    "RUN B FAILED (HOLLOW TEST DETECTED): "
                    "When your new/extended tests were run against the OLD (HEAD) production "
                    "code, the test suite still PASSED! A meaningful test for a new feature "
                    "or bugfix must FAIL when the production code changes are reverted, and "
                    "PASS when your production code changes are present. Strengthen your "
                    "test assertions so they actually exercise and verify the new behavior."
                )

    except Exception as e:
        log_err(f"Cross checkout error: {e}")

    return True, ""


def handle_after_agent(data: dict) -> None:
    session_id = data.get("session_id", "default")
    state = load_state(session_id)
    retry_count = state.get("retry_count", 0)

    if data.get("stop_hook_active") and retry_count >= 3:
        emit({"decision": "allow"})

    allow_test_edit = state.get("allow_test_edit", False)
    skip_test_gate = state.get("skip_test_gate", False)

    changed = get_changed_files()
    changed_prod = [f for f in changed if is_prod_file(f)]
    changed_unit = [f for f in changed if is_unit_test(f)]
    changed_e2e = [f for f in changed if is_e2e_test(f)]
    changed_tests = sorted(set(changed_unit + changed_e2e))

    # Gate 1: Verify no existing test lines were removed/modified
    if not allow_test_edit:
        for rel in changed_tests:
            if is_tracked_in_head(rel):
                ok, removed = check_git_diff_append_only(rel)
                if not ok:
                    state["retry_count"] = retry_count + 1
                    save_state(session_id, state)
                    preview = "\n".join(f"  - {l}" for l in removed[:10])
                    emit(
                        {
                            "decision": "deny",
                            "reason": (
                                f"APPEND-ONLY TEST GUARD FAILED on '{rel}':\n"
                                "You modified or deleted existing lines in a committed test file:\n"
                                f"{preview}\n\n"
                                "Restore the original test lines in that file and only APPEND new "
                                "test cases, then fix the production code so the original tests pass."
                            ),
                        }
                    )

    # Gate 2: Mandatory Test Coverage Gate when production files are modified
    if changed_prod and not skip_test_gate:
        unit_lines = sum(count_added_test_lines(f) for f in changed_unit)
        e2e_lines = sum(count_added_test_lines(f) for f in changed_e2e)

        if REQUIRE_BOTH_UNIT_AND_E2E and (unit_lines < 3 or e2e_lines < 3):
            state["retry_count"] = retry_count + 1
            save_state(session_id, state)
            emit(
                {
                    "decision": "deny",
                    "reason": (
                        "MANDATORY TEST COVERAGE GATE: You modified production code "
                        f"({', '.join(changed_prod)}), but did not add/extend BOTH unit tests "
                        f"(added lines: {unit_lines}) and E2E tests (added lines: {e2e_lines}). "
                        "Before finishing, you MUST write or extend both unit and E2E tests "
                        "covering your changes."
                    ),
                }
            )
        elif (unit_lines + e2e_lines) < 3:
            state["retry_count"] = retry_count + 1
            save_state(session_id, state)
            emit(
                {
                    "decision": "deny",
                    "reason": (
                        "MANDATORY TEST COVERAGE GATE: You modified production code "
                        f"({', '.join(changed_prod)}), but did not add or extend any tests. "
                        "Before finishing this turn, you MUST write a new test or extend an "
                        "existing unit/E2E test file to cover your changes."
                    ),
                }
            )

    # Gate 3: Cross-Checkout Verification (Run A, Run B, Run C)
    if changed_prod or changed_tests:
        ok, err_msg = run_cross_checkout_verification(
            changed_prod, changed_tests, allow_test_edit
        )
        if not ok:
            state["retry_count"] = retry_count + 1
            save_state(session_id, state)
            emit({"decision": "deny", "reason": err_msg})

    emit({"decision": "allow"})


def main() -> None:
    try:
        raw = sys.stdin.read()
        data = json.loads(raw) if raw.strip() else {}
    except Exception:
        emit({"decision": "allow"})

    event = data.get("hook_event_name", "")

    if event == "BeforeAgent":
        handle_before_agent(data)
    elif event == "BeforeTool":
        handle_before_tool(data)
    elif event == "AfterAgent":
        handle_after_agent(data)
    else:
        emit({"decision": "allow"})


if __name__ == "__main__":
    main()
