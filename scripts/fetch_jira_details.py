#!/usr/bin/env python3
"""Fetch JIRA issue details and write them to GITHUB_ENV.

Pre-fetches summary, description, and reviewer information so the
orchestrator agent doesn't need to spend turns on JIRA API calls.
Also provides ISSUE_DESCRIPTION for the field validation safety net.

Required env vars:
  JIRA_BASE_URL, JIRA_USER_EMAIL, JIRA_API_TOKEN, ISSUE_KEY

Optional env vars:
  JIRA_TO_GH_MAP  – JSON mapping of JIRA display names to GitHub logins
  REVIEWER_OVERRIDE – skip custom-field lookup and use this display name
"""

import base64
import json
import os
import sys
import urllib.error
import urllib.request


def _api_call(base_url: str, email: str, token: str, method: str, path: str, data=None):
    """Make an authenticated JIRA REST API call."""
    auth = base64.b64encode(f"{email}:{token}".encode()).decode()
    headers = {"Authorization": f"Basic {auth}", "Accept": "application/json"}
    if data is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(data).encode()
    url = f"{base_url.rstrip('/')}{path}"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read().decode() or "{}")


def _extract_adf_text(node):
    """Convert Atlassian Document Format JSON to plain text."""
    if isinstance(node, str):
        return node
    if isinstance(node, dict):
        ntype = node.get("type")
        if ntype == "text":
            return node.get("text", "")
        if ntype == "hardBreak":
            return "\n"
        if ntype == "inlineCard":
            return node.get("attrs", {}).get("url", "")
        text = "".join(_extract_adf_text(c) for c in node.get("content", []))
        if ntype in ("paragraph", "heading", "codeBlock", "blockquote",
                     "bulletList", "orderedList", "listItem", "rule"):
            text += "\n"
        return text
    if isinstance(node, list):
        return "".join(_extract_adf_text(n) for n in node)
    return ""


def _extract_reviewer(val):
    """Extract (accountId, displayName, emailAddress) from a custom field value."""
    if isinstance(val, list) and val:
        val = val[0]
    if isinstance(val, dict):
        return (
            val.get("accountId") or "",
            val.get("displayName") or "",
            val.get("emailAddress") or "",
        )
    return ("", "", "")


def main():
    base = (os.environ.get("JIRA_BASE_URL") or "").rstrip("/")
    email = os.environ.get("JIRA_USER_EMAIL") or ""
    token = os.environ.get("JIRA_API_TOKEN") or ""
    issue = os.environ.get("ISSUE_KEY") or ""

    if not base or not email or not token or not issue:
        sys.stderr.write("Missing JIRA_BASE_URL, JIRA_USER_EMAIL, JIRA_API_TOKEN, or ISSUE_KEY\n")
        sys.exit(1)

    # Fetch issue details
    fields = "summary,description,assignee,customfield_11684"
    path = f"/rest/api/3/issue/{issue}?fields={fields}&fieldsByKeys=true&expand=names"
    try:
        data = _api_call(base, email, token, "GET", path)
    except urllib.error.HTTPError as e:
        sys.stderr.write(f"Failed to fetch issue {issue}: {e} {e.read().decode()}\n")
        sys.exit(1)
    except Exception as e:
        sys.stderr.write(f"Failed to fetch issue {issue}: {e}\n")
        sys.exit(1)

    issue_fields = data.get("fields") or {}
    summary = (issue_fields.get("summary") or "").strip()

    # Convert description from ADF to plain text
    desc_raw = issue_fields.get("description")
    if isinstance(desc_raw, dict):
        description = _extract_adf_text(desc_raw).strip()
        if not description:
            description = json.dumps(desc_raw, ensure_ascii=False)
    elif desc_raw is None:
        description = ""
    else:
        description = str(desc_raw)

    # Extract reviewer
    reviewer_override = (os.environ.get("REVIEWER_OVERRIDE") or "").strip()
    reviewer_account_id = ""
    reviewer_display = reviewer_override
    reviewer_email = ""

    if not reviewer_display:
        for key in ("customfield_11684",):
            acc, disp, eml = _extract_reviewer(issue_fields.get(key))
            if disp or acc:
                reviewer_account_id = acc
                reviewer_display = disp
                reviewer_email = eml
                break

    if not summary or not description:
        sys.stderr.write("Missing summary or description from JIRA; failing.\n")
        sys.exit(1)
    if not reviewer_display:
        sys.stderr.write("Missing Reviewer override or customfield_11684 (DevCodingAgent Reviewer) in JIRA; failing.\n")
        sys.exit(1)

    # Map reviewer display name to GitHub login
    map_raw = os.environ.get("JIRA_TO_GH_MAP") or "{}"
    try:
        name_to_gh = json.loads(map_raw)
    except Exception:
        sys.stderr.write("Failed to parse JIRA_TO_GH_MAP secret as JSON; failing.\n")
        sys.exit(1)

    reviewer_gh = (
        name_to_gh.get(reviewer_display)
        or name_to_gh.get(reviewer_display.strip())
        or name_to_gh.get(reviewer_display.strip().lower())
    )
    if not reviewer_gh:
        sys.stderr.write(f"Reviewer '{reviewer_display}' not found in JIRA_TO_GH_MAP; failing.\n")
        sys.exit(1)

    # Write to GITHUB_ENV
    github_env = os.environ.get("GITHUB_ENV")
    if not github_env:
        # Running locally — just print
        print(f"ISSUE_SUMMARY={summary}")
        print(f"ISSUE_DESCRIPTION={description[:200]}...")
        print(f"REVIEWER_ACCOUNT_ID={reviewer_account_id}")
        print(f"REVIEWER_DISPLAY={reviewer_display}")
        print(f"REVIEWER_GH={reviewer_gh}")
        return

    with open(github_env, "a", encoding="utf-8") as envf:
        envf.write(f"ISSUE_SUMMARY={summary}\n")
        envf.write("ISSUE_DESCRIPTION<<EOF\n")
        envf.write(f"{description}\n")
        envf.write("EOF\n")
        envf.write(f"REVIEWER_ACCOUNT_ID={reviewer_account_id}\n")
        envf.write(f"REVIEWER_DISPLAY={reviewer_display}\n")
        envf.write(f"REVIEWER_GH={reviewer_gh}\n")

    print(f"Fetched JIRA details for {issue}: summary={summary[:60]}..., reviewer={reviewer_display} -> {reviewer_gh}")


if __name__ == "__main__":
    main()
