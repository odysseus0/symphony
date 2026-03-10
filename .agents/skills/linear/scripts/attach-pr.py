#!/usr/bin/env python3
"""Attach a GitHub PR to a Linear issue.

Usage: python3 attach-pr.py <issue-id> <pr-url> [title]

Env: LINEAR_API_KEY
"""

import json, os, sys, urllib.request

def main():
    if len(sys.argv) < 3:
        print("Usage: python3 attach-pr.py <issue-id> <pr-url> [title]", file=sys.stderr)
        sys.exit(1)

    issue_id = sys.argv[1]
    pr_url = sys.argv[2]
    title = sys.argv[3] if len(sys.argv) > 3 else pr_url

    api_key = os.environ.get("LINEAR_API_KEY")
    if not api_key:
        print("error: LINEAR_API_KEY not set", file=sys.stderr)
        sys.exit(1)

    data = gql(api_key,
        """mutation($issueId: String!, $url: String!, $title: String) {
            attachmentLinkGitHubPR(
                issueId: $issueId, url: $url, title: $title, linkKind: links
            ) { success }
        }""",
        {"issueId": issue_id, "url": pr_url, "title": title},
    )

    if not data["attachmentLinkGitHubPR"]["success"]:
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
