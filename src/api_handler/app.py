import boto3
import json
import logging
import os

logger = logging.getLogger()
logger.setLevel(logging.DEBUG)

sqs = boto3.client("sqs")


def lambda_handler(event, context):
    try:
        logger.debug(f"Incoming event: {json.dumps(event)}")

        # Get configuration from environment variables (ENV and SQS_URL)
        env = os.environ.get("ENV", "dev")
        queue_url = os.environ.get("SQS_URL")

        if not queue_url:
            raise ValueError("Environment variable 'SQS_URL' must be set")

        logger.debug(f"Using environment: {env}, queue_url: {queue_url}")

        # Case 1: API Gateway with Lambda Proxy Integration
        if "body" in event:
            body_raw = event["body"]
            try:
                body = json.loads(body_raw)
            except Exception as e:
                logger.error(f"Invalid JSON body: {body_raw}")
                return {
                    "statusCode": 400,
                    "body": json.dumps({"error": "Invalid JSON", "details": str(e)})
                }
        else:
            # Case 2: direct integration (JSON mapped directly)
            body = event

        logger.debug(f"Parsed body: {json.dumps(body)}")

        # Send synchronously
        response = sqs.send_message(
            QueueUrl=queue_url,
            MessageBody=json.dumps(body)
        )
        logger.debug(f"SQS send OK: {json.dumps(response)}")

        # Immediately return 202 Accepted
        return {
            "statusCode": 202,
            "body": json.dumps({
                "status": "accepted",
                "env": env,
                "messageId": response["MessageId"]
            })
        }

    except Exception as e:
        logger.exception("Error while processing request")
        return {"statusCode": 500, "body": json.dumps({"error": str(e)})}
