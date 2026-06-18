import boto3
import base64
import json
import time
from collections import defaultdict

logs = boto3.client("logs")


def lambda_handler(event, context):
    output = []
    print(f"Incoming event: {json.dumps(event)}")

    # Dictionary to group events by (logGroup, logStream)
    grouped_events = defaultdict(list)

    for record in event['records']:
        try:
            payload = base64.b64decode(record['data']).decode('utf-8')
            log_entry = json.loads(payload)

            log_group = log_entry.get("logGroup", "/default/logs")
            log_stream = time.strftime("%Y-%m-%d")  # daily stream

            # Build individual events
            if "message" in log_entry:
                ts = sanitize_timestamp(int(log_entry.get("timestamp", int(time.time() * 1000))))
                grouped_events[(log_group, log_stream)].append({"timestamp": ts, "message": log_entry["message"]})
            elif "messages" in log_entry:
                for msg in log_entry["messages"]:
                    ts = sanitize_timestamp(int(msg.get("timestamp", int(time.time() * 1000))))
                    grouped_events[(log_group, log_stream)].append({"timestamp": ts, "message": msg.get("message", "")})

            # Firehose response: mark Dropped
            output.append({
                "recordId": record['recordId'],
                "result": "Dropped",
                "data": record['data']
            })

        except Exception as e:
            print(f"Error processing record {record['recordId']}: {e}")
            output.append({
                "recordId": record['recordId'],
                "result": "ProcessingFailed",
                "data": record['data']
            })

    # Write events per (logGroup, logStream)
    for (log_group, log_stream), events in grouped_events.items():
        print(f"Processing {len(events)} events for {log_group}/{log_stream}")
        # Ensure log group exists
        try:
            logs.create_log_group(logGroupName=log_group)
        except logs.exceptions.ResourceAlreadyExistsException:
            pass

        # Ensure log stream exists
        try:
            logs.create_log_stream(logGroupName=log_group, logStreamName=log_stream)
        except logs.exceptions.ResourceAlreadyExistsException:
            pass

        # Sort events by timestamp
        events.sort(key=lambda x: x["timestamp"])
        put_events_with_retry(log_group, log_stream, events)

    return {"records": output}


def sanitize_timestamp(ts):
    now = int(time.time() * 1000)
    two_hours = 2 * 60 * 60 * 1000
    if ts < now - two_hours or ts > now + two_hours:
        print(f"Timestamp {ts} out of range, replacing with {now}")
        return now
    return ts


def put_events_with_retry(log_group, log_stream, events):
    sequence_token = None
    for attempt in range(3):
        try:
            kwargs = {
                "logGroupName": log_group,
                "logStreamName": log_stream,
                "logEvents": events
            }
            if sequence_token:
                kwargs["sequenceToken"] = sequence_token

            print(f"Calling put_log_events for {log_group}/{log_stream} with {len(events)} events")
            resp = logs.put_log_events(**kwargs)
            sequence_token = resp.get("nextSequenceToken")
            print(f"put_log_events response: {resp}")
            return True

        except logs.exceptions.InvalidSequenceTokenException as e:
            msg = str(e)
            print(f"InvalidSequenceTokenException: {msg}")
            if "expected sequenceToken is" in msg:
                sequence_token = msg.split("expected sequenceToken is")[-1].strip()
            else:
                raise
        except Exception as e:
            print(f"PutLogEvents failed: {e}")
            raise

    print(f"Failed to put events into {log_group}/{log_stream} after retries")
    return False
