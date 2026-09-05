"""
Valheim server management Lambda.

Routes:
  GET  /start   — Start the EC2 instance
  GET  /stop    — Stop the EC2 instance
  GET  /status  — Instance state + public IP
  POST /discord — Discord Interactions Endpoint (slash commands: /valheim-start,
                   /valheim-stop, /valheim-status). Authenticated by Discord's Ed25519
                   request signature, not AWS auth — Discord's servers call this
                   directly and there's no IP to allowlist. /valheim-start and
                   /valheim-status also return the connect address + password,
                   ephemerally (only the command's caller sees it) — the plain HTTP
                   /status route below never includes the password.
Scheduled event  — {"scheduled_action": "check_idle"}: stop the instance if it looks
                    idle (low average network activity over a trailing window), unless
                    it's still within its post-start grace period.
"""
import base64
import json
import os
from datetime import datetime, timedelta, timezone

import boto3
import nacl.exceptions
import nacl.signing

INSTANCE_ID = os.environ["INSTANCE_ID"]
IDLE_WINDOW_MINUTES = int(os.environ.get("IDLE_WINDOW_MINUTES", "30"))
IDLE_GRACE_PERIOD_MINUTES = int(os.environ.get("IDLE_GRACE_PERIOD_MINUTES", "20"))
IDLE_THRESHOLD_BYTES = float(os.environ.get("IDLE_THRESHOLD_BYTES", "100000"))
DISCORD_PUBLIC_KEY = os.environ.get("DISCORD_PUBLIC_KEY", "")
SERVER_ADDRESS = os.environ.get("SERVER_ADDRESS", "")
CREDENTIALS_SECRET_ARN = os.environ.get("CREDENTIALS_SECRET_ARN", "")

DISCORD_EPHEMERAL_FLAG = 64  # only the command's caller sees the response


# ---------------------------------------------------------------------------
# EC2 management
# ---------------------------------------------------------------------------

def start_instance(ec2_client):
    ec2_client.start_instances(InstanceIds=[INSTANCE_ID])
    return f"Starting instance {INSTANCE_ID}"


def stop_instance(ec2_client):
    ec2_client.stop_instances(InstanceIds=[INSTANCE_ID])
    return f"Stopping instance {INSTANCE_ID}"


def instance_status(ec2_client):
    resp = ec2_client.describe_instances(InstanceIds=[INSTANCE_ID])
    instance = resp["Reservations"][0]["Instances"][0]
    return {
        "state": instance["State"]["Name"],
        "public_ip": instance.get("PublicIpAddress"),
    }


# ---------------------------------------------------------------------------
# Idle detection — called on a schedule (EventBridge, every N minutes)
# ---------------------------------------------------------------------------

def check_idle(ec2_client, cloudwatch_client):
    resp = ec2_client.describe_instances(InstanceIds=[INSTANCE_ID])
    instance = resp["Reservations"][0]["Instances"][0]

    if instance["State"]["Name"] != "running":
        return "Instance not running — nothing to check"

    launch_time = instance["LaunchTime"]
    now = datetime.now(timezone.utc)
    minutes_running = (now - launch_time).total_seconds() / 60

    if minutes_running < IDLE_GRACE_PERIOD_MINUTES:
        return (
            f"Within grace period ({minutes_running:.0f}m < "
            f"{IDLE_GRACE_PERIOD_MINUTES}m since start) — skipping idle check"
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
        return "No CloudWatch datapoints yet — skipping idle check"

    avg_bytes = datapoints[0]["Average"]
    if avg_bytes < IDLE_THRESHOLD_BYTES:
        stop_instance(ec2_client)
        return (
            f"Idle (avg NetworkIn {avg_bytes:.0f}B < {IDLE_THRESHOLD_BYTES:.0f}B "
            f"over {IDLE_WINDOW_MINUTES}m) — stopping instance"
        )

    return f"Active (avg NetworkIn {avg_bytes:.0f}B) — leaving instance running"


# ---------------------------------------------------------------------------
# Discord Interactions (slash commands over a plain HTTPS webhook — no gateway
# connection, no always-on bot process needed)
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


def get_server_password(secrets_client):
    resp = secrets_client.get_secret_value(SecretId=CREDENTIALS_SECRET_ARN)
    return json.loads(resp["SecretString"])["SERVER_PASS"]


def discord_response(body_dict):
    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body_dict),
    }


def discord_message(content, ephemeral=True):
    data = {"content": content}
    if ephemeral:
        data["flags"] = DISCORD_EPHEMERAL_FLAG
    return discord_response({"type": 4, "data": data})


def handle_discord_interaction(event):
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    raw_body = event.get("body") or ""
    if event.get("isBase64Encoded"):
        raw_body = base64.b64decode(raw_body).decode()

    if not verify_discord_signature(headers, raw_body):
        return {"statusCode": 401, "body": json.dumps("invalid request signature")}

    interaction = json.loads(raw_body)
    interaction_type = interaction.get("type")

    # PING — Discord's endpoint-verification handshake. Deliberately touches no AWS
    # SDK client at all: constructing a boto3 EC2 client alone costs ~3s (parsing its
    # large service model), which blew well past whatever timeout Discord enforces on
    # this handshake and was the actual cause of "endpoint could not be verified."
    if interaction_type == 1:
        return discord_response({"type": 1})

    if interaction_type == 2:  # APPLICATION_COMMAND
        sess = boto3.session.Session()
        ec2_client = sess.client("ec2")
        command = interaction.get("data", {}).get("name")

        # /valheim-start and /valheim-status also hand back how to connect (address +
        # password) — ephemeral (visible only to whoever ran the command), even though
        # this Discord is invite-only, so the password doesn't sit in plain channel
        # history/screenshots. The plain HTTP /status route never gets the password.
        if command == "valheim-start":
            content = start_instance(ec2_client)
            content += f"\n\nConnect: `{SERVER_ADDRESS}`\nPassword: `{get_server_password(sess.client('secretsmanager'))}`"
        elif command == "valheim-stop":
            content = stop_instance(ec2_client)
        elif command == "valheim-status":
            status = instance_status(ec2_client)
            content = f"State: {status['state']}"
            if status["state"] == "running":
                content += f"\n\nConnect: `{SERVER_ADDRESS}`\nPassword: `{get_server_password(sess.client('secretsmanager'))}`"
        else:
            content = f"Unknown command: {command}"

        return discord_message(content)

    return discord_message("Unsupported interaction type")


# ---------------------------------------------------------------------------
# Lambda handler
# ---------------------------------------------------------------------------

def lambda_handler(event, context):
    print(json.dumps(event))
    route = event.get("path", "")

    # Handled entirely without touching boto3 — see handle_discord_interaction for why.
    if route == "/discord":
        return handle_discord_interaction(event)

    sess = boto3.session.Session()
    ec2 = sess.client("ec2")

    if event.get("scheduled_action") == "check_idle":
        msg = check_idle(ec2, sess.client("cloudwatch"))
        return {"statusCode": 200, "body": json.dumps(msg)}

    if event.get("httpMethod", "GET") != "GET":
        return {"statusCode": 400, "body": json.dumps("Bad Request")}

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
