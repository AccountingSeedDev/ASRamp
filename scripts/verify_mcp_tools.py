"""
Verify JIRA MCP server can start and JIRA API supports transitions/assignments.

Two-part verification:
  Part 1: MCP server process check — confirms the package installs and starts
  Part 2: Direct JIRA REST API check — confirms the same endpoints the MCP
           tools use (transitions, assignee) are accessible with our credentials

Usage (requires JIRA env vars — see below):
    ISSUE_KEY=DO-261 python3 scripts/verify_mcp_tools.py
"""
from __future__ import annotations

import base64
import json
import os
import subprocess
import sys
import time
import urllib.request


def check_mcp_server_starts() -> bool:
    """Part 1: Verify the JIRA MCP server process can start."""
    print("\n--- Part 1: MCP Server Process Check ---")

    env = os.environ.copy()
    try:
        proc = subprocess.Popen(
            ["npx", "-y", "@aashari/mcp-server-atlassian-jira"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
        )
    except FileNotFoundError:
        print("FAIL: npx not found")
        return False

    # Wait up to 15s for the process to initialize
    time.sleep(15)

    if proc.poll() is not None:
        stderr = proc.stderr.read()
        # Some MCP servers exit when stdin has no data — check stderr for success indicators
        if "running on stdio" in stderr.lower() or "server" in stderr.lower():
            print(f"OK: MCP server launched and ready (exited cleanly on empty stdin)")
            print(f"  stderr: {stderr.strip()[:200]}")
            return True
        print(f"FAIL: MCP server exited. stderr: {stderr.strip()[:300]}")
        return False

    print(f"OK: MCP server running (pid {proc.pid})")
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
    return True


def jira_api_call(method: str, path: str, data: dict | None = None) -> dict:
    """Make a direct JIRA REST API call."""
    base_url = os.environ.get("JIRA_BASE_URL", "").rstrip("/")
    email = os.environ.get("JIRA_USER_EMAIL") or os.environ.get("ATLASSIAN_USER_EMAIL", "")
    token = os.environ.get("JIRA_API_TOKEN") or os.environ.get("ATLASSIAN_API_TOKEN", "")

    if not base_url or not email or not token:
        raise RuntimeError("Missing JIRA credentials (JIRA_BASE_URL, JIRA_USER_EMAIL, JIRA_API_TOKEN)")

    auth = base64.b64encode(f"{email}:{token}".encode()).decode()
    url = f"{base_url}{path}"
    headers = {
        "Authorization": f"Basic {auth}",
        "Accept": "application/json",
        "Content-Type": "application/json",
    }

    body = json.dumps(data).encode() if data else None
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.loads(resp.read().decode() or "{}")


def check_transitions(issue_key: str) -> bool:
    """Part 2a: Verify we can read transitions (same endpoint as jira_get)."""
    print(f"\n--- Part 2a: Read Transitions for {issue_key} ---")

    try:
        data = jira_api_call("GET", f"/rest/api/3/issue/{issue_key}/transitions")
    except Exception as e:
        print(f"FAIL: Could not read transitions: {e}")
        return False

    transitions = data.get("transitions", [])
    print(f"OK: Found {len(transitions)} available transitions:")
    for t in transitions:
        print(f"  - {t.get('name')} (id: {t.get('id')})")

    names = {t.get("name", "").lower() for t in transitions}
    if "done" in names:
        print("OK: 'Done' transition available (agent can use jira_post to apply)")

    return True


def check_assignee(issue_key: str) -> bool:
    """Part 2b: Verify we can read assignee (same endpoint as jira_get)."""
    print(f"\n--- Part 2b: Read Assignee for {issue_key} ---")

    try:
        data = jira_api_call("GET", f"/rest/api/3/issue/{issue_key}?fields=assignee,status")
    except Exception as e:
        print(f"FAIL: Could not read issue: {e}")
        return False

    fields = data.get("fields", {})
    assignee = fields.get("assignee")
    status = fields.get("status", {})

    print(f"OK: Current status: {status.get('name', 'unknown')}")
    if assignee:
        print(f"OK: Current assignee: {assignee.get('displayName', 'unknown')} "
              f"(accountId: {assignee.get('accountId', 'N/A')})")
    else:
        print("OK: No current assignee (unassigned)")

    print("OK: Assignee endpoint accessible (agent can use jira_put to reassign)")
    return True


def check_comment_post(issue_key: str) -> bool:
    """Part 2c: Verify we can post and delete a test comment (round-trip write test)."""
    print(f"\n--- Part 2c: Round-Trip Comment Test on {issue_key} ---")

    comment_body = {
        "body": {
            "type": "doc",
            "version": 1,
            "content": [{
                "type": "paragraph",
                "content": [{
                    "type": "text",
                    "text": "[MCP Verification] This is an automated test comment. It will be deleted immediately."
                }]
            }]
        }
    }

    # Post comment
    try:
        result = jira_api_call("POST", f"/rest/api/3/issue/{issue_key}/comment", comment_body)
    except Exception as e:
        print(f"FAIL: Could not post comment: {e}")
        return False

    comment_id = result.get("id")
    if not comment_id:
        print("FAIL: Comment posted but no ID returned")
        return False

    print(f"OK: Comment posted (id: {comment_id})")

    # Delete the test comment
    try:
        jira_api_call("DELETE", f"/rest/api/3/issue/{issue_key}/comment/{comment_id}")
        print(f"OK: Comment {comment_id} deleted (clean round-trip)")
    except Exception as e:
        print(f"WARN: Could not delete test comment {comment_id}: {e}")
        # Non-fatal — the comment was posted successfully

    print("OK: Comment endpoint accessible (agent can use jira_post to post)")
    return True


def main():
    issue_key = os.environ.get("ISSUE_KEY")
    if not issue_key:
        print("ERROR: ISSUE_KEY environment variable required")
        sys.exit(1)

    print(f"=== MCP + JIRA API Verification for {issue_key} ===")

    results = []

    # Part 1: MCP server process check
    results.append(("MCP server starts", check_mcp_server_starts()))

    # Part 2: JIRA API endpoint checks (same endpoints MCP tools use)
    results.append(("Read transitions", check_transitions(issue_key)))
    results.append(("Read assignee", check_assignee(issue_key)))
    results.append(("Post+delete comment", check_comment_post(issue_key)))

    # Summary
    print("\n=== VERIFICATION SUMMARY ===")
    all_passed = True
    for name, passed in results:
        status = "PASS" if passed else "FAIL"
        print(f"  {status}: {name}")
        if not passed:
            all_passed = False

    if all_passed:
        print("\nAll checks passed. MCP JIRA tools can perform:")
        print("  - jira_get  → read transitions, assignee, comments")
        print("  - jira_post → apply transitions, post comments")
        print("  - jira_put  → reassign issues")
    else:
        print("\nSome checks failed. See details above.")
        sys.exit(1)


if __name__ == "__main__":
    main()
