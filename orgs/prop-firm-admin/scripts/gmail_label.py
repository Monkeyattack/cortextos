#!/usr/bin/env python3
"""
Gmail label application script for deal-digest-reader service account.
Called by the workspace agent to apply labels to queued threads.

Domain: monkeyattack.com
Service account: deal-digest-reader (domain-wide delegation)
Scope: gmail.modify (to read labels and modify messages)

Usage:
  python3 gmail_label.py --thread-ids <id1> <id2> ... --label-id <label_id>
  python3 gmail_label.py --thread-ids <id1> <id2> ... --label-name "deal-ingested"
"""

import argparse
import json
import os
import sys

GMAIL_MODIFY_SCOPE = "https://www.googleapis.com/auth/gmail.modify"


# ---------------------------------------------------------------------------
# Credential loading (same as gmail_search.py)
# ---------------------------------------------------------------------------

def load_credentials():
    """
    Load SA JSON + impersonation email from Vault (secret/gmail/) or env fallback.

    Returns (sa_json_str, impersonate_email).
    Raises RuntimeError with a user-friendly message on failure.
    """
    sa_json_str = None
    impersonate_email = None

    # --- Try Vault first ---
    vault_token = os.getenv("VAULT_TOKEN")
    if vault_token:
        # Strategy 1: try hvac via VaultManager
        try:
            sys.path.insert(0, "/home/claude-dev/repos/meta-trader-hub/backend")
            from core.vault_config import VaultManager  # noqa: PLC0415

            v = VaultManager()
            if v.client:
                secret = v.client.secrets.kv.read_secret_version(path="gmail")
                data = secret["data"]["data"]
                sa_json_str = data.get("sa_json")
                impersonate_email = data.get("impersonate_email")
        except Exception:
            pass

        # Strategy 2: vault CLI fallback
        if not sa_json_str:
            try:
                import subprocess  # noqa: PLC0415

                vault_env = {
                    **os.environ,
                    "VAULT_TOKEN": vault_token,
                    "VAULT_ADDR": os.getenv("VAULT_ADDR", "https://127.0.0.1:8200"),
                    "VAULT_SKIP_VERIFY": "true",
                }
                for field, target_var in [("sa_json", "sa_json_str"), ("impersonate_email", "impersonate_email")]:
                    result = subprocess.run(
                        ["vault", "kv", "get", f"-field={field}", "secret/gmail"],
                        capture_output=True, text=True, env=vault_env, timeout=10,
                    )
                    if result.returncode == 0 and result.stdout.strip():
                        if target_var == "sa_json_str":
                            sa_json_str = result.stdout.strip()
                        else:
                            impersonate_email = result.stdout.strip()
            except Exception:
                pass

    # --- Env-var fallback ---
    if not sa_json_str:
        sa_json_str = os.getenv("GMAIL_SA_JSON")
    if not impersonate_email:
        impersonate_email = os.getenv("GMAIL_IMPERSONATE_EMAIL")

    if not sa_json_str:
        raise RuntimeError(
            "SA JSON not found. Set VAULT_TOKEN (with secret/gmail/sa_json) "
            "or GMAIL_SA_JSON env var."
        )
    if not impersonate_email:
        raise RuntimeError(
            "Impersonation email not found. Set VAULT_TOKEN (with secret/gmail/impersonate_email) "
            "or GMAIL_IMPERSONATE_EMAIL env var."
        )

    return sa_json_str, impersonate_email


def build_gmail_service(sa_json_str: str, impersonate_email: str):
    """
    Build an authenticated Gmail API service client with gmail.modify scope.
    """
    from google.oauth2 import service_account  # noqa: PLC0415
    from googleapiclient.discovery import build  # noqa: PLC0415

    sa_info = json.loads(sa_json_str)

    credentials = service_account.Credentials.from_service_account_info(
        sa_info,
        scopes=[GMAIL_MODIFY_SCOPE],
    )
    delegated_credentials = credentials.with_subject(impersonate_email)

    service = build("gmail", "v1", credentials=delegated_credentials, cache_discovery=False)
    return service


# ---------------------------------------------------------------------------
# Label helpers
# ---------------------------------------------------------------------------

def get_label_id_by_name(service, label_name: str) -> str | None:
    """
    Fetch all labels and find the one matching label_name (case-insensitive).
    Returns label ID or None if not found.
    """
    try:
        results = service.users().labels().list(userId="me").execute()
        labels = results.get("labels", [])
        for label in labels:
            if label.get("name", "").lower() == label_name.lower():
                return label.get("id")
    except Exception:
        pass
    return None


def apply_label_to_thread(service, thread_id: str, label_id: str) -> dict:
    """
    Apply a label to a thread.
    Returns {'success': bool, 'thread_id': str, 'label_id': str, 'error': str (if any)}
    """
    try:
        service.users().threads().modify(
            userId="me",
            id=thread_id,
            body={"addLabelIds": [label_id]}
        ).execute()
        return {
            "success": True,
            "thread_id": thread_id,
            "label_id": label_id,
        }
    except Exception as exc:
        return {
            "success": False,
            "thread_id": thread_id,
            "label_id": label_id,
            "error": str(exc),
        }


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def parse_args():
    parser = argparse.ArgumentParser(
        description="Apply Gmail label to threads via service account."
    )
    parser.add_argument(
        "--thread-ids",
        nargs="+",
        required=True,
        help="Thread IDs to label",
    )
    label_group = parser.add_mutually_exclusive_group(required=True)
    label_group.add_argument(
        "--label-id",
        help="Label ID (raw Gmail ID)",
    )
    label_group.add_argument(
        "--label-name",
        help="Label name (e.g. 'deal-ingested')",
    )
    return parser.parse_args()


def emit_error(error: str, message: str, status: str = "auth_error") -> None:
    """Emit a JSON error and exit 1."""
    print(
        json.dumps(
            {
                "status": status,
                "error": error,
                "message": message,
            },
            indent=2,
        )
    )
    sys.exit(1)


def main():
    args = parse_args()

    # --- Load credentials ---
    try:
        sa_json_str, impersonate_email = load_credentials()
    except RuntimeError as exc:
        emit_error(str(exc), "Gmail connector unreachable — re-auth or check SA delegation")

    # --- Build service ---
    try:
        service = build_gmail_service(sa_json_str, impersonate_email)
    except Exception as exc:
        emit_error(str(exc), "Gmail connector unreachable — re-auth or check SA delegation")

    # --- Resolve label ID ---
    label_id = args.label_id
    if args.label_name:
        label_id = get_label_id_by_name(service, args.label_name)
        if not label_id:
            emit_error(
                f"Label '{args.label_name}' not found",
                "Check label name or create it in Gmail first",
                status="label_error"
            )

    # --- Apply label to threads ---
    results = []
    for thread_id in args.thread_ids:
        result = apply_label_to_thread(service, thread_id, label_id)
        results.append(result)

    success_count = sum(1 for r in results if r.get("success"))
    failure_count = len(results) - success_count

    output = {
        "status": "ok" if failure_count == 0 else "partial",
        "label_id": label_id,
        "label_name": args.label_name or "(by ID)",
        "total": len(results),
        "success": success_count,
        "failed": failure_count,
        "results": results,
    }

    print(json.dumps(output, indent=2))
    sys.exit(0 if failure_count == 0 else 1)


if __name__ == "__main__":
    main()
