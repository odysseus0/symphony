#!/usr/bin/env python3
"""Move a Linear issue to a named workflow state.

Resolves state name to stateId internally.

Usage: python3 move-issue.py <issue-id> <state-name>

Env: LINEAR_API_KEY
"""

import json, os, sys, urllib.request

def main():
    if len(sys.argv) < 3:
        print('Usage: python3 move-issue.py <issue-id> "State Name"', file=sys.stderr)
        sys.exit(1)

    issue_id, state_name = sys.argv[1], sys.argv[2]
    api_key = os.environ.get("LINEAR_API_KEY")
    if not api_key:
        print("error: LINEAR_API_KEY not set", file=sys.stderr)
        sys.exit(1)

    # Fetch team states
    data = gql(api_key,
        """query($id: String!) {
            issue(id: $id) {
                team { states { nodes { id name } } }
            }
        }""",
        {"id": issue_id},
    )

    states = data["issue"]["team"]["states"]["nodes"]
    target = next((s for s in states if s["name"] == state_name), None)
    if not target:
        available = ", ".join(s["name"] for s in states)
        print(f"error: state '{state_name}' not found. Available: {available}", file=sys.stderr)
        sys.exit(1)

    # Move issue
    data = gql(api_key,
        """mutation($id: String!, $stateId: String!) {
            issueUpdate(id: $id, input: { stateId: $stateId }) {
                success
                issue { state { name } }
            }
        }""",
        {"id": issue_id, "stateId": target["id"]},
    )

    if not data["issueUpdate"]["success"]:
        print("error: move failed", file=sys.stderr)
        sys.exit(1)
    print(f"moved to {data['issueUpdate']['issue']['state']['name']}")


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
