import json
import os

import boto3

firehose = boto3.client("firehose")

# Stream name is environment-specific (PUT-CloudWatch-Staging / -Prod) and is
# injected by CloudFormation so the same code works in every environment.
FIREHOSE_STREAM = os.environ["FIREHOSE_STREAM"]


def lambda_handler(event, context):
    records = []

    for sqs_record in event["Records"]:
        body = json.loads(sqs_record["body"])
        log_group = body.get("logGroup", "/LogApi/Test")
        messages = body.get("messages", [])

        # Iterate through the messages array
        for msg in messages:
            payload = {
                "logGroup": log_group,
                "message": msg.get("message", ""),
                "timestamp": msg.get("timestamp")
            }
            records.append({"Data": (json.dumps(payload) + "\n").encode("utf-8")})

    if records:
        resp = firehose.put_record_batch(
            DeliveryStreamName=FIREHOSE_STREAM,
            Records=records
        )
        print(f"Sent {len(records)} records to {FIREHOSE_STREAM}, failed={resp['FailedPutCount']}")

    return {"statusCode": 200}
