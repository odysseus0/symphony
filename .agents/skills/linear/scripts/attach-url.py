#!/usr/bin/env python3
"""Attach a plain URL to a Linear issue.

Usage: python3 attach-url.py <issue-id> <url> [title]

Use attach-pr.py instead when linking a GitHub PR (richer metadata).

Env: LINEAR_API_KEY
"""

import json, os, sys, urllib.request

def main():
    if len(sys.argv) < 3:
        print("Usage: python3 attach-url.py <issue-id> <url> [title]", file=sys.stderr)
        sys.exit(1)

    issue_id = sys.argv[1]
    url = sys.argv[2]
    title = sys.argv[3] if len(sys.argv) > 3 else url

    api_key = os.environ.get("LINEAR_API_KEY")
    if not api_key:
        print("error: LINEAR_API_KEY not set", file=sys.stderr)
        sys.exit(1)

    data = gql(api_key,
        """mutation($issueId: String!, $url: String!, $title: String) {
            attachmentLinkURL(issueId: $issueId, url: $url, title: $title) { success }
        }""",
        {"issueId": issue_id, "url": url, "title": title},
    )

    if not data["attachmentLinkURL"]["success"]:
        print("error: attach failed", file=sys.stderr)
        sys.exit(1)
    print("attached")


def gql(api_key, query, variables):
    req = urllib.request.Request(
        "https://api.linear.app/graphql",
        data=json.dumps({"query": query, "variables": variables}).encode(),
        headers={"Content-Type": "application/json", "Authorization": api_key},
    )
    resp = json.loads(urllib.request.urlopen(req).read())
    if "errors" in resp:
        print(f"error: {resp['errors'][0]['message']}", file=sys.stderr)
        sys.exit(1)
    return resp["data"]


if __name__ == "__main__":
    main()
