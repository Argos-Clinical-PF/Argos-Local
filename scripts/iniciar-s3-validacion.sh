#!/bin/sh
set -eu
awslocal s3api head-bucket --bucket argos-validacion 2>/dev/null || awslocal s3api create-bucket --bucket argos-validacion
awslocal s3api put-public-access-block --bucket argos-validacion --public-access-block-configuration '{"BlockPublicAcls":true,"IgnorePublicAcls":true,"BlockPublicPolicy":true,"RestrictPublicBuckets":true}'
awslocal s3api put-bucket-cors --bucket argos-validacion --cors-configuration '{"CORSRules":[{"AllowedOrigins":["http://localhost:5173"],"AllowedMethods":["GET","PUT","HEAD"],"AllowedHeaders":["*"],"ExposeHeaders":["ETag"]}]}'
