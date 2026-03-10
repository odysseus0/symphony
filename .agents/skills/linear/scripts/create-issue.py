#!/usr/bin/env python3
"""Create a Linear issue in a project.

Resolves project slug to projectId and team internally.

Usage: python3 create-issue.py <project-slug> <title> [options]

Options (passed as key=value after positional args):
  description=<text>     Issue description (markdown)
  priority=<0-4>         0=none, 1=urgent, 2=high, 3=medium, 4=low
  state=<name>           Workflow state name (default: Backlog)
  blocked_by=<issue-id>  Issue that blocks this one
  related=<issue-id>     Related issue

Env: LINEAR_API_KEY
"""

import json, os, sys, urllib.request


def main():
    if len(sys.argv) < 3:
        print('Usage: python3 create-issue.py <project-slug> "Title" [key=value ...]', file=sys.stderr)
        sys.exit(1)

    project_slug, title = sys.argv[1], sys.argv[2]
    opts = dict(kv.split("=", 1) for kv in sys.argv[3:] if "=" in kv)

    api_key = os.environ.get("LINEAR_API_KEY")
    if not api_key:
        print("error: LINEAR_API_KEY not set", file=sys.stderr)
        sys.exit(1)

    # Resolve project slug → project ID + team ID
    data = gql(api_key,
        """query($slug: String!) {
            projects(filter: { slugId: { eq: $slug } }) {
                nodes { id teams { nodes { id key states { nodes { id name } } } } }
            }
        }""",
        {"slug": project_slug},
    )

    projects = data["projects"]["nodes"]
    if not projects:
        print(f"error: project '{project_slug}' not found", file=sys.stderr)
        sys.exit(1)

    project = projects[0]
    teams = project["teams"]["nodes"]
    if not teams:
        print("error: project has no teams", file=sys.stderr)
        sys.exit(1)

    team = teams[0]

    # Build input
    issue_input = {
        "title": title,
        "teamId": team["id"],
        "projectId": project["id"],
    }

    if "description" in opts:
        issue_input["description"] = opts["description"]

    if "priority" in opts:
        issue_input["priority"] = int(opts["priority"])

    if "state" in opts:
        states = team["states"]["nodes"]
        target = next((s for s in states if s["name"] == opts["state"]), None)
        if not target:
            available = ", ".join(s["name"] for s in states)
            print(f"error: state '{opts['state']}' not found. Available: {available}", file=sys.stderr)
            sys.exit(1)
        issue_input["stateId"] = target["id"]

    # Create issue
    data = gql(api_key,
        """mutation($input: IssueCreateInput!) {
            issueCreate(input: $input) {
                success
                issue { id identifier title url }
            }
        }""",
        {"input": issue_input},
    )

    if not data["issueCreate"]["success"]:
        print("error: create failed", file=sys.stderr)
        sys.exit(1)

    issue = data["issueCreate"]["issue"]
    print(f"{issue['identifier']} {issue['url']}")

    # Create relation if requested
    for rel_type, opt_key in [("blocks", "blocked_by"), ("related", "related")]:
        if opt_key in opts:
            gql(api_key,
                """mutation($input: IssueRelationCreateInput!) {
                    issueRelationCreate(input: $input) { success }
                }""",
                {"input": {
                    "issueId": issue["id"],
                    "relatedIssueId": opts[opt_key],
                    "type": rel_type,
                }},
            )


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
