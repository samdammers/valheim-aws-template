"""
Valheim server management Lambda.

Routes:
  GET  /start   - Start the EC2 instance
  GET  /stop    - Stop the EC2 instance
  GET  /status  - Instance state + public IP
  POST /discord - Discord Interactions Endpoint (slash commands: /valheim-start,
                   /valheim-stop, /valheim-status). Authenticated by Discord's Ed25519
                   request signature, not AWS auth - Discord's servers call this
                   directly and there's no IP to allowlist. Uses Discord Deferred
                   Responses (type 5) with asynchronous background processing to
                   reliably respond in <100ms and avoid Discord's 3-second timeout.
Scheduled event - {"scheduled_action": "check_idle"}: stop the instance if it looks
                   idle (low average network activity over a trailing window), unless
                   it's still within its post-start grace period.
Async event     - {"async_action": "discord_command"}: asynchronous execution of
                   slash commands invoked by the synchronous /discord router.
"""
import base64
import json
import os
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

import boto3
import nacl.exceptions
import nacl.signing

INSTANCE_ID = os.environ["INSTANCE_ID"]
IDLE_WINDOW_MINUTES = int(os.environ.get("IDLE_WINDOW_MINUTES", "30"))
IDLE_GRACE_PERIOD_MINUTES = int(os.environ.get("IDLE_GRACE_PERIOD_MINUTES", "20"))
IDLE_THRESHOLD_BYTES = float(os.environ.get("IDLE_THRESHOLD_BYTES", "100000"))
DISCORD_PUBLIC_KEY = os.environ.get("DISCORD_PUBLIC_KEY", "")
DISCORD_WEBHOOK_URL = os.environ.get("DISCORD_WEBHOOK_URL", "")
SERVER_ADDRESS = os.environ.get("SERVER_ADDRESS", "")
CREDENTIALS_SECRET_ARN = os.environ.get("CREDENTIALS_SECRET_ARN", "")

DISCORD_EPHEMERAL_FLAG = 64  # only the command's caller sees the response

# Module-level client and secret caches (reused across warm invocations)
_CACHED_SESSION = None
_CACHED_EC2 = None
_CACHED_CW = None
_CACHED_SM = None
_CACHED_LAMBDA = None
_CACHED_SERVER_PASSWORD = None


def get_session():
    global _CACHED_SESSION
    if _CACHED_SESSION is None:
        _CACHED_SESSION = boto3.session.Session()
    return _CACHED_SESSION


def get_ec2_client():
    global _CACHED_EC2
    if _CACHED_EC2 is None:
        _CACHED_EC2 = get_session().client("ec2")
    return _CACHED_EC2


def get_cloudwatch_client():
    global _CACHED_CW
    if _CACHED_CW is None:
        _CACHED_CW = get_session().client("cloudwatch")
    return _CACHED_CW


def get_secrets_client():
    global _CACHED_SM
    if _CACHED_SM is None:
        _CACHED_SM = get_session().client("secretsmanager")
    return _CACHED_SM


def get_lambda_client():
    global _CACHED_LAMBDA
    if _CACHED_LAMBDA is None:
        _CACHED_LAMBDA = get_session().client("lambda")
    return _CACHED_LAMBDA


def get_server_password():
    global _CACHED_SERVER_PASSWORD
    if _CACHED_SERVER_PASSWORD is None:
        if not CREDENTIALS_SECRET_ARN:
            return ""
        resp = get_secrets_client().get_secret_value(SecretId=CREDENTIALS_SECRET_ARN)
        _CACHED_SERVER_PASSWORD = json.loads(resp["SecretString"]).get("SERVER_PASS", "")
    return _CACHED_SERVER_PASSWORD


# ---------------------------------------------------------------------------
# EC2 management
# ---------------------------------------------------------------------------

def start_instance(ec2_client):
    ec2_client.start_instances(InstanceIds=[INSTANCE_ID])
    return f"Starting instance {INSTANCE_ID}"


def stop_instance(ec2_client):
    ec2_client.stop_instances(InstanceIds=[INSTANCE_ID])
    return f"Stopping instance {INSTANCE_ID}"


def format_uptime(launch_time):
    seconds = (datetime.now(timezone.utc) - launch_time).total_seconds()
    hours, minutes = divmod(int(seconds) // 60, 60)
    return f"{hours}h {minutes}m" if hours else f"{minutes}m"


def instance_status(ec2_client):
    resp = ec2_client.describe_instances(InstanceIds=[INSTANCE_ID])
    instance = resp["Reservations"][0]["Instances"][0]
    status = {
        "state": instance["State"]["Name"],
        "public_ip": instance.get("PublicIpAddress"),
    }
    if status["state"] == "running":
        status["uptime"] = format_uptime(instance["LaunchTime"])
    return status


# ---------------------------------------------------------------------------
# Discord webhook notifications - proactive posts (unlike slash-command
# responses, which reply to an interaction Discord initiated).
# ---------------------------------------------------------------------------

def notify_discord(content):
    if not DISCORD_WEBHOOK_URL:
        return
    req = urllib.request.Request(
        DISCORD_WEBHOOK_URL,
        data=json.dumps({"content": content}).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        urllib.request.urlopen(req, timeout=5)
    except urllib.error.URLError as exc:
        print(f"WARN: failed to post Discord webhook notification: {exc}")


# ---------------------------------------------------------------------------
# Idle detection - called on a schedule (EventBridge, every N minutes)
# ---------------------------------------------------------------------------

def check_idle(ec2_client, cloudwatch_client):
    resp = ec2_client.describe_instances(InstanceIds=[INSTANCE_ID])
    instance = resp["Reservations"][0]["Instances"][0]

    if instance["State"]["Name"] != "running":
        return "Instance not running - nothing to check"

    launch_time = instance["LaunchTime"]
    now = datetime.now(timezone.utc)
    minutes_running = (now - launch_time).total_seconds() / 60

    if minutes_running < IDLE_GRACE_PERIOD_MINUTES:
        return (
            f"Within grace period ({minutes_running:.0f}m < "
            f"{IDLE_GRACE_PERIOD_MINUTES}m since start) - skipping idle check"
        )

    end = now
    start = end - timedelta(minutes=IDLE_WINDOW_MINUTES)
    metrics = cloudwatch_client.get_metric_statistics(
        Namespace="AWS/EC2",
        MetricName="NetworkIn",
        Dimensions=[{"Name": "InstanceId", "Value": INSTANCE_ID}],
        StartTime=start,
        EndTime=end,
        Period=IDLE_WINDOW_MINUTES * 60,
        Statistics=["Average"],
    )

    datapoints = metrics.get("Datapoints", [])
    if not datapoints:
        return "No CloudWatch datapoints yet - skipping idle check"

    avg_bytes = datapoints[0]["Average"]
    if avg_bytes < IDLE_THRESHOLD_BYTES:
        stop_instance(ec2_client)
        message = (
            f"Idle (avg NetworkIn {avg_bytes:.0f}B < {IDLE_THRESHOLD_BYTES:.0f}B "
            f"over {IDLE_WINDOW_MINUTES}m) - stopping instance"
        )
        notify_discord(f":zzz: Valheim server auto-stopped - no activity for {IDLE_WINDOW_MINUTES}m")
        return message

    return f"Active (avg NetworkIn {avg_bytes:.0f}B) - leaving instance running"


# ---------------------------------------------------------------------------
# Discord Interactions (slash commands over HTTPS webhook)
# ---------------------------------------------------------------------------

def verify_discord_signature(headers, raw_body):
    signature = headers.get("x-signature-ed25519")
    timestamp = headers.get("x-signature-timestamp")
    if not signature or not timestamp or not DISCORD_PUBLIC_KEY:
        return False
    try:
        verify_key = nacl.signing.VerifyKey(bytes.fromhex(DISCORD_PUBLIC_KEY))
        verify_key.verify((timestamp + raw_body).encode(), bytes.fromhex(signature))
        return True
    except (nacl.exceptions.BadSignatureError, ValueError):
        return False


def discord_response(body_dict):
    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body_dict),
    }


def discord_message(content, ephemeral=False):
    data = {"content": content}
    if ephemeral:
        data["flags"] = DISCORD_EPHEMERAL_FLAG
    return discord_response({"type": 4, "data": data})


def discord_invoker_name(interaction):
    user = interaction.get("member", {}).get("user") or interaction.get("user", {})
    return user.get("global_name") or user.get("username") or "someone"


def edit_discord_interaction_response(application_id, token, content):
    """Update Discord's original interaction message via webhook PATCH."""
    url = f"https://discord.com/api/v10/webhooks/{application_id}/{token}/messages/@original"
    req = urllib.request.Request(
        url,
        data=json.dumps({"content": content}).encode(),
        headers={
            "Content-Type": "application/json",
            "User-Agent": "ValheimManagerLambda (https://github.com/samdammers/valheim-aws-template, 1.0)",
        },
        method="PATCH",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            print(f"Discord original interaction updated (status {resp.status})")
    except urllib.error.URLError as exc:
        print(f"ERROR: failed to update Discord interaction response: {exc}")
        if hasattr(exc, "read"):
            try:
                print(f"Details: {exc.read().decode(errors='replace')}")
            except Exception:
                pass


def invoke_async_worker(payload, context=None):
    """Invoke this same Lambda function asynchronously with InvocationType='Event'."""
    lambda_client = get_lambda_client()
    function_name = (
        context.function_name
        if context and hasattr(context, "function_name")
        else os.environ.get("AWS_LAMBDA_FUNCTION_NAME", "valheim-manager")
    )
    lambda_client.invoke(
        FunctionName=function_name,
        InvocationType="Event",
        Payload=json.dumps(payload),
    )


def handle_discord_interaction(event, context):
    """
    Handle synchronous POST /discord webhook calls from Discord.
    
    Verifies signature and immediately returns:
    - type 1 (PONG) for PING (endpoint verification)
    - type 5 (DEFERRED_CHANNEL_MESSAGE_WITH_SOURCE) for slash commands,
      dispatching the actual work to an async Lambda invocation to guarantee
      response in <100ms and avoid Discord's 3-second timeout limit.
    """
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    raw_body = event.get("body") or ""
    if event.get("isBase64Encoded"):
        raw_body = base64.b64decode(raw_body).decode()

    if not verify_discord_signature(headers, raw_body):
        return {"statusCode": 401, "body": json.dumps("invalid request signature")}

    try:
        interaction = json.loads(raw_body)
    except Exception as exc:
        print(f"ERROR: invalid interaction JSON: {exc}")
        return {"statusCode": 400, "body": json.dumps("invalid json body")}

    interaction_type = interaction.get("type")

    # PING - Discord's endpoint-verification handshake.
    if interaction_type == 1:
        return discord_response({"type": 1})

    # APPLICATION_COMMAND - Slash commands.
    if interaction_type == 2:
        invoke_async_worker(
            {
                "async_action": "discord_command",
                "interaction": interaction,
            },
            context=context,
        )
        # Deferred response: Discord displays "Bot is thinking..." and allows up to 15m for followup
        return discord_response({"type": 5})

    return discord_message("Unsupported interaction type")


def process_discord_command(interaction):
    """Execute the slash command and format the response message."""
    command = interaction.get("data", {}).get("name")
    ec2_client = get_ec2_client()

    try:
        if command == "valheim-start":
            status = instance_status(ec2_client)
            state = status["state"]

            if state == "running":
                content = f"Already running (up {status['uptime']})"
                invoker_line = f"Checked by {discord_invoker_name(interaction)}"
            elif state == "stopped":
                content = start_instance(ec2_client)
                invoker_line = f"Started by {discord_invoker_name(interaction)}"
            elif state in ("pending", "stopping", "shutting-down"):
                content = f"Server is currently **{state}**. Please wait a moment before trying to start."
                invoker_line = f"Checked by {discord_invoker_name(interaction)}"
            else:
                content = f"Server is in unexpected state: **{state}**"
                invoker_line = f"Checked by {discord_invoker_name(interaction)}"

            if state in ("running", "stopped"):
                content += f"\n\nConnect: `{SERVER_ADDRESS}`\nPassword: `{get_server_password()}`"
            content += f"\n{invoker_line}"
            return content

        if command == "valheim-stop":
            status = instance_status(ec2_client)
            state = status["state"]

            if state == "stopped":
                content = "Already stopped"
            elif state == "stopping":
                content = "Server is already stopping..."
            elif state == "running":
                content = stop_instance(ec2_client)
            elif state == "pending":
                content = "Server is currently starting up (pending), please wait before stopping."
            else:
                content = f"Server is currently **{state}**, cannot stop right now."
            content += f"\nStopped by {discord_invoker_name(interaction)}"
            return content

        if command == "valheim-status":
            status = instance_status(ec2_client)
            state = status["state"]
            content = f"State: {state}"
            if state == "running":
                content += f" (up {status['uptime']})"
                content += f"\n\nConnect: `{SERVER_ADDRESS}`\nPassword: `{get_server_password()}`"
            elif state in ("stopping", "pending"):
                content += " (transitioning)"
            return content

        return f"Unknown command: {command}"
    except Exception as exc:  # pylint: disable=broad-except
        print(f"ERROR: failed executing command '{command}': {exc}")
        return f":warning: Failed to execute `/{command}`: {exc}"


def handle_async_discord_command(event):
    """Handle asynchronous background execution of a Discord slash command."""
    interaction = event.get("interaction", {})
    app_id = interaction.get("application_id")
    token = interaction.get("token")

    if not app_id or not token:
        print("ERROR: missing application_id or token in async discord interaction event")
        return

    content = process_discord_command(interaction)
    edit_discord_interaction_response(app_id, token, content)


# ---------------------------------------------------------------------------
# Lambda handler
# ---------------------------------------------------------------------------

def lambda_handler(event, context):
    print(json.dumps(event))

    # Asynchronous Discord slash command worker
    if event.get("async_action") == "discord_command":
        handle_async_discord_command(event)
        return {"statusCode": 200, "body": json.dumps("ok")}

    # Scheduled EventBridge idle check
    if event.get("scheduled_action") == "check_idle":
        msg = check_idle(get_ec2_client(), get_cloudwatch_client())
        return {"statusCode": 200, "body": json.dumps(msg)}

    route = event.get("path", "")

    # Synchronous API Gateway /discord route
    if route == "/discord":
        try:
            return handle_discord_interaction(event, context)
        except Exception as exc:  # pylint: disable=broad-except
            print(f"ERROR in handle_discord_interaction: {exc}")
            return {"statusCode": 500, "body": json.dumps(str(exc))}

    if event.get("httpMethod", "GET") != "GET":
        return {"statusCode": 400, "body": json.dumps("Bad Request")}

    ec2 = get_ec2_client()

    try:
        if route == "/start":
            body = start_instance(ec2)
        elif route == "/stop":
            body = stop_instance(ec2)
        elif route == "/status":
            body = json.dumps(instance_status(ec2))
            return {"statusCode": 200, "body": body}
        else:
            return {"statusCode": 404, "body": json.dumps(f"Unknown route: {route}")}
    except Exception as exc:  # pylint: disable=broad-except
        print(f"ERROR: {exc}")
        return {"statusCode": 500, "body": json.dumps(str(exc))}

    return {"statusCode": 200, "body": json.dumps(body)}
