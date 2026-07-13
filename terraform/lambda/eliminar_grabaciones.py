import os
from datetime import datetime, timedelta, timezone

import boto3
from botocore.exceptions import ClientError


s3 = boto3.client("s3")
BUCKET = os.environ["BUCKET"]
MAX_RETENTION = timedelta(hours=int(os.environ.get("MAX_RETENTION_HOURS", "720")))
MULTIPART_RETENTION = timedelta(hours=int(os.environ.get("MULTIPART_RETENTION_HOURS", "24")))
DELETE_AT_TAG = "argos-delete-at"


def _delete_at(key, last_modified):
    try:
        response = s3.get_object_tagging(Bucket=BUCKET, Key=key)
        tags = {tag["Key"]: tag["Value"] for tag in response.get("TagSet", [])}
        value = tags.get(DELETE_AT_TAG)
        if value is not None:
            return datetime.fromtimestamp(int(value), timezone.utc)
    except (ValueError, TypeError, ClientError):
        pass

    # Un objeto sin etiqueta nunca puede superar el máximo técnico del ambiente.
    return last_modified + MAX_RETENTION


def handler(_event, _context):
    now = datetime.now(timezone.utc)
    eliminados = 0
    paginator = s3.get_paginator("list_objects_v2")
    for pagina in paginator.paginate(Bucket=BUCKET):
        for objeto in pagina.get("Contents", []):
            if _delete_at(objeto["Key"], objeto["LastModified"]) <= now:
                s3.delete_object(Bucket=BUCKET, Key=objeto["Key"])
                eliminados += 1

    abortados = 0
    limite_multipart = now - MULTIPART_RETENTION
    paginator_uploads = s3.get_paginator("list_multipart_uploads")
    for pagina in paginator_uploads.paginate(Bucket=BUCKET):
        for upload in pagina.get("Uploads", []):
            if upload["Initiated"] <= limite_multipart:
                s3.abort_multipart_upload(Bucket=BUCKET, Key=upload["Key"], UploadId=upload["UploadId"])
                abortados += 1
    return {"eliminados": eliminados, "multipart_abortados": abortados}
