import os
from datetime import datetime, timedelta, timezone

import boto3


s3 = boto3.client("s3")
BUCKET = os.environ["BUCKET"]
RETENTION = timedelta(hours=int(os.environ.get("RETENTION_HOURS", "12")))


def handler(_event, _context):
    limite = datetime.now(timezone.utc) - RETENTION
    eliminados = 0
    paginator = s3.get_paginator("list_objects_v2")
    for pagina in paginator.paginate(Bucket=BUCKET):
        for objeto in pagina.get("Contents", []):
            if objeto["LastModified"] <= limite:
                s3.delete_object(Bucket=BUCKET, Key=objeto["Key"])
                eliminados += 1

    abortados = 0
    paginator_uploads = s3.get_paginator("list_multipart_uploads")
    for pagina in paginator_uploads.paginate(Bucket=BUCKET):
        for upload in pagina.get("Uploads", []):
            if upload["Initiated"] <= limite:
                s3.abort_multipart_upload(Bucket=BUCKET, Key=upload["Key"], UploadId=upload["UploadId"])
                abortados += 1
    return {"eliminados": eliminados, "multipart_abortados": abortados}
